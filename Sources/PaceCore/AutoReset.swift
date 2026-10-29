import Foundation
import Darwin

/// Selects only a specific, known, unexpired Codex credit in its final five minutes.
public enum AutoResetPolicy {
    public static let leadTime: TimeInterval = 300

    public static func candidate(credits: ResetCredits?, now: Date) -> ResetCredit? {
        guard let credits, credits.availableCount > 0 else { return nil }
        return (credits.credits ?? []).filter {
            guard $0.status == "available", $0.resetType == "codexRateLimits", !$0.id.isEmpty,
                  let expiry = $0.expiryDate else { return false }
            let remaining = expiry.timeIntervalSince(now)
            return remaining > 0 && remaining <= leadTime
        }.sorted {
            if $0.expiryDate == $1.expiryDate { return $0.id < $1.id }
            return $0.expiryDate! < $1.expiryDate!
        }.first
    }
}

public enum AutoResetOutcome: String, Codable {
    case reset, nothingToReset, noCredit, alreadyRedeemed
}

public enum ResetRedemptionMode {
    case automatic
    case manual(expectedExpiry: Date?)
}

public enum ManualResetPolicy {
    public static func credit(id: String, credits: ResetCredits?, now: Date) -> ResetCredit? {
        guard !id.isEmpty, let credits, credits.availableCount > 0 else { return nil }
        let matches = (credits.credits ?? []).filter { $0.id == id }
        guard matches.count == 1, let credit = matches.first,
              credit.status == "available", credit.resetType == "codexRateLimits",
              credit.expiresAt == nil || credit.expiresAt.map({ $0.isFinite && $0 <= 253_402_300_799 }) == true,
              credit.expiresAt == nil || credit.expiryDate.map({ $0 > now }) == true else { return nil }
        return credit
    }
}

public enum AutoResetError: LocalizedError {
    case accountChanged, creditChanged, disabled, beforeSend(String)
    public var errorDescription: String? {
        switch self {
        case .disabled: return L("自动 Reset 已关闭。")
        case .accountChanged: return L("Codex 账户已变化，已取消本次 Reset。")
        case .creditChanged: return L("Reset 券状态已变化，已取消本次操作。")
        case .beforeSend(let message): return message
        }
    }
}

private enum AutoResetDisk {
    static func write(_ data: Data, to file: URL, syncDirectory: Bool = true) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".auto-reset-" + UUID().uuidString)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw AutoResetJournalError.storage }
        defer { close(fd); try? FileManager.default.removeItem(at: temp) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, rename(temp.path, file.path) == 0 else { throw AutoResetJournalError.storage }
        // Syncing the directory makes the rename durable before the caller sends a request.
        guard syncDirectory else { return }
        let dirFD = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard dirFD >= 0 else { throw AutoResetJournalError.storage }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0 else { throw AutoResetJournalError.storage }
    }
}

/// A process-wide and cross-process journal; a crash after dispatch retains the same key.
public enum AutoResetJournal {
    private struct Attempt: Codable {
        var key: String
        var outcome: AutoResetOutcome?
        var completedAt: Date?
        var resolvedAt: Date?
    }
    private struct State: Codable { var attempts: [String: Attempt] = [:] }

    public static func perform(directory: URL, accountKey: String, creditID: String,
                               retryKnownUnused: Bool = false,
                               redeem: (String) throws -> AutoResetOutcome) throws -> AutoResetOutcome {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("auto-reset.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AutoResetJournalError.storage }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AutoResetJournalError.busy }
        defer { flock(fd, LOCK_UN) }
        let file = directory.appendingPathComponent("auto-reset.json")
        var state: State
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else { state = State() }
        let entryID = accountKey + ":" + creditID
        if let outcome = state.attempts[entryID]?.outcome {
            if retryKnownUnused && (outcome == .nothingToReset || outcome == .noCredit) {
                state.attempts.removeValue(forKey: entryID)
            } else { return outcome }
        }
        if state.attempts[entryID]?.resolvedAt != nil { throw AutoResetJournalError.resolved }
        if state.attempts.contains(where: { id, attempt in
            id.hasPrefix(accountKey + ":") && id != entryID && attempt.outcome == nil && attempt.resolvedAt == nil
        }) { throw AutoResetJournalError.unconfirmed }
        // A successful redemption resets the same pool; prevent consuming multiple credits together.
        if state.attempts.contains(where: { id, attempt in
            id.hasPrefix(accountKey + ":") && (attempt.outcome == .reset || attempt.outcome == .alreadyRedeemed) &&
            attempt.completedAt.map { Date().timeIntervalSince($0) < 300 } == true
        }) { throw AutoResetJournalError.cooldown }
        let isNew = state.attempts[entryID] == nil
        if isNew { state.attempts[entryID] = Attempt(key: UUID().uuidString) }
        func save(_ state: State) throws {
            try AutoResetDisk.write(JSONEncoder().encode(state), to: file)
        }
        // Fail closed when durable storage is unavailable.
        try save(state)
        let outcome: AutoResetOutcome
        do { outcome = try redeem(state.attempts[entryID]!.key) }
        catch {
            // These failures occur before the consume request is sent. Preserve an older
            // uncertain attempt, which may already have reached the server.
            if isNew, error is AutoResetError {
                state.attempts.removeValue(forKey: entryID)
                try save(state)
            }
            throw error
        }
        state.attempts[entryID]!.outcome = outcome
        state.attempts[entryID]!.completedAt = Date()
        try save(state)
        return outcome
    }

    public static func hasUnconfirmed(directory: URL, accountKey: String) throws -> Bool {
        try access(directory: directory, save: false) { state in
            state.attempts.contains { $0.key.hasPrefix(accountKey + ":") && $0.value.outcome == nil && $0.value.resolvedAt == nil }
        }
    }

    public static func clearUnconfirmed(directory: URL, accountKey: String) throws {
        try access(directory: directory) { state in
            for id in state.attempts.keys where id.hasPrefix(accountKey + ":") {
                if state.attempts[id]?.outcome == nil && state.attempts[id]?.resolvedAt == nil {
                    state.attempts[id]?.resolvedAt = Date()
                }
            }
        }
    }

    private static func access<T>(directory: URL, save: Bool = true, body: (inout State) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("auto-reset.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AutoResetJournalError.storage }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AutoResetJournalError.busy }
        defer { flock(fd, LOCK_UN) }
        let file = directory.appendingPathComponent("auto-reset.json")
        var state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : State()
        let value = try body(&state)
        if save {
            try AutoResetDisk.write(JSONEncoder().encode(state), to: file)
        }
        return value
    }
}

public enum AutoResetJournalError: LocalizedError {
    case storage, busy, cooldown, unconfirmed, resolved
    public var errorDescription: String? {
        switch self {
        case .resolved: return L("此券的未确认记录已由你核实；如仍需使用，请在 Codex 操作。")
        case .unconfirmed: return L("上次 Reset 的结果尚未确认，请在 Codex 核实后解除暂停。")
        case .storage: return L("无法保存 Reset 记录，操作已暂停。")
        case .busy: return L("Reset 正在处理，请稍后再试。")
        case .cooldown: return L("刚完成一次 Reset，暂不连续使用另一张。")
        }
    }
}

/// Coordinates the account-bound authorization across app processes.
public enum AutoResetAuthorization {
    private static let lock = NSLock()
    private static var locallyRevoked = false
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPace")
    }
    private struct Grant: Codable { let accountKey: String? }
    private static func locked<T>(directory: URL?, body: (URL) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let directory = directory ?? defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("auto-reset-authorization.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AutoResetJournalError.storage }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AutoResetJournalError.storage }
        defer { flock(fd, LOCK_UN) }
        return try body(directory.appendingPathComponent("auto-reset-authorization.json"))
    }
    private static func read(_ file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Grant.self, from: Data(contentsOf: file)).accountKey
    }
    public static func authorizedAccount(directory: URL? = nil) throws -> String? {
        try locked(directory: directory) { locallyRevoked ? nil : try read($0) }
    }
    public static func setEnabled(_ enabled: Bool, accountKey: String?, directory: URL? = nil) throws {
        try locked(directory: directory) { file in
            if !enabled {
                locallyRevoked = true
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                return
            }
            guard let accountKey else { throw AutoResetJournalError.storage }
            let data = try JSONEncoder().encode(Grant(accountKey: accountKey))
            try AutoResetDisk.write(data, to: file, syncDirectory: false)
            locallyRevoked = false
        }
    }
    public static func sendIfEnabled(accountKey: String, directory: URL? = nil, action: () throws -> Void) throws {
        try locked(directory: directory) { file in
            guard !locallyRevoked, try read(file) == accountKey else { throw AutoResetError.disabled }
            try action()
        }
    }
}
