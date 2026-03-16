import SwiftUI
import ClaudeBoardCore

enum UsageResetDisplay {
    case countdown   // "3h 22m"
    case weekday     // "Friday 10:00"
}

struct UsageBarView: View {
    let label: String
    let utilization: Double  // 0-100
    let resetsAt: Date?
    var resetDisplay: UsageResetDisplay = .countdown

    /// Total duration of the usage window in seconds.
    var windowDuration: TimeInterval = 5 * 3600

    private var elapsedFraction: Double {
        guard let resets = resetsAt else { return 0 }
        let remaining = resets.timeIntervalSinceNow
        return max(0, min(1, 1.0 - remaining / windowDuration))
    }

    private var fillColor: Color {
        let pace = UsagePaceColor.calculate(utilization: utilization, elapsedFraction: elapsedFraction)
        switch pace {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        }
    }

    private var resetLabel: String {
        guard let date = resetsAt else { return "" }
        switch resetDisplay {
        case .countdown:
            let diff = date.timeIntervalSince(.now)
            guard diff > 0 else { return "now" }
            let hours = Int(diff) / 3600
            let mins = (Int(diff) % 3600) / 60
            return "\(hours)h \(mins)m"
        case .weekday:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE HH:mm"
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
    }

    private var percentText: String {
        "\(Int(utilization))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(resetLabel)
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
            .frame(width: 360, height: 8)

            Text(percentText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .fixedSize()
    }
}
