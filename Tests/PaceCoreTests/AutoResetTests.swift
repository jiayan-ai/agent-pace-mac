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
