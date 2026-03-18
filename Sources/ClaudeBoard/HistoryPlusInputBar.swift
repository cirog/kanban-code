import SwiftUI
import AppKit

struct HistoryPlusInputBar: View {
    @State private var inputText = ""
    @State private var sentFlash = false
    @FocusState private var isInputFocused: Bool
    var onSend: (String) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Type a message...")
                        .foregroundStyle(Color(hex: "#6272A4"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#F8F8F2"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: 80, maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($isInputFocused)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.command) {
                            send()
                            return .handled
                        }
                        // Enter without modifiers = newline (default behavior)
                        return .ignored
                    }
            }
            .background(Color(hex: "#44475A"))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(sentFlash ? Color.green.opacity(0.8) : Color(hex: "#6272A4"), lineWidth: 1)
            )

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color(hex: "#6272A4") : Color(hex: "#BD93F9")
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        inputText = ""
        sentFlash = true
        withAnimation(.easeOut(duration: 1.0)) {
            sentFlash = false
        }
    }
}
