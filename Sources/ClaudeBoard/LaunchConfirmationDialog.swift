import SwiftUI
import ClaudeBoardCore

/// Pre-launch confirmation dialog showing editable prompt, options, and editable command.
/// Also used for resume — shows the resume command.
struct LaunchConfirmationDialog: View {
    let cardId: String
    let projectPath: String
    let initialPrompt: String
    let isResume: Bool
    let sessionId: String?
    let assistant: CodingAssistant
    @Binding var isPresented: Bool
    var onLaunch: (String, Bool, String?, Bool, Bool, String?, [ImageAttachment]) -> Void = { _, _, _, _, _, _, _ in }

    @State private var prompt: String
    @State private var images: [ImageAttachment]
    @State private var command: String = ""
    @State private var commandEdited: Bool = false
    @AppStorage("dangerouslySkipPermissions") private var dangerouslySkipPermissions = true

    init(
        cardId: String,
        projectPath: String,
        initialPrompt: String,
        isResume: Bool = false,
        sessionId: String? = nil,
        promptImagePaths: [String] = [],
        assistant: CodingAssistant = .claude,
        isPresented: Binding<Bool>,
        onLaunch: @escaping (String, Bool, String?, Bool, Bool, String?, [ImageAttachment]) -> Void = { _, _, _, _, _, _, _ in }
    ) {
        self.cardId = cardId
        self.projectPath = projectPath
        self.initialPrompt = initialPrompt
        self.isResume = isResume
        self.sessionId = sessionId
        self.assistant = assistant
        self._isPresented = isPresented
        self.onLaunch = onLaunch
        self._prompt = State(initialValue: initialPrompt)
        self._images = State(initialValue: promptImagePaths.compactMap { ImageAttachment.fromPath($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isResume ? "Resume Session" : "Launch Session")
                        .font(.app(.title3))
                        .fontWeight(.semibold)

                    // Project path (read-only)
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(projectPath)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    // Session ID (resume only)
                    if isResume, let sid = sessionId {
                        HStack(spacing: 6) {
                            AssistantIcon(assistant: assistant)
                                .frame(width: CGFloat(14).scaled, height: CGFloat(14).scaled)
                                .opacity(0.5)
                            Text(sid)
                                .font(.app(.caption).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    // Editable prompt (launch only)
                    if !isResume {
                        PromptSection(
                            text: $prompt,
                            images: $images,
                            minHeight: 120,
                            onSubmit: submitForm
                        )
                    }

                    // Checkboxes
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Dangerously skip permissions", isOn: $dangerouslySkipPermissions)
                            .font(.app(.callout))
                    }

                    // Editable command
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $command)
                            .font(.app(.caption).monospaced())
                            .frame(minHeight: 36, maxHeight: 80)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(4)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .onChange(of: command) {
                                if command != commandPreview {
                                    commandEdited = true
                                }
                            }
                    }
                }
                .padding(20)
            }

            // Buttons pinned outside scroll area
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isResume ? "Resume" : "Launch", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(!isResume && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 8)
        }
        .frame(width: 500)
        .frame(maxHeight: 700)
        .onAppear {
            command = commandPreview
        }
        .onChange(of: prompt) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: dangerouslySkipPermissions) {
            if !commandEdited { command = commandPreview }
        }
    }

    // MARK: - Actions

    private func submitForm() {
        if !isResume {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        }
        let override = commandEdited ? command : nil
        onLaunch(prompt, false, nil, false, dangerouslySkipPermissions, override, images)
        isPresented = false
    }

    // MARK: - Computed

    private var commandPreview: String {
        if isResume, let sid = sessionId {
            var resumeCmd = assistant.cliCommand
            if dangerouslySkipPermissions { resumeCmd += " \(assistant.autoApproveFlag)" }
            resumeCmd += " \(assistant.resumeFlag) \(sid)"
            return "cd \(projectPath) && \(resumeCmd)"
        } else {
            var cmd = assistant.cliCommand
            if dangerouslySkipPermissions { cmd += " \(assistant.autoApproveFlag)" }
            return cmd
        }
    }

    static func truncatePrompt(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = trimmed.components(separatedBy: .newlines)
            .joined(separator: " ")
        if singleLine.count <= maxLength { return singleLine }
        return String(singleLine.prefix(maxLength)) + "..."
    }
}
