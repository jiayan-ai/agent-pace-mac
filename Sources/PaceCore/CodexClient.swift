import Foundation
import CryptoKit
import Darwin

public struct UsageSnapshot: Codable {
    public let response: UsageResponse
    public let accountKey: String
    public let fetchedAt: Date
    public let activity: AccountActivity?

    public init(response: UsageResponse, accountKey: String, fetchedAt: Date, activity: AccountActivity? = nil) {
        self.response = response
        self.accountKey = accountKey
        self.fetchedAt = fetchedAt
        self.activity = activity
    }
}

public enum UsageError: LocalizedError {
    case missingCodex, timeout, exited, invalidResponse, notSignedIn, server
    public var errorDescription: String? {
        switch self {
        case .missingCodex: return L("未找到 Codex。请安装并登录 ChatGPT 或 Codex 桌面应用，也可以安装 Codex CLI。")
        case .timeout: return L("额度同步超时。请检查网络，然后重试。")
        case .exited: return L("Codex 本地服务未能启动。请打开 ChatGPT / Codex 并确认已登录。")
        case .invalidResponse: return L("暂时无法识别额度数据。请更新 ChatGPT / Codex 后重试。")
        case .notSignedIn: return L("请先在 ChatGPT / Codex 中登录订阅账户。API Key 登录不提供此额度。")
        case .server: return L("暂时无法读取额度。请检查网络及 ChatGPT / Codex 的登录状态。")
        }
    }
}

public enum CodexClient {
    public static func executable() -> URL? {
        var candidates: [String] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            candidates += [
                root + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                root + "/Codex.app/Contents/Resources/codex",
                root + "/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Read-only account, quota and daily activity calls. Never redeems a reset.
    public static func fetch(executable override: URL? = nil, timeout: TimeInterval = 30) throws -> UsageSnapshot {
        guard let binary = override ?? executable() else { throw UsageError.missingCodex }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Bound shutdown even if the local service hangs.
            let end = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agent_pace", "title": "Agent Pace", "version": "1.3.0"]]])
        var buffer = Data()
        var accountKey: String?
        var quota: UsageSnapshot?
        var activityDeadline = Double.infinity
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let quota, ProcessInfo.processInfo.systemUptime >= activityDeadline { return quota }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 200)
            if ready < 0 && errno == EINTR { continue }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                if count == 0 {
                    if let quota { return quota }
                    throw UsageError.exited
                }
                if buffer.count > 4_000_000 { throw UsageError.invalidResponse }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    // Reject unsolicited server requests; never approve work or return credentials.
                    if message["method"] != nil, let id = message["id"] {
                        try send(["id": id, "error": ["code": -32601, "message": "Read-only usage client"]])
                        continue
                    }
                    guard let id = message["id"] as? Int else { continue }
                    // Older app servers can lack history. Keep a valid quota result.
                    if id == 4, let quota {
                        let activity = (message["result"] as? [String: Any]).flatMap {
                            try? JSONDecoder().decode(AccountActivity.self, from: JSONSerialization.data(withJSONObject: $0))
                        }
                        return UsageSnapshot(response: quota.response, accountKey: quota.accountKey,
                                             fetchedAt: quota.fetchedAt, activity: activity?.recent(now: quota.fetchedAt))
                    }
                    if message["error"] != nil { throw UsageError.server }
                    guard let result = message["result"] as? [String: Any] else { throw UsageError.invalidResponse }
                    switch id {
                    case 1:
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                    case 2:
                        guard let account = result["account"] as? [String: Any],
                              account["type"] as? String == "chatgpt",
                              let identity = (account["id"] ?? account["email"]) as? String else { throw UsageError.notSignedIn }
                        // Current desktop versions expose email, older versions may expose id.
                        // Hash the identity plus workspace routing; never persist either in plain text.
                        let scope: [String: Any] = ["identity": identity, "workspace": result["workspaceRouting"] ?? NSNull()]
                        let scopeData = try JSONSerialization.data(withJSONObject: scope, options: .sortedKeys)
                        accountKey = SHA256.hash(data: scopeData).map { String(format: "%02x", $0) }.joined()
                        try send(["id": 3, "method": "account/rateLimits/read"])
                    case 3:
                        guard let accountKey else { throw UsageError.notSignedIn }
                        let data = try JSONSerialization.data(withJSONObject: result)
                        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
                        quota = UsageSnapshot(response: response, accountKey: accountKey, fetchedAt: Date())
                        activityDeadline = ProcessInfo.processInfo.systemUptime + 5
                        try send(["id": 4, "method": "account/usage/read"])
                    default: break
                    }
                }
            }
            if !process.isRunning {
                if let quota { return quota }
                throw UsageError.exited
            }
        }
        if let quota { return quota }
        throw UsageError.timeout
    }

    /// Rechecks the account and credit on a new connection before spending this specific credit.
    /// The caller must durably store the idempotency key before entering this method.
    public static func consumeResetCredit(expectedAccountKey: String, creditID: String, idempotencyKey: String,
                                          executable override: URL? = nil, timeout: TimeInterval = 30,
                                          authorizationDirectory: URL? = nil,
                                          mode: ResetRedemptionMode = .automatic) throws -> AutoResetOutcome {
        var consumeSent = false
        do {
            guard !expectedAccountKey.isEmpty, !creditID.isEmpty, !idempotencyKey.isEmpty else { throw AutoResetError.creditChanged }
            guard let binary = override ?? executable() else { throw UsageError.missingCodex }
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = binary
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                let end = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? output.fileHandleForReading.close()
            }
            func send(_ value: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: value)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agent_pace", "title": "Agent Pace", "version": "1.9.0"], "capabilities": ["experimentalApi": true, "requestAttestation": false]]])
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&event, 1, 200)
                if ready < 0 && errno == EINTR { continue }
                if ready > 0 {
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = read(fd, &bytes, bytes.count)
                    if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                    if count == 0 { throw UsageError.exited }
                    if buffer.count > 4_000_000 { throw UsageError.invalidResponse }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: newline)
                        buffer.removeSubrange(...newline)
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        if message["method"] != nil, let id = message["id"] {
                            try send(["id": id, "error": ["code": -32601, "message": "Unsupported request"]])
                            continue
                        }
                        guard let id = message["id"] as? Int else { continue }
                        if message["error"] != nil { throw UsageError.server }
                        guard let result = message["result"] as? [String: Any] else { throw UsageError.invalidResponse }
                        switch id {
                        case 1:
                            try send(["method": "initialized", "params": [:]])
                            try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                        case 2:
                            guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt",
                                  let identity = (account["id"] ?? account["email"]) as? String else { throw UsageError.notSignedIn }
                            let scope: [String: Any] = ["identity": identity, "workspace": result["workspaceRouting"] ?? NSNull()]
                            let scopeData = try JSONSerialization.data(withJSONObject: scope, options: .sortedKeys)
                            let accountKey = SHA256.hash(data: scopeData).map { String(format: "%02x", $0) }.joined()
                            guard accountKey == expectedAccountKey else { throw AutoResetError.accountChanged }
                            try send(["id": 3, "method": "account/rateLimits/read"])
                        case 3:
                            let data = try JSONSerialization.data(withJSONObject: result)
                            let response = try JSONDecoder().decode(UsageResponse.self, from: data)
                            switch mode {
                            case .automatic:
                                guard AutoResetPolicy.candidate(credits: response.rateLimitResetCredits, now: Date())?.id == creditID else {
                                    throw AutoResetError.creditChanged
                                }
                            case .manual(let expectedExpiry):
                                guard let credit = ManualResetPolicy.credit(id: creditID, credits: response.rateLimitResetCredits, now: Date()),
                                      credit.expiryDate == expectedExpiry else { throw AutoResetError.creditChanged }
                            }
                            func consume() throws {
                                // Mark before writing: a partial write may already reach the server.
                                consumeSent = true
                                try send(["id": 4, "method": "account/rateLimitResetCredit/consume", "params": ["creditId": creditID, "idempotencyKey": idempotencyKey]])
                            }
                            switch mode {
                            case .automatic:
                                try AutoResetAuthorization.sendIfEnabled(accountKey: expectedAccountKey, directory: authorizationDirectory, action: consume)
                            case .manual:
                                try consume()
                            }
                        case 4:
                            guard let raw = result["outcome"] as? String, let outcome = AutoResetOutcome(rawValue: raw) else { throw UsageError.invalidResponse }
                            return outcome
                        default: break
                        }
                    }
                }
                if !process.isRunning { throw UsageError.exited }
            }
            throw UsageError.timeout
        } catch {
            if !consumeSent, !(error is AutoResetError) {
                throw AutoResetError.beforeSend((error as? LocalizedError)?.errorDescription ?? L("额度同步失败，请稍后重试。"))
            }
            throw error
        }
    }

}
