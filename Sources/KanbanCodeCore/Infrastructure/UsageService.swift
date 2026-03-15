import Foundation

public struct UsageData: Sendable {
    public let fiveHourUtilization: Double  // 0-100
    public let fiveHourResetsAt: Date?
    public let sevenDayUtilization: Double  // 0-100
    public let sevenDayResetsAt: Date?

    public static let empty = UsageData(
        fiveHourUtilization: 0, fiveHourResetsAt: nil,
        sevenDayUtilization: 0, sevenDayResetsAt: nil
    )
}

public actor UsageService {
    private var cachedData: UsageData = .empty
    private var timer: Task<Void, Never>?

    public init() {}

    public func start() {
        timer = Task {
            while !Task.isCancelled {
                await fetchUsage()
                try? await Task.sleep(for: .seconds(600)) // 10 minutes
            }
        }
    }

    public func stop() {
        timer?.cancel()
    }

    public func currentUsage() -> UsageData {
        cachedData
    }

    private func fetchUsage() async {
        guard let token = getOAuthToken() else { return }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.72", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]

        cachedData = UsageData(
            fiveHourUtilization: fiveHour?["utilization"] as? Double ?? 0,
            fiveHourResetsAt: (fiveHour?["resets_at"] as? String).flatMap { iso.date(from: $0) },
            sevenDayUtilization: sevenDay?["utilization"] as? Double ?? 0,
            sevenDayResetsAt: (sevenDay?["resets_at"] as? String).flatMap { iso.date(from: $0) }
        )
    }

    private func getOAuthToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let jsonStr = String(data: data, encoding: .utf8),
              let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
