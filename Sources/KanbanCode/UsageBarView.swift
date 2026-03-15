import SwiftUI

struct UsageBarView: View {
    let label: String
    let utilization: Double  // 0-100
    let resetsAt: Date?

    private var fillColor: Color {
        if utilization >= 80 { return .red }
        if utilization >= 50 { return .yellow }
        return .green
    }

    private var resetText: String {
        guard let date = resetsAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private var percentText: String {
        "\(Int(utilization))%"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor.opacity(0.8))
                        .frame(width: geo.size.width * min(utilization / 100, 1.0))
                }
            }
            .frame(width: 120, height: 8)

            Text(percentText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .fixedSize()
        .help("Resets \(resetText)")
    }
}
