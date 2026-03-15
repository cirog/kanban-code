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

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor.opacity(0.8))
                        .frame(width: geo.size.width * min(utilization / 100, 1.0))
                }
            }
            .frame(width: 60, height: 8)

            Text("\(Int(utilization))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .help("Resets \(resetText)")
    }
}
