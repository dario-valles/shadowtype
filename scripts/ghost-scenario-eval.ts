// ghost-scenario-eval.ts — fire a scenario corpus at the live Shadowtype engine via the UDS
// (no auth, no GUI) and score each completion for the known content failure modes. This tests
// the MODEL+sampling+stop layer that ghost text shares with /v1/completions — NOT the ghost
// gating layer (EOL/mid-line/dedup), which lives in swift tests.
//
// Run while Shadowtype.app is running:  bun scripts/ghost-scenario-eval.ts
import { homedir } from "os";
import { spawnSync } from "child_process";

const SOCK = `${homedir()}/Library/Application Support/Shadowtype/api.sock`;

type Scenario = {
  id: string;
  cat: string;
  prompt: string;        // the prefix as it would appear before the caret
  lang?: string;         // expected language of the continuation (heuristic check)
  chat?: boolean;        // hit /v1/chat/completions instead (messages)
  messages?: { role: string; content: string }[];
};

// Ghost free tier is ~1-2 words; standard is longer. Use a small ceiling to approximate ghost
// length, but big enough to expose runaway/repetition.
const MAX_TOKENS = 16;

const corpus: Scenario[] = [
  // --- formal email ---
  { id: "email-thanks",   cat: "email", prompt: "Thank you for your email. I really appreciate " },
  { id: "email-open",     cat: "email", prompt: "I'm writing to let you know that " },
  { id: "email-signoff",  cat: "email", prompt: "Best regards,\n" },
  { id: "email-meeting",  cat: "email", prompt: "Could we schedule a call sometime next " },
  { id: "email-apology",  cat: "email", prompt: "I apologize for the delay in " },
  // --- casual chat ---
  { id: "chat-plans",     cat: "chat",  prompt: "hey are we still on for " },
  { id: "chat-lol",       cat: "chat",  prompt: "haha yeah that was " },
  { id: "chat-q",         cat: "chat",  prompt: "wait what time does the " },
  // --- mid-sentence (ghost default OFF here, but tests model behavior) ---
  { id: "mid-because",    cat: "midline", prompt: "We decided to postpone the launch because " },
  { id: "mid-the",        cat: "midline", prompt: "The most important thing about this project is the " },
  // --- lists ---
  { id: "list-shopping",  cat: "list",  prompt: "Shopping list:\n- milk\n- eggs\n- " },
  { id: "list-todo",      cat: "list",  prompt: "TODO:\n1. fix the login bug\n2. " },
  // --- spanish (language steer; user is Spanish) ---
  { id: "es-saludo",      cat: "spanish", prompt: "Hola, muchas gracias por tu ", lang: "es" },
  { id: "es-email",       cat: "spanish", prompt: "Estimado cliente, le escribo para informarle de que ", lang: "es" },
  { id: "es-casual",      cat: "spanish", prompt: "oye, quedamos mañana para ", lang: "es" },
  // --- RTL ---
  { id: "ar-greet",       cat: "rtl",   prompt: "مرحبا، شكرا جزيلا على ", lang: "ar" },
  // --- numbers / chrome-trap (memory: numeric chrome caused word-salad) ---
  { id: "num-invoice",    cat: "numbers", prompt: "Invoice #4521 total: $1," },
  { id: "num-date",       cat: "numbers", prompt: "The deadline is March " },
  // --- echo-trap: prefix that the model might just repeat back (doc-echo bug) ---
  { id: "echo-repeat",    cat: "echo",  prompt: "Please remember to bring your passport. Please remember to " },
  { id: "echo-list",      cat: "echo",  prompt: "apple banana apple banana apple " },
  // --- code (model has no FIM; tests raw continuation) ---
  { id: "code-fn",        cat: "code",  prompt: "function add(a, b) {\n  return " },
  { id: "code-import",    cat: "code",  prompt: "import { useState } from " },
  // --- edge cases ---
  { id: "edge-empty",     cat: "edge",  prompt: "" },
  { id: "edge-space",     cat: "edge",  prompt: " " },
  { id: "edge-url",       cat: "edge",  prompt: "Check out the repo at https://github.com/" },
  { id: "edge-emoji",     cat: "edge",  prompt: "Great work today everyone 🎉 " },
  { id: "edge-long",      cat: "edge",  prompt: "In conclusion, after reviewing all the evidence and considering the various perspectives that were raised during our extensive discussions over the past several weeks, it has become increasingly clear to everyone involved that the most prudent course of action would be to " },
  // --- chat endpoint ---
  { id: "chatapi-hi",     cat: "chatapi", chat: true, messages: [{ role: "user", content: "Reply to: 'Can you send me the report?'" }] },
];

function call(s: Scenario): any {
  const url = s.chat ? "http://localhost/v1/chat/completions" : "http://localhost/v1/completions";
  // `ghost: true` is a local debug extension (build > 28) that runs the real ghost decode loop
  // (leading-newline strip + continue, word/sentence stops) so the completion matches on-screen
  // ghost text. Older servers ignore the unknown field and return the rawer API stream.
  const body = s.chat
    ? { messages: s.messages, max_tokens: 48 }
    : { prompt: s.prompt, max_tokens: MAX_TOKENS, temperature: 0.4, top_p: 0.9, top_k: 40, ghost: true };
  const t0 = performance.now();
  const r = spawnSync("curl", ["-s", "--unix-socket", SOCK, url, "-H", "Content-Type: application/json", "-d", JSON.stringify(body)], { encoding: "utf8", maxBuffer: 1 << 20 });
  const ms = Math.round(performance.now() - t0);
  let json: any = null;
  try { json = JSON.parse(r.stdout); } catch { /* leave null */ }
  return { json, ms };
}

function textOf(s: Scenario, json: any): string {
  if (!json) return "";
  if (s.chat) return json.choices?.[0]?.message?.content ?? "";
  return json.choices?.[0]?.text ?? "";
}

// --- heuristic flags ---
function flags(s: Scenario, text: string): string[] {
  const f: string[] = [];
  if (text === "") { f.push("EMPTY"); return f; }
  if (/<(end_of_turn|eos|\/s|\|im_end\||end_of_text)>|<\|.*?\|>/i.test(text)) f.push("EOG-LEAK");
  // repetition: any token-run of the same word 3+ times, or a 2-gram repeated 3+ times
  const words = text.trim().toLowerCase().split(/\s+/);
  for (let i = 0; i + 2 < words.length; i++) if (words[i] && words[i] === words[i+1] && words[i] === words[i+2]) { f.push("REPEAT-WORD"); break; }
  // echo: continuation restates a long chunk already in the prompt
  const pf = (s.prompt ?? "").trim().toLowerCase();
  if (pf.length > 15) {
    const tail = pf.slice(-Math.min(40, pf.length));
    const cont = text.trim().toLowerCase();
    if (cont.length > 8 && (pf.includes(cont.slice(0, Math.min(20, cont.length))) || cont.includes(tail.slice(0, 15)))) f.push("ECHO?");
  }
  // language drift (very rough): expected Spanish/Arabic but output looks ASCII-English
  if (s.lang === "es") { const hasEs = /[áéíóúñ¿¡]/i.test(text) || /\b(que|para|gracias|usted|de|el|la|por)\b/i.test(text); if (!hasEs) f.push("LANG-DRIFT(es?)"); }
  if (s.lang === "ar") { if (!/[؀-ۿ]/.test(text)) f.push("LANG-DRIFT(ar?)"); }
  // leading newline (ghost strips this; raw API leaks it — note it)
  if (/^\n/.test(text)) f.push("lead-\\n");
  // runaway: hit token ceiling without a sentence end (would be capped by ghost, but flags verbosity)
  return f;
}

const results: any[] = [];
for (const s of corpus) {
  const { json, ms } = call(s);
  const text = textOf(s, json);
  const f = flags(s, text);
  results.push({ ...s, text, ms, flags: f });
}

// --- report ---
console.log("\n=== Shadowtype ghost-engine scenario eval ===");
const health = JSON.parse(spawnSync("curl", ["-s", "--unix-socket", SOCK, "http://localhost/v1/health"], { encoding: "utf8" }).stdout);
console.log(`model=${health.model}  ctx=${health.ctx}  chat=${health.supports_chat}  fim=${health.supports_fim}\n`);

for (const r of results) {
  const flagStr = r.flags.length ? `  ⚑ ${r.flags.join(" ")}` : "";
  const pStr = r.prompt ?? (r.messages ? JSON.stringify(r.messages) : "");
  const promptShown = pStr.length > 50 ? pStr.slice(0, 47) + "..." : pStr;
  console.log(`[${r.cat}] ${r.id}  (${r.ms}ms)${flagStr}`);
  console.log(`  prefix : ${JSON.stringify(promptShown)}`);
  console.log(`  ghost→ : ${JSON.stringify(r.text)}`);
}

const flagged = results.filter(r => r.flags.length);
console.log(`\n=== summary: ${flagged.length}/${results.length} scenarios flagged ===`);
const byFlag: Record<string, string[]> = {};
for (const r of flagged) for (const fl of r.flags) (byFlag[fl] ??= []).push(r.id);
for (const [fl, ids] of Object.entries(byFlag)) console.log(`  ${fl}: ${ids.join(", ")}`);
const avgMs = Math.round(results.filter(r=>!r.chat).reduce((a,r)=>a+r.ms,0) / results.filter(r=>!r.chat).length);
console.log(`  avg latency (completions): ${avgMs}ms`);

// Snapshot for regression diffing: re-run after a model/prompt change and `git diff` the snapshot
// to see which scenarios shifted. Latency is excluded (noisy); only id+text+flags are recorded.
const snapPath = new URL("./ghost-scenario-eval.snapshot.json", import.meta.url).pathname;
const snapshot = { model: health.model, scenarios: results.map(r => ({ id: r.id, cat: r.cat, text: r.text, flags: r.flags })) };
spawnSync("bash", ["-c", `cat > ${JSON.stringify(snapPath)}`], { input: JSON.stringify(snapshot, null, 2) + "\n", encoding: "utf8" });
console.log(`\nsnapshot → scripts/ghost-scenario-eval.snapshot.json  (git diff to spot regressions)`);
