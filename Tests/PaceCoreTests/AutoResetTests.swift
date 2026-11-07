import Foundation
import CryptoKit
import PaceCore

struct AutoResetTests {
    func testCandidateBoundariesAndSelection() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func data(_ entries: String) throws -> ResetCredits {
            try JSONDecoder().decode(ResetCredits.self, from: Data("{\"availableCount\":2,\"credits\":[\(entries)]}".utf8))
        }
        func entry(_ id: String, _ seconds: Int, _ status: String = "available", _ type: String = "codexRateLimits") -> String {
            "{\"id\":\"\(id)\",\"resetType\":\"\(type)\",\"status\":\"\(status)\",\"expiresAt\":\(Int(now.timeIntervalSince1970) + seconds)}"
        }
        try expect(AutoResetPolicy.candidate(credits: try data(entry("too-far", 301)), now: now) == nil)
        try expect(AutoResetPolicy.candidate(credits: try data(entry("expired", 0)), now: now) == nil)
        try expect(AutoResetPolicy.candidate(credits: try data(entry("other", 120, "available", "unknown")), now: now) == nil)
        let two = try data(entry("later", 300) + "," + entry("earlier", 120))
        try expect(AutoResetPolicy.candidate(credits: two, now: now)?.id == "earlier")
        try expect(AutoResetPolicy.candidate(credits: try data(entry("boundary", 300)), now: now)?.id == "boundary")
    }

    func testJournalPersistsRetryKeyAndPreventsDoubleSpend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var seen: [String] = []
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one") { key in
                seen.append(key)
                throw UsageError.timeout
            }
        }
        try expect(try AutoResetJournal.hasUnconfirmed(directory: directory, accountKey: "account"))
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "other") { _ in .reset }
        }
        let result = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one") { key in
            seen.append(key)
            return .reset
        }
        try expect(result == .reset && seen.count == 2 && seen[0] == seen[1])
        try expect(!(try AutoResetJournal.hasUnconfirmed(directory: directory, accountKey: "account")))
        let repeated = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one") { _ in
            throw UsageError.server
        }
        try expect(repeated == .reset)
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "two") { _ in .reset }
        }
        let anotherDir = directory.appendingPathComponent("manual")
        try expectThrows { _ = try AutoResetJournal.perform(directory: anotherDir, accountKey: "account", creditID: "uncertain") { _ in throw UsageError.timeout } }
        try AutoResetJournal.clearUnconfirmed(directory: anotherDir, accountKey: "account")
        try expect(!(try AutoResetJournal.hasUnconfirmed(directory: anotherDir, accountKey: "account")))
        try expectThrows { _ = try AutoResetJournal.perform(directory: anotherDir, accountKey: "account", creditID: "uncertain") { _ in .reset } }
        let other = try AutoResetJournal.perform(directory: directory, accountKey: "another-account", creditID: "two") { _ in .noCredit }
        try expect(other == .noCredit)
    }

    func testRefreshIntervalTracksExpiryWindow() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let credits = try JSONDecoder().decode(ResetCredits.self, from: Data("""
        {"availableCount":1,"credits":[{"id":"soon","resetType":"codexRateLimits","status":"available","expiresAt":2000000300}]}
        """.utf8))
        try expect(AutoResetPolicy.refreshInterval(credits: credits, enabled: true, now: now.addingTimeInterval(-0.001)) == 300)
        try expect(AutoResetPolicy.refreshInterval(credits: credits, enabled: true, now: now) == 60)
        try expect(AutoResetPolicy.refreshInterval(credits: credits, enabled: true, now: now.addingTimeInterval(299.999)) == 60)
        try expect(AutoResetPolicy.refreshInterval(credits: credits, enabled: true, now: now.addingTimeInterval(300)) == 300)
        try expect(AutoResetPolicy.refreshInterval(credits: credits, enabled: false, now: now) == 300)
        try expect(AutoResetPolicy.refreshInterval(credits: nil, enabled: true, now: now) == 300)
    }

    func testJournalRetriesKnownUnusedAfterInterval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for noOp in [AutoResetOutcome.nothingToReset, .noCredit] {
            let account = noOp.rawValue
            var keys: [String] = []
            let first = try AutoResetJournal.perform(directory: directory, accountKey: account, creditID: "one",
                                                    retryKnownUnused: true, minimumRetryInterval: 60, now: now) { key in
                keys.append(key)
                return noOp
            }
            try expect(first == noOp && keys.count == 1)
            let early = try AutoResetJournal.perform(directory: directory, accountKey: account, creditID: "one",
                                                    retryKnownUnused: true, minimumRetryInterval: 60,
                                                    now: now.addingTimeInterval(59.999)) { _ in
                throw TestFailure(description: "Known unused credit retried before its retry interval")
            }
            try expect(early == noOp)
            let retried = try AutoResetJournal.perform(directory: directory, accountKey: account, creditID: "one",
                                                      retryKnownUnused: true, minimumRetryInterval: 60,
                                                      now: now.addingTimeInterval(60)) { key in
                keys.append(key)
                return .reset
            }
            try expect(retried == .reset && keys.count == 2 && keys[0] != keys[1])
            let completed = try require(AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: account))
            try expect(completed.outcome == .reset && completed.completedAt == now.addingTimeInterval(60))
            let repeated = try AutoResetJournal.perform(directory: directory, accountKey: account, creditID: "one",
                                                       retryKnownUnused: true, minimumRetryInterval: 60,
                                                       now: now.addingTimeInterval(360)) { _ in
                throw TestFailure(description: "Successful credit was dispatched again")
            }
            try expect(repeated == .reset)
            var otherSent = false
            try expectThrows {
                _ = try AutoResetJournal.perform(directory: directory, accountKey: account, creditID: "two",
                                                 now: now.addingTimeInterval(359.999)) { _ in otherSent = true; return .reset }
            }
            try expect(!otherSent)
            _ = try AutoResetJournal.perform(directory: directory, accountKey: account, creditID: "two",
                                             now: now.addingTimeInterval(360)) { _ in otherSent = true; return .reset }
            try expect(otherSent)
        }
    }

    func testJournalUnknownRetriesKeepKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var keys: [String] = []
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one",
                                             retryKnownUnused: true, minimumRetryInterval: 60, now: now) { key in
                keys.append(key)
                throw UsageError.timeout
            }
        }
        var otherSent = false
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "two",
                                             retryKnownUnused: true, minimumRetryInterval: 60,
                                             now: now.addingTimeInterval(60)) { _ in otherSent = true; return .reset }
        }
        try expect(!otherSent)
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one",
                                             retryKnownUnused: true, minimumRetryInterval: 60,
                                             now: now.addingTimeInterval(60)) { key in
                keys.append(key)
                throw UsageError.timeout
            }
        }
        let result = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one",
                                                 retryKnownUnused: true, minimumRetryInterval: 60,
                                                 now: now.addingTimeInterval(120)) { key in
            keys.append(key)
            return .alreadyRedeemed
        }
        try expect(result == .alreadyRedeemed && keys.count == 3 && Set(keys).count == 1)
        _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one",
                                         retryKnownUnused: true, minimumRetryInterval: 60,
                                         now: now.addingTimeInterval(420)) { _ in
            throw TestFailure(description: "Already-redeemed credit was dispatched again")
        }
        try expect(!(try AutoResetJournal.hasUnconfirmed(directory: directory, accountKey: "account")))
    }

    func testLatestCompletedAttemptReadsLegacyAndIsolatesAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let legacy: [String: Any] = ["attempts": [
            "account:older": ["key": "old-key", "outcome": "noCredit", "completedAt": now.addingTimeInterval(-60).timeIntervalSinceReferenceDate],
            "account:one": ["key": "one-key", "outcome": "nothingToReset", "completedAt": now.timeIntervalSinceReferenceDate],
            "account:pending": ["key": "pending-key"],
            "account-other:two": ["key": "two-key", "outcome": "reset", "completedAt": now.addingTimeInterval(60).timeIntervalSinceReferenceDate]
        ]]
        let file = directory.appendingPathComponent("auto-reset.json")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try legacyData.write(to: file)
        let own = try require(AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "account"))
        try expect(own.outcome == .nothingToReset && own.completedAt == now)
        let other = try require(AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "account-other"))
        try expect(other.outcome == .reset && other.completedAt == now.addingTimeInterval(60))
        try expect(try AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "missing") == nil)
        try expect(try Data(contentsOf: file) == legacyData)
        let summary = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(own)) as? [String: Any])
        try expect(Set(summary.keys) == Set(["outcome", "completedAt"]))
        try expect(try AutoResetJournal.confirmedCreditIDs(directory: directory, accountKey: "account").isEmpty)
        try expect(try AutoResetJournal.confirmedCreditIDs(directory: directory, accountKey: "account-other") == ["two"])
    }

    func testLatestCompletedAttemptSurvivesRetryFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Start with the old schema so the retry must preserve its fallback summary.
        let legacy: [String: Any] = ["attempts": [
            "account:one": ["key": "old-key", "outcome": "nothingToReset", "completedAt": now.timeIntervalSinceReferenceDate]
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("auto-reset.json"))
        let original = try require(AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "account"))
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one",
                                             retryKnownUnused: true, minimumRetryInterval: 60,
                                             now: now.addingTimeInterval(60)) { _ in throw AutoResetError.creditChanged }
        }
        try expect(try AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "account") == original)
        try expect(!(try AutoResetJournal.hasUnconfirmed(directory: directory, accountKey: "account")))
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: directory, accountKey: "account", creditID: "one",
                                             retryKnownUnused: true, minimumRetryInterval: 60,
                                             now: now.addingTimeInterval(120)) { _ in throw UsageError.timeout }
        }
        try expect(try AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "account") == original)
        try expect(try AutoResetJournal.hasUnconfirmed(directory: directory, accountKey: "account"))
        _ = try AutoResetJournal.perform(directory: directory, accountKey: "other", creditID: "two",
                                         now: now.addingTimeInterval(180)) { _ in .noCredit }
        try expect(try AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "account") == original)
        let other = try require(AutoResetJournal.latestCompletedAttempt(directory: directory, accountKey: "other"))
        try expect(other.outcome == .noCredit && other.completedAt == now.addingTimeInterval(180))
    }

    func testConsumeProtocolAndAccountCheck() throws {
        let now = Int(Date().timeIntervalSince1970)
        let script = """
        #!/usr/bin/python3
        import json,sys
        def recv(method):
            msg=json.loads(sys.stdin.readline())
            assert msg['method']==method
            return msg
        def send(msg): print(json.dumps(msg),flush=True)
        req=recv('initialize')
        assert req['params']['capabilities']['experimentalApi'] == True
        send({'id':1,'result':{}})
        recv('initialized')
        recv('account/read')
        send({'id':2,'result':{'account':{'type':'chatgpt','id':'fixture-account'}}})
        recv('account/rateLimits/read')
        send({'id':3,'result':{'rateLimitResetCredits':{'availableCount':1,'credits':[{'id':'credit-1','resetType':'codexRateLimits','status':'available','expiresAt':\(now + 240)}]}}})
        req=recv('account/rateLimitResetCredit/consume')
        assert req['params']=={'creditId':'credit-1','idempotencyKey':'same-key'}
        send({'id':4,'result':{'outcome':'reset'}})
        sys.stdin.read()
        """
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }
        let scope: [String: Any] = ["identity": "fixture-account", "workspace": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: scope, options: .sortedKeys)
        let account = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let authDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: authDir) }
        try AutoResetAuthorization.setEnabled(true, accountKey: account, directory: authDir)
        let outcome = try CodexClient.consumeResetCredit(expectedAccountKey: account, creditID: "credit-1", idempotencyKey: "same-key", executable: path, timeout: 5, authorizationDirectory: authDir)
        try expect(outcome == .reset)
        try AutoResetAuthorization.setEnabled(false, accountKey: nil, directory: authDir)
        var sent = false
        try expectThrows { try AutoResetAuthorization.sendIfEnabled(accountKey: account, directory: authDir) { sent = true } }
        try expect(!sent)
        try expectThrows {
            _ = try CodexClient.consumeResetCredit(expectedAccountKey: account, creditID: "credit-1", idempotencyKey: "same-key", executable: path, timeout: 5, authorizationDirectory: authDir)
        }
        try expectThrows {
            _ = try CodexClient.consumeResetCredit(expectedAccountKey: "different-account", creditID: "credit-1", idempotencyKey: "same-key", executable: path, timeout: 5, authorizationDirectory: authDir)
        }
    }
}
