import SwiftUI
import KanbanCore

// MARK: - Editor preference

enum PreferredEditor: String, CaseIterable, Identifiable {
    case zed = "Zed"
    case cursor = "Cursor"
    case vscode = "Visual Studio Code"
    case textEdit = "TextEdit"

    var id: String { rawValue }

    var bundleId: String {
        switch self {
        case .zed: "dev.zed.Zed"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .vscode: "com.microsoft.VSCode"
        case .textEdit: "com.apple.TextEdit"
        }
    }

    /// Open a file in this editor. Creates the file if it doesn't exist.
    func open(path: String) {
        // Ensure file exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: "{}".data(using: .utf8))
        }

        let url = URL(fileURLWithPath: path)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            // Fallback: open with default app
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings root

struct SettingsView: View {
    @State private var hooksInstalled = false
    @State private var ghAvailable = false
    @State private var tmuxAvailable = false
    @State private var mutagenAvailable = false

    var body: some View {
        TabView {
            GeneralSettingsView(
                hooksInstalled: $hooksInstalled,
                ghAvailable: ghAvailable,
                tmuxAvailable: tmuxAvailable,
                mutagenAvailable: mutagenAvailable
            )
            .tabItem { Label("General", systemImage: "gear") }

            AmphetamineSettingsView()
                .tabItem { Label("Amphetamine", systemImage: "bolt.fill") }

            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }

            RemoteSettingsView()
                .tabItem { Label("Remote", systemImage: "network") }
        }
        .frame(width: 480, height: 400)
        .task {
            await checkAvailability()
        }
    }

    private func checkAvailability() async {
        hooksInstalled = HookManager.isInstalled()
        ghAvailable = await GhCliAdapter().isAvailable()
        tmuxAvailable = await TmuxAdapter().isAvailable()
        mutagenAvailable = await MutagenAdapter().isAvailable()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Binding var hooksInstalled: Bool
    let ghAvailable: Bool
    let tmuxAvailable: Bool
    let mutagenAvailable: Bool

    @AppStorage("preferredEditor") private var preferredEditor: PreferredEditor = .zed

    var body: some View {
        Form {
            Section("Editor") {
                Picker("Open files with", selection: $preferredEditor) {
                    ForEach(PreferredEditor.allCases) { editor in
                        Text(editor.rawValue).tag(editor)
                    }
                }
            }

            Section("Integrations") {
                HStack {
                    Label("Claude Code Hooks", systemImage: hooksInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                    Spacer()
                    if !hooksInstalled {
                        Button("Install") {
                            do {
                                try HookManager.install()
                                hooksInstalled = true
                            } catch {
                                // Show error
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Text("Installed")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                statusRow("tmux", available: tmuxAvailable)
                statusRow("GitHub CLI (gh)", available: ghAvailable)
                statusRow("Mutagen", available: mutagenAvailable)
            }

            Section("Settings File") {
                HStack {
                    Text("~/.kanban/settings.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Editor") {
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban/settings.json")
                        preferredEditor.open(path: path)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func statusRow(_ name: String, available: Bool) -> some View {
        HStack {
            Label(name, systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
            Spacer()
            Text(available ? "Available" : "Not found")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

// MARK: - Amphetamine

struct AmphetamineSettingsView: View {
    @AppStorage("clawdLingerTimeout") private var lingerTimeout: Double = 60

    var body: some View {
        Form {
            Section("Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kanban spawns a **clawd** helper process when Claude sessions are actively working. Configure Amphetamine to detect it:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        instructionRow(1, "Install **Amphetamine** from the Mac App Store")
                        instructionRow(2, "Open Amphetamine → Preferences → **Triggers**")
                        instructionRow(3, "Add new trigger → select **Application**")
                        instructionRow(4, "Search for **\"clawd\"** and select it")
                    }

                    Text("Amphetamine will keep your Mac awake whenever Claude is working, and allow sleep when all sessions finish.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Linger Timeout") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Slider(value: $lingerTimeout, in: 0...300, step: 15)
                        Text(formatTimeout(lingerTimeout))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    Text("Keep clawd running for this long after the last active session ends, so Amphetamine doesn't immediately allow sleep.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Logs") {
                HStack {
                    Text("~/.kanban/logs/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Finder") {
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban/logs")
                        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func formatTimeout(_ seconds: Double) -> String {
        if seconds == 0 { return "Off" }
        if seconds < 60 { return "\(Int(seconds))s" }
        return "\(Int(seconds / 60))m"
    }

    private func instructionRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @State private var pushoverToken = ""
    @State private var pushoverUser = ""

    var body: some View {
        Form {
            Section("Pushover") {
                TextField("App Token", text: $pushoverToken)
                TextField("User Key", text: $pushoverUser)
                Text("Get your keys at pushover.net")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Remote

struct RemoteSettingsView: View {
    @State private var remoteHost = ""
    @State private var remotePath = ""
    @State private var localPath = ""

    var body: some View {
        Form {
            Section("SSH") {
                TextField("Remote Host", text: $remoteHost)
                    .textFieldStyle(.roundedBorder)
                TextField("Remote Path", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Local Path", text: $localPath)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
