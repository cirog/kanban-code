import SwiftUI

struct ReplyInputBar: View {
    @State private var inputText = ""
    @State private var sentFlash = false
    @FocusState private var isInputFocused: Bool
    var isWorking: Bool = false
    var onSend: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(hex: "#BD93F9"))
                    Text("Claude is responding...")
                        .font(.app(.caption))
                        .foregroundStyle(Color(hex: "#6272A4"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

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
                        .font(.app(size: 13))
                        .foregroundStyle(Color(hex: "#F8F8F2"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(minHeight: 60, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($isInputFocused)
                        .onKeyPress(.return, phases: .down) { keyPress in
                            if keyPress.modifiers.contains(.shift) {
                                return .ignored
                            }
                            send()
                            return .handled
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
        .onAppear { isInputFocused = true }
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
