import SwiftUI
import ClaudeBoardCore

let presetLabelColors = [
    "#FF6B6B", "#FF9F43", "#FECA57", "#48DBFB", "#0ABDE3",
    "#10AC84", "#1DD1A1", "#54A0FF", "#5F27CD", "#C44569",
    "#808080", "#2C3E50",
]

struct NewProjectLabelSheet: View {
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedColor = presetLabelColors[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project Label")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Color")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
                ForEach(presetLabelColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: selectedColor == hex ? 2 : 0)
                        )
                        .onTapGesture {
                            selectedColor = hex
                        }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard !name.isEmpty else { return }
                    onSave(name, selectedColor)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
