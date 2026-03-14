import SwiftUI

/// Popover for manually adding a Branch link to a card.
struct AddLinkPopover: View {
    var onAddBranch: (String) -> Void = { _ in }

    @State private var branchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link")
                .font(.app(.subheadline).bold())

            TextField("Branch name", text: $branchText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Add") {
                    let branch = branchText.trimmingCharacters(in: .whitespaces)
                    guard !branch.isEmpty else { return }
                    onAddBranch(branch)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchText.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
