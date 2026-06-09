// LocalAPISettingsPane — Settings panel for the M1 Local API + MCP surface (free, always available).
// Lets the user:
//   - Toggle the server on/off (mirrored by `UserDefaults shadowtype.serverEnabled`).
//   - See the live status + bound port.
//   - View the Bearer API key (Keychain-backed), copy it, or regenerate.
//   - Copy ready-to-paste curl + MCP configuration snippets.
//
// The view observes `.shadowtypeLocalAPIDidChange` to refresh status after a sleep/wake re-bind
// or a port shuffle.
import SwiftUI

struct LocalAPISettingsPane: View {
    @AppStorage("shadowtype.serverEnabled") private var serverEnabled: Bool = false
    @State private var apiKey: String = APIKeyStore.read(.apiKey) ?? ""
    @State private var statusText: String = "Stopped"
    @State private var portText: String = "—"
    @State private var copyConfirmation: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                toggleSection
                if serverEnabled {
                    statusSection
                    apiKeySection
                    integrationExamples
                }
                disclaimer
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .shadowtypeLocalAPIDidChange)) { _ in refresh() }
    }

    // MARK: - Sections

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local API")
                .font(.system(size: 22, weight: .semibold))
            Text("Turn the loaded model into an OpenAI-compatible endpoint at `http://127.0.0.1:<port>/v1` plus a Unix-socket MCP bridge. Point Cursor, Zed, Aider, llm-cli, or Claude Code at it; the model stays on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var toggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $serverEnabled) {
                Text("Enable Local API server")
                    .font(.body.weight(.medium))
            }
            .toggleStyle(.switch)
            .onChange(of: serverEnabled) { _, _ in
                NotificationCenter.default.post(name: .shadowtypeToggleLocalAPI, object: nil)
            }
            Text("Starts on launch as long as this toggle is on. The server listens on 127.0.0.1 only — never on your local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusSection: some View {
        HStack(spacing: 16) {
            Label(statusText, systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .foregroundStyle(statusText.contains("Running") ? .green : .secondary)
            Text("Port \(portText)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy URL") { copy(serverURL, label: "URL") }
                .disabled(portText == "—")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bearer API Key")
                .font(.body.weight(.medium))
            Text("Required for TCP requests (`Authorization: Bearer …`). The Unix-socket transport ignores this; filesystem permissions are the auth gate there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(apiKey.isEmpty ? "<not generated yet>" : apiKey)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") { copy(apiKey, label: "API key") }
                    .disabled(apiKey.isEmpty)
                Button("Regenerate") {
                    apiKey = APIKeyStore.regenerateAPIKey()
                    copyConfirmation = "Rotated — existing clients will need the new key."
                }
            }
        }
    }

    @ViewBuilder private var integrationExamples: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Integration snippets")
                .font(.body.weight(.medium))
            ExampleBlock(title: "curl",
                         text: curlSnippet)
            ExampleBlock(title: "Claude Code MCP",
                         text: mcpSnippet)
            ExampleBlock(title: "Cursor / Continue / llm-cli",
                         text: "Base URL: \(serverURL)\nAPI key: <paste from above>")
            if let msg = copyConfirmation {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var disclaimer: some View {
        Text("Disabling the toggle stops the listener immediately; uninstalling the app removes both the TCP listener and the Unix-socket node.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Computed

    private var serverURL: String {
        guard portText != "—" else { return "http://127.0.0.1:5666/v1" }
        return "http://127.0.0.1:\(portText)/v1"
    }

    private var curlSnippet: String {
        """
        curl \(serverURL)/chat/completions \\
          -H "Authorization: Bearer \(apiKey.isEmpty ? "<KEY>" : apiKey)" \\
          -H "Content-Type: application/json" \\
          -d '{
            "model": "shadowtype",
            "messages": [{"role": "user", "content": "Hello!"}]
          }'
        """
    }

    private var mcpSnippet: String {
        let bundlePath = Bundle.main.bundlePath
        return """
        {
          "mcpServers": {
            "shadowtype": {
              "command": "\(bundlePath)/Contents/Resources/shadowtype-mcp"
            }
          }
        }
        """
    }

    // MARK: - Actions

    private func refresh() {
        apiKey = APIKeyStore.read(.apiKey) ?? ""
        // The server lives on AppDelegate; we don't have a direct ref. Pull port from notification
        // payload posted by AppDelegate, or fall back to scanning UserDefaults. For v1 we ping by
        // attempting a quick socket connect to each candidate port and using the first that answers.
        // Cheaper: read the stored "shadowtype.lastBoundPort" hint AppDelegate sets when refreshing.
        if let p = (UserDefaults.standard.object(forKey: "shadowtype.lastBoundPort") as? Int),
           p > 0 {
            statusText = "Running"
            portText = String(p)
        } else {
            statusText = "Stopped"
            portText = "—"
        }
    }

    private func copy(_ value: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        copyConfirmation = "Copied \(label)."
    }
}

private struct ExampleBlock: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }
}
