import SwiftUI
import KanbanCodeCore

// MARK: - Editor discovery

/// Discovers installed code editors and opens files/folders in them.
enum EditorDiscovery {
    /// Known code editor bundle IDs — only installed ones appear in the picker.
    private static let knownEditors: [(bundleId: String, name: String)] = [
        ("dev.zed.Zed", "Zed"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.intellij.ce", "IntelliJ CE"),
        ("com.jetbrains.CLion", "CLion"),
        ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.goland", "GoLand"),
        ("com.jetbrains.rider", "Rider"),
        ("com.jetbrains.rustrover", "RustRover"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text 3"),
        ("org.vim.MacVim", "MacVim"),
        ("org.gnu.Emacs", "Emacs"),
        ("com.panic.Nova", "Nova"),
        ("com.barebones.bbedit", "BBEdit"),
        ("co.aspect.browser", "Windsurf"),
        ("com.neovide.neovide", "Neovide"),
        ("com.apple.TextEdit", "TextEdit"),
    ]

    struct Editor: Identifiable, Hashable {
        let bundleId: String
        let name: String
        let icon: NSImage
        var id: String { bundleId }
    }

    /// Returns only editors that are installed on this system.
    static func installedEditors() -> [Editor] {
        knownEditors.compactMap { entry in
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: entry.bundleId
            ) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            return Editor(bundleId: entry.bundleId, name: entry.name, icon: icon)
        }
    }

    /// CLI names for editors — used to open the correct folder as project root.
    /// NSWorkspace.open alone can't do this for already-running editors.
    /// CLI commands and extra flags for editors.
    private static let cliCommands: [String: (command: String, extraArgs: [String])] = [
        "dev.zed.Zed": ("zed", ["-n"]),
        "com.todesktop.230313mzl4w4u92": ("cursor", []),
        "com.microsoft.VSCode": ("code", []),
        "co.aspect.browser": ("windsurf", []),
        "com.sublimetext.4": ("subl", []),
        "com.sublimetext.3": ("subl", []),
    ]

    /// Open a path in the editor with the given bundle ID.
    static func open(path: String, bundleId: String) {
        // Try CLI first — the only reliable way to tell an already-running editor
        // to open a specific directory as project root
        if let entry = cliCommands[bundleId] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [entry.command] + entry.extraArgs + [path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return }
        }
        // Fallback to NSWorkspace
        let url = URL(fileURLWithPath: path)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open a file in the editor, creating it first if needed (for config files).
    static func openFile(path: String, bundleId: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: "{}".data(using: .utf8))
        }
        open(path: path, bundleId: bundleId)
    }
}

// MARK: - Settings root

struct SettingsView: View {
    @State private var tmuxAvailable = false

    var body: some View {
        TabView {
            ProjectsSettingsView()
                .tabItem { Label("Projects", systemImage: "folder") }

            GeneralSettingsView(
                tmuxAvailable: tmuxAvailable
            )
            .tabItem { Label("General", systemImage: "gear") }

            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 520, height: 460)
        .task {
            tmuxAvailable = await TmuxAdapter().isAvailable()
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let tmuxAvailable: Bool

    @AppStorage("preferredEditorBundleId") private var editorBundleId: String = "dev.zed.Zed"
    @AppStorage("uiTextSize") private var uiTextSize: Int = 1
    @AppStorage("sessionDetailFontSize") private var sessionDetailFontSize: Double = Double(TerminalCache.defaultFontSize)
    @State private var installedEditors: [EditorDiscovery.Editor] = []
    @State private var showOnboarding = false

    var body: some View {
        Form {
            Section("Editor") {
                Picker("Open files with", selection: $editorBundleId) {
                    ForEach(installedEditors) { editor in
                        Label {
                            Text(editor.name)
                        } icon: {
                            Image(nsImage: editor.icon)
                        }
                        .tag(editor.bundleId)
                    }
                }
            }

            Section("Appearance") {
                Picker("UI text size", selection: $uiTextSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                    Text("X-Large").tag(3)
                    Text("XX-Large").tag(4)
                }

                HStack {
                    Text("Session details monospace font size")
                    Spacer()
                    Text("\(Int(sessionDetailFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("", value: $sessionDetailFontSize, in: 8...24, step: 1)
                        .labelsHidden()
                }

                HStack {
                    Text("⌘+ / ⌘- to adjust both, or set independently here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Reset to Defaults") {
                        uiTextSize = 1
                        sessionDetailFontSize = Double(TerminalCache.defaultFontSize)
                    }
                    .controlSize(.small)
                    .disabled(uiTextSize == 1 && sessionDetailFontSize == Double(TerminalCache.defaultFontSize))
                }
            }

            Section("Integrations") {
                statusRow("tmux", available: tmuxAvailable)
            }

            Section("Settings File") {
                HStack {
                    Text("~/.kanban-code/settings.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Editor") {
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/settings.json")
                        EditorDiscovery.openFile(path: path, bundleId: editorBundleId)
                    }
                    .controlSize(.small)
                }
            }

            Section {
                Button("Open Setup Wizard...") {
                    showOnboarding = true
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            installedEditors = EditorDiscovery.installedEditors()
        }
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

// MARK: - Notifications

struct NotificationSettingsView: View {
    @State private var pushoverEnabled = false
    @State private var pushoverToken = ""
    @State private var pushoverUserKey = ""
    @State private var renderMarkdownImage = false
    @State private var isSaving = false
    @State private var testSending = false
    @State private var testResult: String?
    @State private var pandocAvailable = false
    @State private var wkhtmltoimageAvailable = false
    @State private var saveTask: Task<Void, Never>?

    private let settingsStore = SettingsStore()

    private var pushoverConfigured: Bool {
        pushoverEnabled && !pushoverToken.isEmpty && !pushoverUserKey.isEmpty
    }

    var body: some View {
        Form {
            Section("Pushover") {
                Toggle("Enable Pushover notifications", isOn: $pushoverEnabled)
                    .onChange(of: pushoverEnabled) { scheduleSave() }

                TextField("App Token", text: $pushoverToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!pushoverEnabled)
                    .onChange(of: pushoverToken) { scheduleSave() }
                TextField("User Key", text: $pushoverUserKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!pushoverEnabled)
                    .onChange(of: pushoverUserKey) { scheduleSave() }

                HStack {
                    Button {
                        testNotification()
                    } label: {
                        HStack(spacing: 4) {
                            if testSending {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "play.circle")
                            }
                            Text("Send Test")
                        }
                    }
                    .controlSize(.small)
                    .disabled(!pushoverConfigured || testSending)

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("Sent") ? .green : .red)
                    }
                }

                Text("Get your keys at pushover.net")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Rich Notification Images") {
                Toggle("Render full output as markdown image", isOn: $renderMarkdownImage)
                    .disabled(!pushoverConfigured)
                    .onChange(of: renderMarkdownImage) { scheduleSave() }

                if !pushoverConfigured {
                    Text("Configure Pushover above to enable this option.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if renderMarkdownImage {
                    statusRow("pandoc", available: pandocAvailable,
                              hint: "brew install pandoc")
                    statusRow("wkhtmltoimage", available: wkhtmltoimageAvailable,
                              hint: "Download .pkg from github.com/wkhtmltopdf/packaging/releases")

                    if !(pandocAvailable && wkhtmltoimageAvailable) {
                        Text("Install the missing dependencies above to enable image rendering.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("When enabled, Claude's full markdown output is rendered as an image and attached to push notifications.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("macOS Fallback") {
                HStack {
                    Label("Native Notifications", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text("Always available")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text("When Pushover is not configured, notifications are sent via macOS notification center.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        }
        .formStyle(.grouped)
        .padding()
        .task { await loadSettings() }
    }

    private func statusRow(_ name: String, available: Bool, hint: String) -> some View {
        HStack {
            Label(name, systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
            Spacer()
            if available {
                Text("Available")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text(hint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func loadSettings() async {
        do {
            let settings = try await settingsStore.read()
            pushoverEnabled = settings.notifications.pushoverEnabled
            pushoverToken = settings.notifications.pushoverToken ?? ""
            pushoverUserKey = settings.notifications.pushoverUserKey ?? ""
            renderMarkdownImage = settings.notifications.renderMarkdownImage
        } catch {}
        pandocAvailable = await ShellCommand.isAvailable("pandoc")
        wkhtmltoimageAvailable = await ShellCommand.isAvailable("wkhtmltoimage")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                var settings = try await settingsStore.read()
                settings.notifications.pushoverEnabled = pushoverEnabled
                settings.notifications.pushoverToken = pushoverToken.isEmpty ? nil : pushoverToken
                settings.notifications.pushoverUserKey = pushoverUserKey.isEmpty ? nil : pushoverUserKey
                settings.notifications.renderMarkdownImage = renderMarkdownImage
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {}
        }
    }

    private func testNotification() {
        testSending = true
        testResult = nil
        Task {
            do {
                let client = PushoverClient(token: pushoverToken, userKey: pushoverUserKey)
                try await client.sendNotification(
                    title: "Kanban Test",
                    message: "Notifications are working!",
                    imageData: nil,
                    cardId: nil
                )
                testResult = "Sent!"
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            testSending = false
        }
    }
}

// MARK: - Projects

struct ProjectsSettingsView: View {
    @State private var projects: [Project] = []
    @State private var excludedPaths: [String] = []
    @State private var newExcludedPath = ""
    @State private var error: String?
    @State private var editingProject: Project?
    @State private var isEditingNew = false
    @State private var projectLabels: [ProjectLabel] = []
    @State private var showNewLabel = false
    @State private var newLabelName = ""
    @State private var newLabelColor = presetLabelColors[0]

    private let settingsStore = SettingsStore()

    var body: some View {
        Form {
            Section("Project Labels") {
                if projectLabels.isEmpty {
                    Text("No project labels configured")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(projectLabels) { label in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: label.color))
                                .frame(width: 12, height: 12)
                            Text(label.name)
                            Spacer()
                            Button {
                                deleteLabel(label)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove label")
                        }
                    }
                }

                if showNewLabel {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Label name", text: $newLabelName)
                            .textFieldStyle(.roundedBorder)

                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 6), spacing: 6) {
                            ForEach(presetLabelColors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary, lineWidth: newLabelColor == hex ? 2 : 0)
                                    )
                                    .onTapGesture { newLabelColor = hex }
                            }
                        }

                        HStack {
                            Button("Cancel") {
                                showNewLabel = false
                                newLabelName = ""
                                newLabelColor = presetLabelColors[0]
                            }
                            .controlSize(.small)
                            Button("Add") {
                                addLabel()
                            }
                            .controlSize(.small)
                            .disabled(newLabelName.isEmpty)
                        }
                    }
                } else {
                    Button("Add Project Label...") {
                        showNewLabel = true
                    }
                    .controlSize(.small)
                }
            }

            Section("Projects") {
                if projects.isEmpty {
                    Text("No projects configured")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    List {
                        ForEach(projects) { project in
                            projectRow(project)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        }
                        .onMove { source, destination in
                            projects.move(fromOffsets: source, toOffset: destination)
                            Task { try? await settingsStore.reorderProjects(projects) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .frame(maxHeight: .infinity)
                }

                Button("Add Project...") {
                    addProjectViaFolderPicker()
                }
                .controlSize(.small)
            }

            Section("Global View Exclusions") {
                ForEach(excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.caption)
                        Spacer()
                        Button {
                            excludedPaths.removeAll { $0 == path }
                            saveExclusions()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Path to exclude from global view", text: $newExcludedPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Add") {
                        guard !newExcludedPath.isEmpty else { return }
                        excludedPaths.append(newExcludedPath)
                        newExcludedPath = ""
                        saveExclusions()
                    }
                    .controlSize(.small)
                    .disabled(newExcludedPath.isEmpty)
                }

                Text("Sessions from excluded paths won't appear in All Projects view")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadSettings() }
        .sheet(item: $editingProject) { project in
            ProjectEditSheet(
                project: project,
                isNew: isEditingNew,
                onSave: { updated in
                    Task {
                        if isEditingNew {
                            try? await settingsStore.addProject(updated)
                        } else {
                            try? await settingsStore.updateProject(updated)
                        }
                        await loadSettings()
                    }
                    isEditingNew = false
                    editingProject = nil
                },
                onCancel: {
                    isEditingNew = false
                    editingProject = nil
                }
            )
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .fontWeight(.medium)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !project.visible {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }

            Button {
                editingProject = project
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit project")

            Button {
                deleteProject(project)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help("Remove project")
        }
    }

    private func addProjectViaFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        // Check for duplicates
        if projects.contains(where: { $0.path == path }) {
            error = "Project already configured at this path"
            return
        }
        // Add directly then open edit sheet — avoids sheet-from-settings issues
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await loadSettings()
            // Open edit sheet so user can configure name/filter
            editingProject = projects.first(where: { $0.path == path })
        }
    }

    private func deleteProject(_ project: Project) {
        Task {
            try? await settingsStore.removeProject(path: project.path)
            await loadSettings()
        }
    }

    private func saveExclusions() {
        Task {
            var settings = try await settingsStore.read()
            settings.globalView.excludedPaths = excludedPaths
            try await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func loadSettings() async {
        do {
            let settings = try await settingsStore.read()
            projects = settings.projects
            excludedPaths = settings.globalView.excludedPaths
            projectLabels = settings.projectLabels
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addLabel() {
        guard !newLabelName.isEmpty else { return }
        let label = ProjectLabel(name: newLabelName, color: newLabelColor)
        Task {
            var settings = try await settingsStore.read()
            settings.projectLabels.append(label)
            try await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            await loadSettings()
        }
        showNewLabel = false
        newLabelName = ""
        newLabelColor = presetLabelColors[0]
    }

    private func deleteLabel(_ label: ProjectLabel) {
        Task {
            var settings = try await settingsStore.read()
            settings.projectLabels.removeAll { $0.id == label.id }
            try await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            await loadSettings()
        }
    }
}

// MARK: - Project Edit Sheet

struct ProjectEditSheet: View {
    @State private var name: String
    @State private var repoRoot: String
    @State private var visible: Bool
    let path: String
    let isNew: Bool
    let onSave: (Project) -> Void
    let onCancel: () -> Void

    init(project: Project, isNew: Bool = false, onSave: @escaping (Project) -> Void, onCancel: @escaping () -> Void) {
        self.path = project.path
        self.isNew = isNew
        self._name = State(initialValue: project.name)
        self._repoRoot = State(initialValue: project.repoRoot ?? "")
        self._visible = State(initialValue: project.visible)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Project" : "Edit Project")
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                Section {
                    TextField("Name", text: $name)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Repo root (if different from path)", text: $repoRoot)
                        .font(.caption)
                    Toggle("Visible in project selector", isOn: $visible)
                }

            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    let project = Project(
                        path: path,
                        name: name,
                        repoRoot: repoRoot.isEmpty ? nil : repoRoot,
                        visible: visible
                    )
                    onSave(project)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

}
