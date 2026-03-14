import Testing
import Foundation
@testable import KanbanCodeCore

struct ProjectColorTests {
    @Test func project_hasDefaultColor() {
        let project = Project(path: "/tmp/test")
        #expect(project.color == "#808080") // default gray
    }

    @Test func project_acceptsCustomColor() {
        let project = Project(path: "/tmp/test", color: "#4A90D9")
        #expect(project.color == "#4A90D9")
    }

    @Test func project_colorSurvivesEncoding() throws {
        let project = Project(path: "/tmp/test", color: "#FF5733")
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.color == "#FF5733")
    }
}
