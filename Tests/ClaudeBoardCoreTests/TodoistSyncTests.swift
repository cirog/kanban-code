import Testing
@testable import ClaudeBoardCore

struct TodoistSyncTests {
    @Test("Parse valid JSON with one task")
    func parseSingleTask() throws {
        let json = """
        [{"id":"123","content":"Fix bug","description":"Some details","labels":["claude"],"priority":1}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks.count == 1)
        #expect(tasks[0].id == "123")
        #expect(tasks[0].content == "Fix bug")
        #expect(tasks[0].description == "Some details")
    }

    @Test("Parse empty array")
    func parseEmpty() throws {
        let tasks = try TodoistSyncService.parseTasks(from: "[]")
        #expect(tasks.isEmpty)
    }

    @Test("Parse multiple tasks")
    func parseMultiple() throws {
        let json = """
        [{"id":"1","content":"Task A"},{"id":"2","content":"Task B","description":"Details B"}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks.count == 2)
        #expect(tasks[1].description == "Details B")
    }

    @Test("Parse skips items without id")
    func parseSkipsInvalid() throws {
        let json = """
        [{"content":"No ID task"},{"id":"1","content":"Valid"}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks.count == 1)
        #expect(tasks[0].id == "1")
    }

    @Test("Parse handles non-array JSON gracefully")
    func parseNonArray() throws {
        let tasks = try TodoistSyncService.parseTasks(from: "{\"key\":\"value\"}")
        #expect(tasks.isEmpty)
    }

    // MARK: - Extra Todoist Fields

    @Test("Parse extracts priority field")
    func parsePriority() throws {
        let json = """
        [{"id":"1","content":"Task","priority":3}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks[0].priority == 3)
    }

    @Test("Parse extracts due date string")
    func parseDueDate() throws {
        let json = """
        [{"id":"1","content":"Task","due":{"date":"2026-03-20","string":"Mar 20"}}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks[0].due == "2026-03-20")
    }

    @Test("Parse extracts labels array")
    func parseLabels() throws {
        let json = """
        [{"id":"1","content":"Task","labels":["claude","urgent"]}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks[0].labels == ["claude", "urgent"])
    }

    @Test("Parse extracts project_id")
    func parseProjectId() throws {
        let json = """
        [{"id":"1","content":"Task","project_id":"proj_abc"}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks[0].projectId == "proj_abc")
    }

    @Test("Parse defaults priority to 1 when missing")
    func parseDefaultPriority() throws {
        let json = """
        [{"id":"1","content":"Task"}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks[0].priority == 1)
    }

    @Test("Parse handles null due gracefully")
    func parseNullDue() throws {
        let json = """
        [{"id":"1","content":"Task","due":null}]
        """
        let tasks = try TodoistSyncService.parseTasks(from: json)
        #expect(tasks[0].due == nil)
    }
}
