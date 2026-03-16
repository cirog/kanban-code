import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("ProjectDiscovery")
struct ProjectDiscoveryTests {

    @Test("Finds unconfigured paths")
    func findsUnconfigured() {
        let projects = [
            Project(path: "/Users/test/Projects/langwatch"),
        ]
        let sessionPaths: [String?] = [
            "/Users/test/Projects/langwatch",
            "/Users/test/Projects/scenario",
            "/Users/test/Projects/kanban",
        ]

        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: sessionPaths,
            configuredProjects: projects
        )

        #expect(result.count == 2)
        #expect(result.contains("/Users/test/Projects/scenario"))
        #expect(result.contains("/Users/test/Projects/kanban"))
    }

    @Test("Ignores subdirectories of configured projects")
    func ignoresSubdirs() {
        let projects = [
            Project(path: "/Users/test/Projects/langwatch-saas"),
        ]
        let sessionPaths: [String?] = [
            "/Users/test/Projects/langwatch-saas/langwatch",
            "/Users/test/Projects/langwatch-saas/api",
            "/Users/test/Projects/other",
        ]

        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: sessionPaths,
            configuredProjects: projects
        )

        #expect(result.count == 1)
        #expect(result[0] == "/Users/test/Projects/other")
    }

    @Test("Deduplicates paths")
    func deduplicates() {
        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: [
                "/Users/test/foo",
                "/Users/test/foo",
                "/Users/test/foo",
            ],
            configuredProjects: []
        )

        #expect(result.count == 1)
    }

    @Test("Skips nil and empty paths")
    func skipsNilAndEmpty() {
        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: [nil, "", nil, "/Users/test/real"],
            configuredProjects: []
        )

        #expect(result.count == 1)
        #expect(result[0] == "/Users/test/real")
    }

    @Test("Returns sorted results")
    func sortedResults() {
        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: ["/z/path", "/a/path", "/m/path"],
            configuredProjects: []
        )

        #expect(result == ["/a/path", "/m/path", "/z/path"])
    }

    @Test("Empty inputs returns empty")
    func emptyInputs() {
        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: [],
            configuredProjects: []
        )

        #expect(result.isEmpty)
    }

    @Test("Normalizes trailing slashes")
    func normalizesTrailingSlash() {
        let projects = [
            Project(path: "/Users/test/Projects/langwatch"),
        ]
        let sessionPaths: [String?] = [
            "/Users/test/Projects/langwatch/",
        ]

        let result = ProjectDiscovery.findUnconfiguredPaths(
            sessionPaths: sessionPaths,
            configuredProjects: projects
        )

        #expect(result.isEmpty)
    }
}
