// spec-bench — is speculative decoding (llama.cpp draft-model or MTP) worth it for Shadowtype?
//
// OPT-IN, NOT PART OF THE APP BUILD. Shadowtype links only libllama + ggml; the speculative driver
// lives in llama.cpp's common/ (common/speculative.cpp, ~3k lines), so this harness is built against
// a separate checkout of the pinned tag by run.sh. It times, per request, plain decode (prefill whole
// prompt, then 1-token decodes — what InferenceEngine does) against the speculative loop from
// examples/speculative-simple, interleaved A/B on the same contexts, over sliding prompt windows.
//
//   scripts/spec-bench/run.sh -m <target.gguf> [-md <draft.gguf>] --spec-type draft-simple|draft-mtp //       --spec-draft-n-max 3 --temp 0          # greedy; also try --temp 0.4 --top-k 40 --top-p 0.9 //                                              #   --repeat-penalty 1.1 --repeat-last-n 64 (ghost chain)
//   env: BENCH_PROMPT_TOKENS=200,1500  BENCH_N=16,64,256  BENCH_REPS=5  BENCH_STRIDE=300  BENCH_TEXT=<file>
//
// FINDINGS (llama.cpp b11466, M1 Pro 16 GB, Metal, -fa on, n_ctx 4096; ratio = plain/spec wall time
// for prefill + N tokens, median of per-window ratios; >1 = speculation faster). Machine was shared
// with other GPU work, so absolute ms are noisy; the A/B ratios are interleaved per window.
//
//   target (shipped file)          drafter (n-max 2-6)             N=16       N=64       N=256
//   Gemma 3 1B pt Q4_K_M (default) gemma-3-270m Q8_0, draft-simple 0.51-0.86x 0.68-1.06x 0.86-1.08x
//   Gemma 4 E2B it QAT Q4_0        E2B-it-qat assistant (78M) MTP  0.86-1.00x 0.95-1.14x 1.05-1.59x
//   Qwen3.5 2B (instruct, MTP GGUF) built-in MTP head              0.72-0.98x 0.86-1.00x  -
//
//   * TTFT gets WORSE (+20-60 ms short prompt, up to +190 ms with a separate draft model
//     that must prefill the prompt too): the first token only arrives after a draft + verify round.
//     The ghost's 400 ms first-token deadline is the binding constraint, and ghosts are 8-24 tokens.
//   * Gemma 3 1B already decodes ~70-95 tok/s; a 270M drafter costs nearly as much per Metal call as
//     the target, so draft-simple loses or at best breaks even at every length (acceptance 40-80%).
//   * Gemma 4 E2B + its MTP assistant is the only real win, and only for long outputs (rewrite):
//     decode 1.2-1.95x at N=256 with 55-83% acceptance (greedy), 1.05-1.2x total with the ghost sampler.
//   * The mradermacher Qwen3.5 *Base* GGUFs the catalog ships have NO MTP tensors (no
//     qwen35.nextn_predict_layers, no blk.N.nextn.*), although upstream Qwen/Qwen3.5-2B-Base has an
//     mtp.* head; the measured MTP row uses unsloth/Qwen3.5-2B-MTP-GGUF (instruct) and still loses.
//   * Greedy outputs matched plain decode in all Gemma runs at N<=64; ~1 in 6 long (N=256) or
//     Qwen3.5 runs diverged after a few dozen tokens — batch-shape float differences, not a bug.
//
// API: MTP is NOT drivable from the public llama.h alone. The public pieces are llama_model_params
// .load_mtp (llama.h:356), llama_context_params .ctx_type = LLAMA_CONTEXT_TYPE_MTP (:225-228, :377),
// .ctx_other (:425, the draft context shares the target's KV for Gemma 4), .n_rs_seq (:371, recurrent
// rollback), llama_model_n_layer_nextn (:602) and llama_batch_ext_init / _set_embd_state / llama_process
// (:1020, :1057, :1088). But feeding the target's hidden state to the MTP head needs llama_set_embeddings_nextn
// / llama_get_embeddings_nextn_ith / llama_get_ctx_other, which exist only in the staging header
// src/llama-ext.h ("breaking changes and C++ are allowed"), exported with C++ linkage
// (e.g. __Z26llama_set_embeddings_nextnP13llama_contextbb in libllama.a). Swift would need a C++ shim
// target plus a port of the MTP driver and sample-and-match verification into InferenceEngine's
// multi-seq, prefix-reusing ghost/API/rewrite loops. Classic draft-model speculation IS doable with
// the public API (decode [last, d0..dk] with logits on every row, sample sequentially, seq_rm the
// rejected tail) but measured as a loss above.
//
// VERDICT: don't adopt. Revisit when (a) the nextn/MTP calls graduate into llama.h with C linkage,
// AND (b) Gemma 4 E2B (or a model whose GGUF ships its MTP head) becomes the default or rewrite
// latency becomes a priority — re-run this bench with BENCH_N=256 on that model first.

#include "arg.h"
#include "common.h"
#include "sampling.h"
#include "speculative.h"
#include "log.h"
#include "llama.h"

#include <algorithm>
#include <chrono>
#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static double now_ms() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static std::vector<int> parse_list(const char * s, std::vector<int> def) {
    if (!s) return def;
    std::vector<int> out; std::stringstream ss(s); std::string it;
    while (std::getline(ss, it, ',')) out.push_back(std::stoi(it));
    return out;
}
static double median(std::vector<double> v) {
    if (v.empty()) return 0; std::sort(v.begin(), v.end()); size_t n = v.size();
    return n % 2 ? v[n/2] : 0.5 * (v[n/2-1] + v[n/2]);
}
static void clear_mem(llama_context * ctx) {
    if (!ctx) return;
    auto * m = llama_get_memory(ctx);
    if (m) llama_memory_clear(m, true);
}

struct run_result { double ttft, total; int n_gen; int n_drafted, n_accept; std::vector<llama_token> out; };

// Baseline: prefill whole prompt (logits on last), sample, then 1-token decodes.
static run_result run_plain(common_params & params, llama_context * ctx, llama_context * ctx_dft, const std::vector<llama_token> & inp, int n_gen) {
    clear_mem(ctx); clear_mem(ctx_dft);
    const llama_vocab * vocab = llama_model_get_vocab(llama_get_model(ctx));
    common_sampler_ptr smpl(common_sampler_init(llama_get_model(ctx), params.sampling));
    run_result r{}; const double t0 = now_ms();
    common_batch b(ctx);
    for (size_t i = 0; i < inp.size(); ++i) b.add(inp[i], i, 0, i + 1 == inp.size());
    if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, b.get()) != 0) { fprintf(stderr, "prefill failed\n"); exit(1); }
    int n_past = inp.size();
    llama_token id = common_sampler_sample(smpl.get(), ctx, -1);
    common_sampler_accept(smpl.get(), id, true);
    r.ttft = now_ms() - t0; r.out.push_back(id);
    while ((int) r.out.size() < n_gen && !llama_vocab_is_eog(vocab, id)) {
        b.clear(); b.add(id, n_past++, 0, true);
        if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, b.get()) != 0) { fprintf(stderr, "decode failed\n"); exit(1); }
        id = common_sampler_sample(smpl.get(), ctx, -1);
        common_sampler_accept(smpl.get(), id, true);
        r.out.push_back(id);
    }
    r.total = now_ms() - t0; r.n_gen = r.out.size();
    return r;
}

// Speculative: mirrors examples/speculative-simple.
static run_result run_spec(common_params & params, llama_context * ctx_tgt, llama_context * ctx_dft, const std::vector<llama_token> & inp, int n_gen) {
    clear_mem(ctx_tgt); clear_mem(ctx_dft);
    const llama_vocab * vocab = llama_model_get_vocab(llama_get_model(ctx_tgt));
    const bool use_ckpt_tgt = common_context_can_seq_rm(ctx_tgt) == COMMON_CONTEXT_SEQ_RM_TYPE_FULL;
    const bool use_ckpt_dft = ctx_dft && common_context_can_seq_rm(ctx_dft) == COMMON_CONTEXT_SEQ_RM_TYPE_FULL;
    common_sampler_ptr smpl(common_sampler_init(llama_get_model(ctx_tgt), params.sampling));
    common_speculative * spec = common_speculative_init(params.speculative, 1);
    if (!spec) { fprintf(stderr, "spec init failed\n"); exit(1); }
    const llama_seq_id seq_id = 0;
    run_result r{}; const double t0 = now_ms();
    {
        common_batch bp(ctx_tgt);
        for (size_t i = 0; i + 1 < inp.size(); ++i) bp.add(inp[i], i, seq_id, false);
        llama_process(ctx_tgt, LLAMA_PROCESS_TYPE_DECODE, bp.get());
        if (!common_speculative_process(spec, bp)) { fprintf(stderr, "spec process failed\n"); exit(1); }
    }
    llama_token id_last = inp.back();
    llama_tokens prompt_tgt(inp.begin(), inp.end() - 1);
    int n_past = inp.size() - 1;
    common_speculative_begin(spec, seq_id, prompt_tgt);
    common_batch batch_tgt(ctx_tgt);
    llama_tokens draft;
    common_prompt_checkpoint ckpt;
    bool has_eos = false;
    while (true) {
        if (draft.empty()) {
            ckpt.update_pos(prompt_tgt.size(), llama_memory_seq_pos_min(llama_get_memory(ctx_tgt), seq_id), llama_memory_seq_pos_max(llama_get_memory(ctx_tgt), seq_id));
            if (use_ckpt_dft) ckpt.update_dft(ctx_dft, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
            int n_draft_max = std::min((int) llama_n_ctx(ctx_tgt) - n_past - 2, n_gen - (int) r.out.size() - 1);
            n_draft_max = std::max(n_draft_max, 0);
            common_speculative_get_draft_params(spec, seq_id) = { true, n_draft_max, n_past, id_last, &prompt_tgt, &draft };
            common_speculative_draft(spec);
            if (!draft.empty() && use_ckpt_tgt) ckpt.update_tgt(ctx_tgt, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
            if (ctx_dft) {
                if (use_ckpt_dft) ckpt.load_dft(ctx_dft, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
                if (llama_get_memory(ctx_dft)) llama_memory_seq_rm(llama_get_memory(ctx_dft), seq_id, ckpt.pos_max + 1, -1);
            }
        }
        batch_tgt.clear();
        batch_tgt.add(id_last, n_past++, seq_id, true);
        for (size_t i = 0; i < draft.size(); ++i) batch_tgt.add(draft[i], n_past + i, seq_id, true);
        llama_process(ctx_tgt, LLAMA_PROCESS_TYPE_DECODE, batch_tgt.get());
        if (!common_speculative_process(spec, batch_tgt)) { fprintf(stderr, "spec process failed\n"); break; }
        common_sampler_ptr smpl_save;
        if (use_ckpt_tgt) smpl_save.reset(common_sampler_clone(smpl.get()));
        const size_t n_draft = draft.size();
        auto ids = common_sampler_sample_and_accept_n(smpl.get(), ctx_tgt, draft);
        if (use_ckpt_tgt && ids.size() - 1 < n_draft) {
            draft = std::move(ids);
            ckpt.load_tgt(ctx_tgt, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
            llama_memory_seq_rm(llama_get_memory(ctx_tgt), seq_id, ckpt.pos_max + 1, -1);
            if (ctx_dft) {
                ckpt.load_dft(ctx_dft, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
                if (llama_get_memory(ctx_dft)) llama_memory_seq_rm(llama_get_memory(ctx_dft), seq_id, ckpt.pos_max + 1, -1);
            }
            prompt_tgt.resize(ckpt.n_tokens);
            smpl = std::move(smpl_save);
            n_past = (int) prompt_tgt.size();
            continue;
        }
        common_speculative_accept(spec, seq_id, ids.size() - 1);
        n_past += ids.size() - 1;
        r.n_drafted += n_draft; r.n_accept += ids.size() - 1;
        for (size_t i = 0; i < ids.size(); ++i) {
            prompt_tgt.push_back(id_last);
            id_last = ids[i];
            if (r.out.empty()) r.ttft = now_ms() - t0;
            r.out.push_back(id_last);
            if (llama_vocab_is_eog(vocab, id_last)) { has_eos = true; break; }
            if ((int) r.out.size() >= n_gen) break;
        }
        draft.clear();
        llama_memory_seq_rm(llama_get_memory(ctx_tgt), seq_id, n_past, -1);
        if (ctx_dft && llama_get_memory(ctx_dft)) llama_memory_seq_rm(llama_get_memory(ctx_dft), seq_id, n_past, -1);
        if ((int) r.out.size() >= n_gen || has_eos) break;
    }
    r.total = now_ms() - t0; r.n_gen = r.out.size();
    common_speculative_free(spec);
    return r;
}

int main(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");
    common_params params;
    common_init();
    if (!common_params_parse(argc, argv, params, LLAMA_EXAMPLE_SPECULATIVE)) return 1;
    const auto lim = common_speculative_get_output_limits(params.n_batch, params.n_parallel, common_speculative_n_max(&params.speculative));
    params.n_outputs_max = lim.total; params.n_outputs_max_per_seq = lim.per_seq;
    llama_backend_init();
    auto init_tgt = common_init_from_params(params);
    llama_model * model_tgt = init_tgt->model();
    llama_context * ctx_tgt = init_tgt->context();
    common_speculative_init_result_ptr spec_init;
    common_speculative_type spec_t = COMMON_SPECULATIVE_TYPE_NONE;
    for (auto t : params.speculative.types) if (t != COMMON_SPECULATIVE_TYPE_NONE) spec_t = t;
    const bool want_spec = spec_t != COMMON_SPECULATIVE_TYPE_NONE;
    if (want_spec) {
        common_params pd = common_base_params_to_speculative(params);
        spec_init = common_speculative_init_from_params(pd, model_tgt, ctx_tgt);
        params.speculative.draft.ctx_tgt = ctx_tgt;
        params.speculative.draft.ctx_dft = spec_init->context();
    }
    llama_context * ctx_dft = params.speculative.draft.ctx_dft;

    const char * text_path = getenv("BENCH_TEXT");
    std::ifstream f(text_path ? text_path : ""); std::stringstream ss; ss << f.rdbuf();
    auto all = common_tokenize(ctx_tgt, ss.str(), true, false);
    auto plens = parse_list(getenv("BENCH_PROMPT_TOKENS"), {200, 1500});
    auto ns = parse_list(getenv("BENCH_N"), {16, 64});
    const int reps = getenv("BENCH_REPS") ? atoi(getenv("BENCH_REPS")) : 5;
    fprintf(stderr, "\nRESULT model=%s spec=%s draft_n_max=%d temp=%.2f ckpt_tgt=%d text_tokens=%zu\n",
            params.model.path.c_str(), common_speculative_type_to_str(spec_t).c_str(),
            params.speculative.draft.n_max, params.sampling.temp,
            (int)(common_context_can_seq_rm(ctx_tgt) == COMMON_CONTEXT_SEQ_RM_TYPE_FULL), all.size());
    // warmup
    { std::vector<llama_token> w(all.begin(), all.begin() + 32); run_plain(params, ctx_tgt, ctx_dft, w, 8); if (want_spec) run_spec(params, ctx_tgt, ctx_dft, w, 8); }
    for (int pl : plens) {
        const bool bos = llama_vocab_get_add_bos(llama_model_get_vocab(model_tgt));
        const int stride = getenv("BENCH_STRIDE") ? atoi(getenv("BENCH_STRIDE")) : 300;
        auto window = [&](int k) {
            std::vector<llama_token> w;
            size_t start = (bos ? 1 : 0) + (size_t) k * stride;
            if (bos) w.push_back(all[0]);
            for (size_t i = start; i < all.size() && (int) w.size() < pl; ++i) w.push_back(all[i]);
            return w;
        };
        for (int n : ns) {
            std::vector<double> pt, ptot, st, stot, ratio, dratio; int same = 0, nd = 0, na = 0, gp = 0, gs = 0;
            for (int k = 0; k < reps; ++k) {
                auto inp = window(k);
                if ((int) inp.size() < pl) { fprintf(stderr, "text too short for window %d\n", k); break; }
                auto a = run_plain(params, ctx_tgt, ctx_dft, inp, n);
                pt.push_back(a.ttft); ptot.push_back(a.total); gp = a.n_gen;
                if (want_spec) {
                    auto b = run_spec(params, ctx_tgt, ctx_dft, inp, n);
                    st.push_back(b.ttft); stot.push_back(b.total); gs = b.n_gen;
                    ratio.push_back(a.total / b.total); if (a.n_gen > 1 && b.n_gen > 1) dratio.push_back(((a.total - a.ttft)/(a.n_gen-1)) / ((b.total - b.ttft)/(b.n_gen-1)));
                    nd += b.n_drafted; na += b.n_accept; same += (a.out == b.out);
                    if (k == 0 && a.out != b.out) {
                        auto flat = [&](const std::vector<llama_token> & t) { auto s = common_detokenize(ctx_tgt, t); std::replace(s.begin(), s.end(), '\n', ' '); return s; };
                        fprintf(stderr, "diverge prompt=%d n=%d: plain='%s' spec='%s'\n", pl, n, flat(a.out).c_str(), flat(b.out).c_str());
                    }
                }
            }
            const double pdec = gp > 1 ? (gp - 1) / ((median(ptot) - median(pt)) / 1000.0) : 0;
            fprintf(stderr, "RESULT prompt=%4d n=%3d | plain ttft=%7.1f total=%7.1f gen=%d dec=%6.1f t/s",
                    pl, n, median(pt), median(ptot), gp, pdec);
            if (want_spec) {
                const double sdec = gs > 1 ? (gs - 1) / ((median(stot) - median(st)) / 1000.0) : 0;
                fprintf(stderr, " | spec ttft=%7.1f total=%7.1f gen=%d dec=%6.1f t/s accept=%5.1f%% (%d/%d) same=%d/%d | speedup(total)=%.2fx per-rep-median total=%.2fx decode=%.2fx min plain=%.0f spec=%.0f",
                        median(st), median(stot), gs, sdec, nd ? 100.0 * na / nd : 0.0, na, nd, same, reps, median(ptot) / median(stot), median(ratio), median(dratio), *std::min_element(ptot.begin(), ptot.end()), *std::min_element(stot.begin(), stot.end()));
            }
            fprintf(stderr, "\n");
        }
    }
    llama_backend_free();
    return 0;
}
