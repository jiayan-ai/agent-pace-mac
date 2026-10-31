import Foundation

/// Recorded token counts, including cached input. These are not quota percentages.
public struct TokenCounts: Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationInputTokens: Int64
    public let cacheReadInputTokens: Int64
    public let total: Int64

    public init?(inputTokens: Int64, outputTokens: Int64, cacheCreationInputTokens: Int64,
                 cacheReadInputTokens: Int64) {
        let values = [inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens]
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }
        var sum: Int64 = 0
        for value in values {
            let addition = sum.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            sum = addition.partialValue
        }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.total = sum
    }

    fileprivate func adding(_ other: TokenCounts) -> TokenCounts? {
        let sums = zip(values, other.values).map { $0.addingReportingOverflow($1) }
        guard sums.allSatisfy({ !$0.overflow }) else { return nil }
        return TokenCounts(inputTokens: sums[0].partialValue, outputTokens: sums[1].partialValue,
                           cacheCreationInputTokens: sums[2].partialValue, cacheReadInputTokens: sums[3].partialValue)
    }

    fileprivate func maximum(_ other: TokenCounts) -> TokenCounts? {
        TokenCounts(inputTokens: max(inputTokens, other.inputTokens),
                    outputTokens: max(outputTokens, other.outputTokens),
                    cacheCreationInputTokens: max(cacheCreationInputTokens, other.cacheCreationInputTokens),
                    cacheReadInputTokens: max(cacheReadInputTokens, other.cacheReadInputTokens))
    }

    private var values: [Int64] { [inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens] }
}

/// Only local retained Code transcripts are covered, potentially from multiple accounts.
/// A nil period has no valid recorded requests; it must not be displayed as zero usage.
public struct ClaudeTokenSnapshot: Equatable, Sendable {
    public let today: TokenCounts?
    public let last30Days: TokenCounts?
    public let recordedDays: Int
    public let requests: Int
    public let fetchedAt: Date
    public let partial: Bool
    public let hasFiles: Bool
    public let desktopRequests: Int
    public let cliRequests: Int

    public func isCurrentDay(now: Date, calendar: Calendar, scannedTimeZoneID: String?) -> Bool {
        fetchedAt <= now && calendar.isDate(fetchedAt, inSameDayAs: now) &&
            scannedTimeZoneID == calendar.timeZone.identifier
    }
}

public enum ClaudeLocalTokens {
    public struct Limits: Sendable {
        public var maxFiles: Int
        public var maxBytes: Int
        public var maxLineBytes: Int
        public var maxRecords: Int
        public var maxEntries: Int
        public var maxSeconds: TimeInterval

        public init(maxFiles: Int = 10_000, maxBytes: Int = 256 * 1024 * 1024,
                    maxLineBytes: Int = 2 * 1024 * 1024, maxRecords: Int = 250_000,
                    maxEntries: Int = 100_000, maxSeconds: TimeInterval = 20) {
            self.maxFiles = maxFiles; self.maxBytes = maxBytes; self.maxLineBytes = maxLineBytes
            self.maxRecords = maxRecords; self.maxEntries = maxEntries; self.maxSeconds = maxSeconds
        }
    }

    /// Runs the bounded reader off the main thread; completion is delivered on the main queue.
    public static func readAsync(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 now: Date = Date(), calendar: Calendar = .current,
                                 limits: Limits = Limits(), completion: @escaping (ClaudeTokenSnapshot) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = read(home: home, now: now, calendar: calendar, limits: limits)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Synchronous for deterministic tests. App callers should use readAsync or a background queue.
    /// No transcript content, account data, or credentials are retained or returned.
    public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            now: Date = Date(), calendar: Calendar = .current,
                            limits: Limits = Limits()) -> ClaudeTokenSnapshot {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let reader = Reader(now: now, calendar: calendar, limits: limits)
        return reader.read(root: root)
    }

    private struct Header: Decodable {
        let type: String?
        let entrypoint: String?
    }

    private struct Envelope: Decodable {
        let type: String?
        let entrypoint: String?
        let sessionId: String?
        let requestId: String?
        let timestamp: String?
        let isApiErrorMessage: Bool?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int64?
            let output_tokens: Int64?
            let cache_creation_input_tokens: Int64?
            let cache_read_input_tokens: Int64?

            var counts: TokenCounts? {
                guard let input_tokens, let output_tokens, let cache_creation_input_tokens,
                      let cache_read_input_tokens else { return nil }
                return TokenCounts(inputTokens: input_tokens, outputTokens: output_tokens,
                                   cacheCreationInputTokens: cache_creation_input_tokens,
                                   cacheReadInputTokens: cache_read_input_tokens)
            }
        }
    }

    private struct RecordKey: Hashable {
        let kind: String
        let scope: String
        let messageID: String
    }

    private struct Record {
        var counts: TokenCounts
        var date: Date
        var entrypoint: String?
    }

    private final class Reader {
        let now: Date
        let calendar: Calendar
        let limits: Limits
        let start: Date
        let today: Date
        let started = ProcessInfo.processInfo.systemUptime
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        let standard = ISO8601DateFormatter()
        var partial = false
        var hasFiles = false
        var bytesRead = 0
        var records: [RecordKey: Record] = [:]

        init(now: Date, calendar: Calendar, limits: Limits) {
            self.now = now; self.calendar = calendar; self.limits = limits
            today = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            standard.formatOptions = [.withInternetDateTime]
        }

        var exhausted: Bool {
            bytesRead >= limits.maxBytes || records.count >= limits.maxRecords ||
                ProcessInfo.processInfo.systemUptime - started >= limits.maxSeconds
        }

        func read(root: URL) -> ClaudeTokenSnapshot {
            let manager = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
            guard manager.fileExists(atPath: root.path) else { return snapshot() }
            // Do not follow a redirected source into an unrelated location.
            if root.resolvingSymlinksInPath().standardizedFileURL != root.standardizedFileURL {
                partial = true; return snapshot()
            }
            guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: { [weak self] _, _ in self?.partial = true; return true }) else {
                partial = true; return snapshot()
            }
            var files: [(URL, Date)] = []
            var entries = 0
            for case let url as URL in iterator {
                entries += 1
                if entries > limits.maxEntries || ProcessInfo.processInfo.systemUptime - started >= limits.maxSeconds {
                    partial = true; break
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { partial = true; continue }
                if values.isSymbolicLink == true { iterator.skipDescendants(); partial = true; continue }
                if values.isDirectory == true && ["tool-results", "memory", "mcp-tasks", "node_modules"].contains(url.lastPathComponent) {
                    iterator.skipDescendants(); continue
                }
                guard values.isRegularFile == true, url.pathExtension.lowercased() == "jsonl" else { continue }
                hasFiles = true
                guard files.count < limits.maxFiles else { partial = true; break }
                files.append((url, values.contentModificationDate ?? .distantPast))
            }
            // With a resource cap, prefer the latest available records.
            for (file, _) in files.sorted(by: { $0.1 > $1.1 }) {
                if exhausted { partial = true; break }
                readFile(file)
            }
            return snapshot()
        }

        func readFile(_ url: URL) {
            guard let stream = InputStream(url: url) else { partial = true; return }
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var line = Data()
            var skippingLongLine = false
            while !exhausted {
                let allowance = min(buffer.count, max(0, limits.maxBytes - bytesRead))
                guard allowance > 0 else { partial = true; return }
                let count = stream.read(&buffer, maxLength: allowance)
                if count == 0 {
                    if !line.isEmpty && !skippingLongLine { consume(line) }
                    return
                }
                if count < 0 { partial = true; return }
                bytesRead += count
                for byte in buffer.prefix(count) {
                    if byte == 10 {
                        if !skippingLongLine && !line.isEmpty { consume(line) }
                        line.removeAll(keepingCapacity: true)
                        skippingLongLine = false
                    } else if !skippingLongLine {
                        if line.count < limits.maxLineBytes { line.append(byte) }
                        else { partial = true; skippingLongLine = true; line.removeAll(keepingCapacity: true) }
                    }
                }
            }
            partial = true
        }

        func consume(_ data: Data) {
            guard let header = try? decoder.decode(Header.self, from: data) else { partial = true; return }
            guard header.type == "assistant", header.entrypoint?.lowercased() != "local-agent",
                  header.entrypoint?.lowercased() != "cowork" else { return }
            guard let row = try? decoder.decode(Envelope.self, from: data) else { partial = true; return }
            guard row.isApiErrorMessage != true,
                  row.message?.model != "<synthetic>" else { return }
            guard let text = row.timestamp, let date = fractional.date(from: text) ?? standard.date(from: text) else {
                partial = true; return
            }
            guard date >= start, date <= now else { return }
            guard let messageID = row.message?.id, !messageID.isEmpty, messageID.count <= 512,
                  let counts = row.message?.usage?.counts else { partial = true; return }
            let key: RecordKey
            if let request = row.requestId, !request.isEmpty, request.count <= 512 {
                key = RecordKey(kind: "request", scope: request, messageID: messageID)
            } else if let session = row.sessionId, !session.isEmpty, session.count <= 512 {
                key = RecordKey(kind: "session", scope: session, messageID: messageID)
            } else { partial = true; return }
            if var prior = records[key] {
                guard let merged = prior.counts.maximum(counts) else { partial = true; return }
                prior.counts = merged
                prior.date = min(prior.date, date)
                if prior.entrypoint == nil { prior.entrypoint = row.entrypoint }
                records[key] = prior
            } else if records.count < limits.maxRecords {
                records[key] = Record(counts: counts, date: date, entrypoint: row.entrypoint)
            } else { partial = true }
        }

        func snapshot() -> ClaudeTokenSnapshot {
            var aggregate: TokenCounts?
            var daily: TokenCounts?
            var days = Set<Date>()
            var requests = 0, desktop = 0, cli = 0
            for record in records.values {
                let sum = aggregate == nil ? record.counts : aggregate!.adding(record.counts)
                guard let sum else { partial = true; continue }
                let isToday = record.date >= today
                var daySum = daily
                if isToday {
                    daySum = daily == nil ? record.counts : daily!.adding(record.counts)
                    guard daySum != nil else { partial = true; continue }
                }
                aggregate = sum; daily = daySum
                days.insert(calendar.startOfDay(for: record.date))
                requests += 1
                if record.entrypoint == "claude-desktop" { desktop += 1 }
                if record.entrypoint == "cli" { cli += 1 }
            }
            return ClaudeTokenSnapshot(today: daily, last30Days: aggregate, recordedDays: days.count,
                                       requests: requests, fetchedAt: now, partial: partial, hasFiles: hasFiles,
                                       desktopRequests: desktop, cliRequests: cli)
        }
    }
}
