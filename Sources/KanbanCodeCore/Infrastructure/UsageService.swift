import Foundation

public struct UsageData: Sendable {
    public let fiveHourUtilization: Double  // 0-100
    public let fiveHourResetsAt: Date?
    public let sevenDayUtilization: Double  // 0-100
    public let sevenDayResetsAt: Date?
    public let lastFetchError: String?
    public let lastFetchTime: Date?

    public static let empty = UsageData(
        fiveHourUtilization: 0, fiveHourResetsAt: nil,
        sevenDayUtilization: 0, sevenDayResetsAt: nil,
        lastFetchError: nil, lastFetchTime: nil
    )
}

public actor UsageService {
    private var cachedData: UsageData = .empty
    private var timer: Task<Void, Never>?

    public init() {}

    public func start() {
        timer = Task {
            // First fetch — retry once after 10s if it fails
            await fetchUsage()
            if cachedData.lastFetchError != nil {
                KanbanCodeLog.info("usage", "First fetch failed, retrying in 10s...")
                try? await Task.sleep(for: .seconds(10))
                await fetchUsage()
            }
            // Then poll every 5 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await fetchUsage()
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
        guard let token = getOAuthToken() else {
            KanbanCodeLog.info("usage", "Failed to get OAuth token from keychain")
            cachedData = UsageData(
                fiveHourUtilization: cachedData.fiveHourUtilization,
                fiveHourResetsAt: cachedData.fiveHourResetsAt,
                sevenDayUtilization: cachedData.sevenDayUtilization,
                sevenDayResetsAt: cachedData.sevenDayResetsAt,
                lastFetchError: "No OAuth token",
                lastFetchTime: cachedData.lastFetchTime
            )
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.72", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            KanbanCodeLog.info("usage", "Network error: \(error.localizedDescription)")
            cachedData = UsageData(
                fiveHourUtilization: cachedData.fiveHourUtilization,
                fiveHourResetsAt: cachedData.fiveHourResetsAt,
                sevenDayUtilization: cachedData.sevenDayUtilization,
                sevenDayResetsAt: cachedData.sevenDayResetsAt,
                lastFetchError: "Network: \(error.localizedDescription)",
                lastFetchTime: cachedData.lastFetchTime
            )
            return
        }

        // Check HTTP status
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            KanbanCodeLog.info("usage", "HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            cachedData = UsageData(
                fiveHourUtilization: cachedData.fiveHourUtilization,
                fiveHourResetsAt: cachedData.fiveHourResetsAt,
                sevenDayUtilization: cachedData.sevenDayUtilization,
                sevenDayResetsAt: cachedData.sevenDayResetsAt,
                lastFetchError: "HTTP \(httpResponse.statusCode)",
                lastFetchTime: cachedData.lastFetchTime
            )
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            KanbanCodeLog.info("usage", "Failed to parse JSON response")
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]

        let newData = UsageData(
            fiveHourUtilization: fiveHour?["utilization"] as? Double ?? 0,
            fiveHourResetsAt: (fiveHour?["resets_at"] as? String).flatMap { iso.date(from: $0) },
            sevenDayUtilization: sevenDay?["utilization"] as? Double ?? 0,
            sevenDayResetsAt: (sevenDay?["resets_at"] as? String).flatMap { iso.date(from: $0) },
            lastFetchError: nil,
            lastFetchTime: .now
        )

        KanbanCodeLog.info("usage", "Fetched: 5h=\(newData.fiveHourUtilization)% 7d=\(newData.sevenDayUtilization)%")
        cachedData = newData
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
