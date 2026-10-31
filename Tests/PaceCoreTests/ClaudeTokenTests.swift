import Foundation
import PaceCore

struct ClaudeTokenTests {
    func testSnapshotDateAndTimeZoneFreshness() throws {
        let date = try require(ISO8601DateFormatter().date(from: "2026-11-01T23:59:00-08:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let snapshot = ClaudeLocalTokens.read(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                              now: date, calendar: calendar)
        try expect(snapshot.isCurrentDay(now: date.addingTimeInterval(30), calendar: calendar, scannedTimeZoneID: calendar.timeZone.identifier))
        try expect(!snapshot.isCurrentDay(now: date.addingTimeInterval(120), calendar: calendar, scannedTimeZoneID: calendar.timeZone.identifier))
        try expect(!snapshot.isCurrentDay(now: date.addingTimeInterval(-1), calendar: calendar, scannedTimeZoneID: calendar.timeZone.identifier))
        try expect(!snapshot.isCurrentDay(now: date, calendar: calendar, scannedTimeZoneID: "America/New_York"))
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pace-claude-tokens-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private func save(_ rows: [String], home: URL, file: String = "project/session.jsonl") throws {
        let url = home.appendingPathComponent(".claude/projects/" + file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func row(id: String = "message", request: String? = "request", session: String = "session",
                     timestamp: String = "2026-10-31T10:00:00Z", entrypoint: String? = "claude-desktop",
                     input: String = "10", output: String = "20", write: String = "30", read: String = "40",
                     extraUsage: String = "", model: String = "claude-test") -> String {
        let requestField = request.map { ",\"requestId\":\"\($0)\"" } ?? ""
        let entrypointField = entrypoint.map { ",\"entrypoint\":\"\($0)\"" } ?? ""
        return """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"\(session)"\(requestField)\(entrypointField),"message":{"id":"\(id)","model":"\(model)","content":[{"type":"text","text":"UNREAD_CONVERSATION"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(write),"cache_read_input_tokens":\(read)\(extraUsage)}}}
        """
    }

    func testDesktopDeduplicationStreamingAndCacheCounts() throws {
        try fixture { home in
            let initial = row(input: "5", output: "3", write: "30", read: "40")
            let final = row(extraUsage: ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":30,\"ephemeral_1h_input_tokens\":0}")
            try save([initial, final, row(id: "agent", request: "agent", entrypoint: "local-agent")], home: home)
            try save([final, row(id: "cli", request: nil, entrypoint: "cli")], home: home, file: "other/subagents/agent.jsonl")
            try save([row(id: "cli", request: nil, entrypoint: "cli")], home: home, file: "copy/session.jsonl")
            let snapshot = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(snapshot.today?.total == 200 && snapshot.last30Days?.total == 200)
            try expect(snapshot.today?.inputTokens == 20 && snapshot.today?.outputTokens == 40)
            try expect(snapshot.today?.cacheCreationInputTokens == 60 && snapshot.today?.cacheReadInputTokens == 80)
            try expect(snapshot.requests == 2 && snapshot.recordedDays == 1)
            try expect(snapshot.desktopRequests == 1 && snapshot.cliRequests == 1)
            try expect(snapshot.hasFiles && !snapshot.partial)
        }
    }

    func testLocalDatesMissingPeriodsAndZeroRecords() throws {
        try fixture { home in
            let absent = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(!absent.hasFiles && absent.today == nil && absent.last30Days == nil && !absent.partial)
            // Oct 2 at local midnight is the first of 30 calendar days; Sep/Oct UTC labels alone are insufficient.
            try save([
                row(id: "before", request: "before", timestamp: "2026-10-02T06:59:59Z"),
                row(id: "first", request: "first", timestamp: "2026-10-02T07:00:00Z"),
                row(id: "yesterday", request: "yesterday", timestamp: "2026-10-31T06:59:59Z"),
                row(id: "future", request: "future", timestamp: "2026-11-01T01:00:00Z")
            ], home: home)
            let prior = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(prior.today == nil && prior.last30Days?.total == 200)
            try expect(prior.recordedDays == 2 && prior.requests == 2)
            try save([row(id: "zero", request: "zero", input: "0", output: "0", write: "0", read: "0")], home: home, file: "project/zero.jsonl")
            let zero = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(zero.today?.total == 0 && zero.last30Days?.total == 200 && zero.recordedDays == 3)
        }
    }

    func testInvalidCountsUnknownDataAndSafeOverflow() throws {
        try fixture { home in
            try save([
                row(id: "negative", request: "negative", input: "-1"),
                row(id: "fraction", request: "fraction", input: "1.5"),
                row(id: "bool", request: "bool", input: "true"),
                row(id: "null", request: "null", output: "null"),
                row(id: "large", request: "large", input: "9223372036854775808"),
                row(id: "sumOverflow", request: "sumOverflow", input: "9223372036854775807"),
                row(id: "synthetic", request: "synthetic", model: "<synthetic>"),
                "{\"type\":\"user\",\"message\":\"arbitrary ignored content\"}",
                row(id: "valid", request: "valid")
            ], home: home)
            let snapshot = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(snapshot.partial && snapshot.today?.total == 100 && snapshot.requests == 1)
            try expect(TokenCounts(inputTokens: .max, outputTokens: 1, cacheCreationInputTokens: 0, cacheReadInputTokens: 0) == nil)
            try save([row(input: "null")], home: home)
            let unknown = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(unknown.hasFiles && unknown.partial && unknown.today == nil && unknown.last30Days == nil)
        }
    }

    func testResourceLimitsAndUnreadableOrRedirectedData() throws {
        try fixture { home in
            try save([row(), String(repeating: "x", count: 1000), row(id: "second", request: "second")], home: home)
            let long = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar,
                                             limits: .init(maxLineBytes: 700))
            try expect(long.partial && long.requests == 2 && long.today?.total == 200)
            let bytes = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar,
                                              limits: .init(maxBytes: 10))
            try expect(bytes.partial && bytes.hasFiles && bytes.today == nil)
            let files = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar,
                                              limits: .init(maxFiles: 0))
            try expect(files.partial && files.hasFiles && files.last30Days == nil)
            let records = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar,
                                                limits: .init(maxRecords: 1))
            try expect(records.partial && records.requests == 1)
            let target = home.appendingPathComponent(".claude/projects/project/session.jsonl")
            let link = home.appendingPathComponent(".claude/projects/project/link.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let symlink = ClaudeLocalTokens.read(home: home, now: now, calendar: calendar)
            try expect(symlink.partial && symlink.requests == 2)
        }
    }
}
