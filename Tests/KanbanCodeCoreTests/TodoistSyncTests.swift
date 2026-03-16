import Testing
@testable import KanbanCodeCore

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
}
