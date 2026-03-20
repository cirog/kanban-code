import SwiftUI
import ClaudeBoardCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    /// (cardName, projectPath, title, startImmediately, images)
    var onCreate: (String, String?, String?, Bool, [ImageAttachment]) -> Void = { _, _, _, _, _ in }

    @State private var cardName = ""
    @State private var selectedProjectPath: String = ""
    @AppStorage("lastSelectedProjectPath") private var lastSelectedProjectPath = ""

    private static let noProjectSentinel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.app(.title3))
                .fontWeight(.semibold)

            // Title / prompt
            TextField("Card name", text: $cardName)
                .textFieldStyle(.roundedBorder)
                .font(.app(.callout))
                .onSubmit { submitForm() }

            // Project picker
            if !projects.isEmpty {
                Picker("Project", selection: $selectedProjectPath) {
                    Text("None").tag(Self.noProjectSentinel)
                    ForEach(projects) { project in
                        Text(project.name).tag(project.path)
                    }
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create", action: submitForm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let defaultPath = defaultProjectPath,
               projects.contains(where: { $0.path == defaultPath }) {
                selectedProjectPath = defaultPath
            } else if !lastSelectedProjectPath.isEmpty,
               projects.contains(where: { $0.path == lastSelectedProjectPath }) {
                selectedProjectPath = lastSelectedProjectPath
            } else if let first = projects.first {
                selectedProjectPath = first.path
            }
        }
    }

    // MARK: - Actions

    private func submitForm() {
        guard !cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let proj = selectedProjectPath.isEmpty ? nil : selectedProjectPath
        if let proj { lastSelectedProjectPath = proj }
        onCreate(cardName, proj, nil, true, [])
        isPresented = false
    }
}
