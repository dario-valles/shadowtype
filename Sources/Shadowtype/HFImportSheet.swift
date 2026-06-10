// HFImportSheet — M4 BYOM HF: SwiftUI sheet presented from `ModelsPane` for "Import from
// HuggingFace…". Flow:
//   1. User pastes an HF URL (direct .gguf link OR a repo URL).
//   2. Optional HF token in a secure field — persisted to Keychain on save (APIKeyStore).
//   3. "Resolve" button:
//      - Direct file URL → download immediately, no API call.
//      - Repo URL → call HFResolver.listGGUFs → show picker → user picks → download.
//   4. Download via ModelManager.downloadAuthenticated (sends Authorization: Bearer if token set).
//   5. Validate GGUF magic, register with ImportedModelStore, dismiss sheet.
//
// Errors are surfaced inline (no modal alerts) so the user can correct + retry without leaving
// the sheet. The token field shows a masked-with-suffix preview when a value exists in Keychain
// so the user knows it's set without exposing the full value.
import SwiftUI

struct HFImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onImported: (ImportedModelEntry) -> Void

    @State private var urlText: String = ""
    @State private var tokenText: String = ""
    @State private var tokenLoaded: String? = APIKeyStore.read(.huggingfaceToken)
    @State private var phase: Phase = .input
    @State private var siblings: [HFResolver.Sibling] = []
    @State private var selectedSibling: HFResolver.Sibling?
    @State private var status: String = ""
    @State private var isError = false
    @State private var progress: Double? = nil
    // The in-flight download, kept so Cancel can actually abort the transfer (cooperative
    // cancellation propagates into ModelManager's URLSession download) instead of letting it
    // finish + register behind the dismissed sheet.
    @State private var downloadTask: Task<Void, Never>? = nil

    private enum Phase {
        case input, resolving, pickingFile, downloading, done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch phase {
            case .input, .resolving:
                inputForm
            case .pickingFile:
                pickerForm
            case .downloading:
                downloadingState
            case .done:
                EmptyView()
            }
            statusLine
            buttonBar
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import from HuggingFace")
                .font(.system(size: 18, weight: .semibold))
            Text("Paste a HuggingFace URL. We accept direct `.gguf` resolve links or a repo URL — for repos we'll list the available GGUF files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("URL").font(.caption.weight(.medium))
            TextField("https://huggingface.co/owner/repo  or  …/resolve/main/file.gguf", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                Text("Access token").font(.caption.weight(.medium))
                Spacer()
                if let existing = tokenLoaded, !existing.isEmpty, tokenText.isEmpty {
                    Text("Saved \(maskedPreview(existing))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            SecureField("hf_…  (only needed for private/gated repos)", text: $tokenText)
                .textFieldStyle(.roundedBorder)
            Text("Stored in your macOS Keychain — never written to UserDefaults or the diagnostic log. Leave blank to keep the previously saved token.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pickerForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(siblings.count) GGUF file\(siblings.count == 1 ? "" : "s") found in this repo. Pick one to import:")
                .font(.callout)
            Text("Q4_K_M is the recommended balance of quality and size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(siblings, id: \.filename) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.filename)
                                    .font(.system(size: 12, design: .monospaced))
                                Text(HFResolver.displaySize(s.sizeBytes))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedSibling?.filename == s.filename {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(8)
                        .background(
                            selectedSibling?.filename == s.filename
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedSibling = s }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var downloadingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloading…").font(.callout)
            if let p = progress {
                ProgressView(value: p)
            } else {
                ProgressView()
            }
        }
    }

    private var statusLine: some View {
        Group {
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttonBar: some View {
        HStack {
            Button("Cancel") {
                downloadTask?.cancel()
                dismiss()
            }
            Spacer()
            switch phase {
            case .input, .resolving:
                Button("Resolve") { resolveURL() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || phase == .resolving)
            case .pickingFile:
                Button("Import") { startDownload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedSibling == nil)
            case .downloading:
                Button("Importing…") {}.disabled(true)
            case .done:
                EmptyView()
            }
        }
    }

    // MARK: - Actions

    private func resolveURL() {
        isError = false; status = ""
        let parsed = HFResolver.parse(urlText)
        // Save token to Keychain BEFORE making any HF call so a private repo lists/downloads work
        // on first try. An empty input means "use whatever's already saved" — don't overwrite.
        if !tokenText.isEmpty {
            APIKeyStore.write(.huggingfaceToken, value: tokenText)
            tokenLoaded = tokenText
        }
        let token = !tokenText.isEmpty ? tokenText : (tokenLoaded ?? "")

        switch parsed {
        case .invalid(let reason):
            isError = true; status = reason
            return
        case .directFile:
            // Skip API listing; download immediately.
            startDownload(direct: parsed, token: token)
        case .repoOnly(let owner, let repo):
            phase = .resolving
            status = "Looking up files in \(owner)/\(repo)…"
            HFResolver.listGGUFs(owner: owner, repo: repo, token: token) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let list):
                        // Smallest-first ordering + Q4_K_M default (the recommended quant) so the
                        // happy path is "paste URL, Resolve, Import" with no scrolling.
                        let sorted = HFResolver.sortedBySizeAscending(list)
                        siblings = sorted
                        selectedSibling = HFResolver.preferredImportFile(in: sorted)
                        phase = .pickingFile
                        status = ""
                    case .failure(let err):
                        isError = true
                        status = describe(err)
                        phase = .input
                    }
                }
            }
        }
    }

    private func startDownload(direct: HFResolver.Parsed? = nil, token: String? = nil) {
        let usedToken = token ?? (!tokenText.isEmpty ? tokenText : tokenLoaded) ?? ""
        let downloadURL: URL
        let filename: String

        if case .directFile(_, _, _, let f, let url)? = direct {
            downloadURL = url
            filename = f
        } else if let s = selectedSibling {
            downloadURL = s.downloadURL
            filename = s.filename
        } else {
            isError = true; status = "no file selected"
            return
        }

        phase = .downloading
        status = "Downloading \(filename)…"
        progress = nil

        downloadTask = Task {
            let manager = ModelManager()
            manager.onDownloadProgress = { p in
                DispatchQueue.main.async { progress = p }
            }
            do {
                // Download into the imports dir directly so we don't need a second copy/move.
                let importsDir = (try? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true))!
                    .appendingPathComponent("Shadowtype/models/imported", isDirectory: true)
                try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
                let target = importsDir.appendingPathComponent(filename)
                let final = try await manager.downloadAuthenticated(
                    from: downloadURL, to: target, token: usedToken)

                // Cancelled while (or right after) downloading: do NOT register the import — the
                // user dismissed the sheet. Clean up the file so a half-meant import doesn't linger.
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: final)
                    return
                }

                // Approximate RAM ≈ file size for quantized GGUFs.
                let bytes = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.int64Value ?? 0
                let approxGB = Double(bytes) / (1024 * 1024 * 1024) * 1.1

                let entry = ImportedModelEntry(
                    id: ImportedModelStore.shared.generateID(),
                    name: (filename as NSString).deletingPathExtension,
                    fileName: filename,
                    linkedPath: final.path,
                    originalPath: nil,                    // HF source: no on-disk original
                    approxRAMGB: approxGB,
                    source: .huggingFace,
                    createdAt: Date()
                )
                ImportedModelStore.shared.insert(entry)
                await MainActor.run {
                    onImported(entry)
                    dismiss()
                }
            } catch is CancellationError {
                // User hit Cancel — the sheet is already dismissing; nothing to report.
                return
            } catch {
                await MainActor.run {
                    phase = .input
                    isError = true
                    status = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func describe(_ err: HFResolver.Failure) -> String {
        switch err {
        case .http(let code) where code == 401 || code == 403:
            return "HuggingFace rejected the request (\(code)). This repo may need an access token."
        case .http(let code):
            return "HuggingFace HTTP \(code). Check the URL or your token."
        case .malformed(let msg):
            return "Could not contact HuggingFace: \(msg)"
        case .noGGUFFiles:
            return "No .gguf files found in this repo."
        }
    }

    private func maskedPreview(_ s: String) -> String {
        guard s.count > 6 else { return "(hidden)" }
        return "…" + String(s.suffix(4))
    }
}
