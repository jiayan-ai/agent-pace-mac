import Foundation
import CryptoKit
import PaceCore

struct ManualResetTests {
    func credits(_ entries: String) throws -> ResetCredits {
        try JSONDecoder().decode(ResetCredits.self, from: Data("{\"availableCount\":2,\"credits\":[\(entries)]}".utf8))
    }
    func entry(_ id: String = "chosen", expiry: String = "null", status: String = "available", type: String = "codexRateLimits") -> String {
        "{\"id\":\"\(id)\",\"resetType\":\"\(type)\",\"status\":\"\(status)\",\"expiresAt\":\(expiry)}"
    }
    func testEligibilityUsesSelectedCreditWithoutDeadline() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let distant = entry(expiry: "2000864000")
        try expect(ManualResetPolicy.credit(id: "chosen", credits: try credits(distant), now: now) != nil)
        try expect(ManualResetPolicy.credit(id: "chosen", credits: try credits(entry()), now: now) != nil)
        for invalid in [entry(expiry: "1999999999"), entry(expiry: "1e300"), entry(status: "used"), entry(type: "other"), entry("")] {
            try expect(ManualResetPolicy.credit(id: "chosen", credits: try credits(invalid), now: now) == nil)
        }
        try expect(ManualResetPolicy.credit(id: "chosen", credits: try credits(distant + "," + distant), now: now) == nil)
        try expect(ManualResetPolicy.credit(id: "chosen", credits: ResetCredits(availableCount: 2), now: now) == nil)
    }

    func testKnownNoOpCanRetryButUnknownUsesSameKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for noOp in [AutoResetOutcome.nothingToReset, .noCredit] {
            let account = noOp.rawValue
            var keys: [String] = []
            _ = try AutoResetJournal.perform(directory: dir, accountKey: account, creditID: "credit") { key in keys.append(key); return noOp }
            _ = try AutoResetJournal.perform(directory: dir, accountKey: account, creditID: "credit") { _ in throw UsageError.server }
            try expect(keys.count == 1)
            let result = try AutoResetJournal.perform(directory: dir, accountKey: account, creditID: "credit", retryKnownUnused: true) { key in keys.append(key); return .reset }
            try expect(result == .reset && keys.count == 2 && keys[0] != keys[1])
            _ = try AutoResetJournal.perform(directory: dir, accountKey: account, creditID: "credit", retryKnownUnused: true) { _ in throw UsageError.server }
        }
        var uncertainKey = ""
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: dir, accountKey: "uncertain", creditID: "credit", retryKnownUnused: true) { key in uncertainKey = key; throw UsageError.timeout }
        }
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: dir, accountKey: "uncertain", creditID: "other", retryKnownUnused: true) { _ in .reset }
        }
        _ = try AutoResetJournal.perform(directory: dir, accountKey: "uncertain", creditID: "credit", retryKnownUnused: true) { key in try expect(key == uncertainKey); return .alreadyRedeemed }
        try expectThrows {
            _ = try AutoResetJournal.perform(directory: dir, accountKey: "preflight", creditID: "credit") { _ in throw AutoResetError.creditChanged }
        }
        try expect(!(try AutoResetJournal.hasUnconfirmed(directory: dir, accountKey: "preflight")))
    }

    func testManualProtocolWorksWithAutomaticOffAndTargetsChosenCredit() throws {
        for expiry in [Optional<Date>.none, Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)) + 864000)] {
            try protocolCase(expiry: expiry, changedAccount: false, changedExpiry: false, shouldSend: true)
        }
    }
    func testChangedAccountOrCreditDoesNotSend() throws {
        try protocolCase(expiry: nil, changedAccount: true, changedExpiry: false, shouldSend: false)
        try protocolCase(expiry: nil, changedAccount: false, changedExpiry: true, shouldSend: false)
    }
    private func protocolCase(expiry: Date?, changedAccount: Bool, changedExpiry: Bool, shouldSend: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("server.sent")
        let rawExpiry = changedExpiry ? String(Int(Date().timeIntervalSince1970) + 86400) : (expiry.map { String(Int($0.timeIntervalSince1970)) } ?? "None")
        let script = """
        #!/usr/bin/python3
        import json,sys
        def recv(method):
            raw=sys.stdin.readline()
            if not raw: sys.exit(0)
            m=json.loads(raw)
            assert m['method']==method
            return m
        def send(m): print(json.dumps(m),flush=True)
        recv('initialize');send({'id':1,'result':{}})
        recv('initialized');recv('account/read')
        send({'id':2,'result':{'account':{'type':'chatgpt','id':'manual-fixture'}}})
        recv('account/rateLimits/read')
        send({'id':3,'result':{'rateLimitResetCredits':{'availableCount':2,'credits':[
            {'id':'earlier','status':'available','resetType':'codexRateLimits','expiresAt':2000000000},
            {'id':'chosen','status':'available','resetType':'codexRateLimits','expiresAt':\(rawExpiry)}]}}})
        m=recv('account/rateLimitResetCredit/consume')
        assert m['params']=={'creditId':'chosen','idempotencyKey':'manual-key'}
        open(__file__+'.sent','w').write('sent')
        send({'id':4,'result':{'outcome':'reset'}})
        sys.stdin.read()
        """
        let path = dir.appendingPathComponent("server")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let scope: [String: Any] = ["identity": "manual-fixture", "workspace": NSNull()]
        let scopeData = try JSONSerialization.data(withJSONObject: scope, options: .sortedKeys)
        let account = SHA256.hash(data: scopeData).map { String(format: "%02x", $0) }.joined()
        let run = {
            try CodexClient.consumeResetCredit(expectedAccountKey: changedAccount ? "wrong" : account,
                                               creditID: "chosen", idempotencyKey: "manual-key", executable: path,
                                               timeout: 4, authorizationDirectory: dir,
                                               mode: .manual(expectedExpiry: expiry))
        }
        if shouldSend { try expect(try run() == .reset) }
        else { try expectThrows { _ = try run() } }
        try expect(FileManager.default.fileExists(atPath: marker.path) == shouldSend)
        try expect(!(FileManager.default.fileExists(atPath: dir.appendingPathComponent("auto-reset-authorization.json").path)))
    }
}
