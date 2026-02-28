import Foundation

/// GitHub integration via the `gh` CLI tool.
public final class GhCliAdapter: PRTrackerPort, @unchecked Sendable {

    public init() {}

    public func fetchPRs(repoRoot: String) async throws -> [String: PullRequest] {
        let result = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: [
                "gh", "pr", "list", "--state", "all", "--limit", "50",
                "--json", "number,title,state,url,headRefName,reviewDecision",
            ],
            currentDirectory: repoRoot
        )

        guard result.succeeded, !result.stdout.isEmpty else { return [:] }
        guard let data = result.stdout.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var prs: [String: PullRequest] = [:]
        for item in items {
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let state = item["state"] as? String,
                  let url = item["url"] as? String,
                  let headRefName = item["headRefName"] as? String else {
                continue
            }

            let reviewDecision = item["reviewDecision"] as? String
            let pr = PullRequest(
                number: number,
                title: title,
                state: state.lowercased() == "merged" ? "merged" : state.lowercased(),
                url: url,
                headRefName: headRefName,
                reviewDecision: reviewDecision
            )
            prs[headRefName] = pr
        }

        return prs
    }

    public func enrichPRDetails(repoRoot: String, prs: inout [String: PullRequest]) async throws {
        let openPRs = prs.values.filter { $0.state == "open" }
        guard !openPRs.isEmpty else { return }

        // Build GraphQL query with aliases for each PR
        var queryParts: [String] = []
        var aliasMap: [String: String] = [:] // alias → branch

        for (i, pr) in openPRs.enumerated() {
            let alias = "pr\(i)"
            aliasMap[alias] = pr.headRefName
            queryParts.append("""
            \(alias): pullRequest(number: \(pr.number)) {
              reviewDecision
              reviewThreads(first: 100) { nodes { isResolved } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            }
            """)
        }

        // Get repo owner/name
        let repoResult = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: ["gh", "repo", "view", "--json", "owner,name"],
            currentDirectory: repoRoot
        )
        guard repoResult.succeeded,
              let repoData = repoResult.stdout.data(using: .utf8),
              let repoInfo = try? JSONSerialization.jsonObject(with: repoData) as? [String: Any],
              let owner = repoInfo["owner"] as? [String: Any],
              let ownerLogin = owner["login"] as? String,
              let repoName = repoInfo["name"] as? String else {
            return
        }

        let query = """
        query {
          repository(owner: "\(ownerLogin)", name: "\(repoName)") {
            \(queryParts.joined(separator: "\n"))
          }
        }
        """

        let graphqlResult = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: ["gh", "api", "graphql", "-f", "query=\(query)"],
            currentDirectory: repoRoot
        )

        guard graphqlResult.succeeded,
              let gqlData = graphqlResult.stdout.data(using: .utf8),
              let gqlRoot = try? JSONSerialization.jsonObject(with: gqlData) as? [String: Any],
              let dataObj = gqlRoot["data"] as? [String: Any],
              let repo = dataObj["repository"] as? [String: Any] else {
            return
        }

        for (alias, branch) in aliasMap {
            guard var pr = prs[branch],
                  let prData = repo[alias] as? [String: Any] else {
                continue
            }

            // Review decision
            if let decision = prData["reviewDecision"] as? String {
                pr.reviewDecision = decision
            }

            // Unresolved threads
            if let threads = prData["reviewThreads"] as? [String: Any],
               let nodes = threads["nodes"] as? [[String: Any]] {
                pr.unresolvedThreads = nodes.filter { ($0["isResolved"] as? Bool) == false }.count
            }

            // CI status
            if let commits = prData["commits"] as? [String: Any],
               let commitNodes = commits["nodes"] as? [[String: Any]],
               let lastCommit = commitNodes.last,
               let commit = lastCommit["commit"] as? [String: Any],
               let rollup = commit["statusCheckRollup"] as? [String: Any],
               let state = rollup["state"] as? String {
                switch state.uppercased() {
                case "SUCCESS": pr.checksStatus = .pass
                case "FAILURE", "ERROR": pr.checksStatus = .fail
                case "PENDING": pr.checksStatus = .pending
                default: break
                }
            }

            prs[branch] = pr
        }
    }

    public func isAvailable() async -> Bool {
        let available = await ShellCommand.isAvailable("gh")
        guard available else { return false }

        // Check auth status
        do {
            let result = try await ShellCommand.run("/usr/bin/env", arguments: ["gh", "auth", "status"])
            return result.succeeded
        } catch {
            return false
        }
    }

    /// Fetch GitHub issues matching a filter query.
    public func fetchIssues(repoRoot: String, filter: String) async throws -> [GitHubIssue] {
        let result = try await ShellCommand.run(
            "/usr/bin/env",
            arguments: [
                "gh", "search", "issues", "--match", "title,body",
                "--json", "number,title,body,url,labels",
                "--limit", "25",
                filter,
            ],
            currentDirectory: repoRoot
        )

        guard result.succeeded, !result.stdout.isEmpty else { return [] }
        guard let data = result.stdout.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> GitHubIssue? in
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let url = item["url"] as? String else {
                return nil
            }
            let body = item["body"] as? String
            let labels = (item["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return GitHubIssue(number: number, title: title, body: body, url: url, labels: labels)
        }
    }
}

/// A GitHub issue for the backlog.
public struct GitHubIssue: Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let body: String?
    public let url: String
    public let labels: [String]
}
