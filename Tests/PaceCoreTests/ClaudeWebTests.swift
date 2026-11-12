import Foundation
import JavaScriptCore
import PaceCore

struct ClaudeWebTests {
    let org = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"

    func testWebIdentityAndMissingFields() throws {
        let json = """
        {"status":200,"organizations":[{"uuid":"\(org)","name":"Personal"}],"organization":"\(org)",
         "usage":{"seven_day":{"utilization":25,"resets_at":"2026-10-17T01:00:00Z"}}}
        """
        let reply = try JSONDecoder().decode(ClaudeWebReply.self, from: Data(json.utf8))
        let snapshot = try reply.snapshot()
        try expect(snapshot.response.windows[0].window.remaining == 75)
        try expect(snapshot.accountKey.count == 64 && snapshot.accountKey != org)
        let unknown = json.replacingOccurrences(of: "\"organization\":\"\(org)\"", with: "\"organization\":\"\(other)\"")
        try expectThrows { try JSONDecoder().decode(ClaudeWebReply.self, from: Data(unknown.utf8)).snapshot() }
        for status in [401, 403, 409, 429, 500] {
            try expectThrows { try JSONDecoder().decode(ClaudeWebReply.self, from: Data("{\"status\":\(status)}".utf8)).snapshot() }
        }
        // Verified inventory can stand alone, but one workspace's visible
        // settings cannot provide another workspace's offer.
        let section = #"{"organization":"\#(org)","text":"Limit resets\n2 available\nFull reset\nFable reset","hasEnabledResetButton":true}"#
        let inventory = #"{"status":200,"organization":"\#(org)","organizations":[{"uuid":"\#(org)","name":"Example"}],"usage":{},"resetSection":\#(section)}"#
        let standalone = try JSONDecoder().decode(ClaudeWebReply.self, from: Data(inventory.utf8)).snapshot()
        try expect(standalone.response.claudeLimitResets?.availableCount == 2 && standalone.response.windows.isEmpty)
        let changed = inventory.replacingOccurrences(of: section, with: section.replacingOccurrences(of: org, with: other))
        try expectThrows { try JSONDecoder().decode(ClaudeWebReply.self, from: Data(changed.utf8)).snapshot() }
    }

    func testOriginValidation() throws {
        try expect(ClaudeWebAPI.isClaudeOrigin(URL(string: "https://claude.ai/settings/usage")))
        for path in ["settings/usage", "settings/usage/", "new#settings/usage"] {
            try expect(ClaudeWebAPI.isUsagePage(URL(string: "https://claude.ai/" + path)))
        }
        for url in ["https://claude.ai/new", "https://claude.ai/#settings/profile",
                    "https://example.org/#settings/usage", "https://claude.ai/settings/usage-extra"] {
            try expect(!ClaudeWebAPI.isUsagePage(URL(string: url)))
        }
        func matches(_ paths: [String], sole: Bool = false) throws -> Bool {
            let context = try require(JSContext())
            let resources = paths.map { ["name": $0, "initiatorType": "fetch"] }
            let fixture = String(decoding: try JSONSerialization.data(withJSONObject: resources), as: UTF8.self)
            context.evaluateScript("""
                var location = {origin:'https://claude.ai', pathname:'/new', hash:'#settings/usage'};
                var performance = {getEntriesByType: () => \(fixture)}, selectedOrganization = '\(org)', soleOrganization = \(sole);
                class URL { constructor(path, origin){ this.origin = origin; this.pathname = path; } }
                var document = {querySelectorAll: () => []};
                var scopeResult = (() => { \(ClaudeWebAPI.resetSectionScript) })();
                """)
            let status = try require(context.objectForKeyedSubscript("scopeResult")?.toDictionary()?["readerStatus"] as? [String: Any])
            return status["matched"] as? Bool == true
        }
        let exact = "/api/organizations/\(org)/usage"
        let otherReset = "/api/organizations/\(other)/limit_resets"
        try expect(try matches([exact]))
        try expect(try !matches([exact, otherReset]))
        try expect(try !matches(["/api/organizations/\(org)/profile"]))
        try expect(try matches([], sole: true))
        try expect(try !matches([otherReset], sole: true))
        for url in ["http://claude.ai", "https://claude.ai.evil.test", "https://evil.test/claude.ai", "https://claude.ai:8443", "file:///claude.ai"] {
            try expect(!ClaudeWebAPI.isClaudeOrigin(URL(string: url)))
        }
    }

    // Execute the actual WebKit bridge against a synthetic same-origin server.
    // This checks its requests and output, not a second copy of its logic.
    func runScript(responses: String, selected: String = "", origin: String = "https://claude.ai") throws -> [String: Any] {
        let context = try require(JSContext())
        var scriptError: String?
        context.exceptionHandler = { _, error in scriptError = error?.toString() }
        context.evaluateScript("""
        var location = {origin:'\(origin)'};
        var selectedOrganization = '\(selected)';
        var fixtures = \(responses), requests = [], output;
        function setTimeout() { return 1; } function clearTimeout() {}
        class AbortController { constructor(){this.signal={}} abort(){} }
        async function fetch(path, options) {
            requests.push({path,options});
            var fixture = fixtures.shift();
            if (!fixture) throw Error('Unexpected request');
            return {ok:fixture.status === 200, status:fixture.status,
                headers:{get:key => key === 'Content-Type' ? (fixture.type || 'application/json') : (fixture.retry || null)},
                text:async () => JSON.stringify(fixture.data)};
        }
        (async () => { \(ClaudeWebAPI.script) })().then(value => {output=JSON.parse(value)});
        """)
        let deadline = Date().addingTimeInterval(2)
        while context.objectForKeyedSubscript("output").isUndefined && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        try expect(scriptError == nil)
        let result = try require(context.objectForKeyedSubscript("output").toDictionary() as? [String: Any])
        let requests = try require(context.objectForKeyedSubscript("requests").toArray() as? [[String: Any]])
        for request in requests {
            let options = try require(request["options"] as? [String: Any])
            try expect(options["method"] as? String == "GET")
            try expect(options["redirect"] as? String == "error")
            try expect(options["credentials"] as? String == "same-origin")
        }
        return result.merging(["requests": requests]) { _, new in new }
    }

    func testBridgeOnlyReturnsUsageAndRequiresOrganizationChoice() throws {
        let orgs = #"{"status":200,"data":[{"uuid":"\#(org)","name":"Personal","private":"not returned"}]}"#
        let usage = #"{"status":200,"data":{"seven_day":{"utilization":12,"resets_at":"2026-10-17T01:00:00Z","private":"not returned"},"secret":"not returned"}}"#
        let result = try runScript(responses: "[\(orgs),\(usage)]")
        try expect(result["status"] as? Int == 200)
        let requests = try require(result["requests"] as? [[String: Any]])
        try expect(requests.count == 2)
        try expect(requests[1]["path"] as? String == "/api/organizations/\(org)/usage")
        let json = String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!
        try expect(!json.contains("not returned"))
        let switched = try runScript(responses: "[\(orgs)]", selected: other)
        try expect(switched["status"] as? Int == 409)
        try expect((switched["requests"] as? [Any])?.count == 1)
        let multiple = orgs.replacingOccurrences(of: "]}", with: ",{\"uuid\":\"\(other)\",\"name\":\"Team\"}]}")
        try expect(try runScript(responses: "[\(multiple)]")["status"] as? Int == 409)
        try expect(try runScript(responses: "[\(multiple),\(usage)]", selected: other)["organization"] as? String == other)
    }

    func testBridgeAuthExpiryChallengeAndRateLimit() throws {
        for status in [401, 403, 429, 503] {
            let result = try runScript(responses: "[{\"status\":\(status),\"retry\":\"900\"}]")
            try expect(result["status"] as? Int == status)
            try expect((result["requests"] as? [Any])?.count == 1)
        }
        try expect(try runScript(responses: #"[{"status":200,"type":"text/html","data":"login"}]"#)["status"] as? Int == 401)
        let foreign = try runScript(responses: "[]", origin: "https://accounts.google.com")
        try expect(foreign["status"] as? Int == 401)
        try expect((foreign["requests"] as? [Any])?.isEmpty == true)
    }

    func testBridgeIncludesFableWithoutLeakingOtherFields() throws {
        let orgs = #"{"status":200,"data":[{"uuid":"\#(org)","name":"Personal"}]}"#
        let usage = #"{"status":200,"data":{"seven_day":{"utilization":20,"resets_at":"2026-10-24T01:00:00Z"},"limits":[{"kind":"weekly_scoped","percent":42.5,"resets_at":"2026-10-23T03:00:00Z","scope":{"model":{"display_name":"Fable"}},"private":"must not cross bridge"}],"account_secret":"must not cross bridge"}}"#
        var result = try runScript(responses: "[\(orgs),\(usage)]")
        result.removeValue(forKey: "requests")
        let data = try JSONSerialization.data(withJSONObject: result)
        try expect(!String(decoding: data, as: UTF8.self).contains("must not cross bridge"))
        let snapshot = try JSONDecoder().decode(ClaudeWebReply.self, from: data).snapshot()
        let fable = try require(snapshot.response.windows.first { $0.bucketID == "claude_fable" })
        try expect(fable.window.usedPercent == 42.5 && fable.window.remaining == 57.5)
        let malformed = usage.replacingOccurrences(of: "42.5", with: "\"bad\"")
        let invalid = try runScript(responses: "[\(orgs),\(malformed)]")
        try expect((invalid["usage"] as? [String: Any])?["seven_day_fable"] == nil)
    }

    func testFableScopeZeroMissingAndAmbiguousRows() throws {
        func windows(_ rows: String) throws -> [String: Any] {
            let orgs = #"{"status":200,"data":[{"uuid":"\#(org)","name":"Personal"}]}"#
            let usage = #"{"status":200,"data":{"seven_day":{"utilization":20},"limits":\#(rows),"harbor_lantern":{"utilization":99}}}"#
            return try require(runScript(responses: "[\(orgs),\(usage)]")["usage"] as? [String: Any])
        }
        let row = #"{"kind":"weekly_scoped","percent":0,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}"#
        let zero = try require(windows("[\(row)]")["seven_day_fable"] as? [String: Any])
        try expect(zero["utilization"] as? Double == 0 && zero["resets_at"] is NSNull)
        for rows in ["null", "[]", "[\(row),\(row)]", "[\(row.replacingOccurrences(of: "weekly_scoped", with: "weekly_all"))]",
                     "[\(row.replacingOccurrences(of: "Fable", with: "Other"))]", "[\(row.replacingOccurrences(of: "\"percent\":0", with: "\"percent\":-1"))]"] {
            let values = try windows(rows)
            try expect(values["seven_day_fable"] == nil)
            try expect(values["seven_day"] != nil)
        }
    }

    private var quotaDate: Date { ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")! }

    private func bridgeUsage(_ usage: String) throws -> [String: Any] {
        let orgs = #"{"status":200,"data":[{"uuid":"\#(org)","name":"Personal"}]}"#
        return try runScript(responses: "[\(orgs),{\"status\":200,\"data\":\(usage)}]")
    }

    private func bridgeSnapshot(_ result: [String: Any], now: Date? = nil) throws -> UsageSnapshot {
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(ClaudeWebReply.self, from: data).snapshot(now: now ?? quotaDate)
    }

    func testInactiveModernLimitsOverrideLegacyAndClearSelections() throws {
        let before = try bridgeSnapshot(bridgeUsage(#"""
        {
            "five_hour":{"utilization":2,"resets_at":"2026-11-01T16:00:00Z"},
            "seven_day":{"utilization":3,"resets_at":"2026-11-07T12:00:00Z"},
            "limits":[{"kind":"weekly_scoped","percent":2,"is_active":true,
                "resets_at":"2026-11-07T12:00:00Z","scope":{"model":{"display_name":"Fable"}}}]
        }
        """#))
        var history = ProviderHistory()
        history.ingest(before)
        history.selectedID = "claude/secondary"
        try expect(history.budgets[before.accountKey + "/claude/secondary"] != nil)
        try expect(history.budgets[before.accountKey + "/claude_fable/primary"] != nil)

        // Mirrors the reported response: legacy session usage remains populated
        // even though the corresponding modern limit is explicitly inactive.
        let result = try bridgeUsage(#"""
        {
            "five_hour":{"utilization":2,"resets_at":"2026-11-01T16:00:00Z"},
            "seven_day":{"utilization":99,"resets_at":"2026-11-07T12:00:00Z"},
            "limits":[
                {"kind":"session","percent":2,"is_active":false,"resets_at":"2026-11-01T16:00:00Z"},
                {"kind":"weekly_all","percent":3,"is_active":true,"resets_at":"2026-11-07T12:00:00Z"},
                {"kind":"weekly_scoped","percent":2,"is_active":false,"resets_at":"2026-11-07T12:00:00Z",
                    "scope":{"model":{"display_name":"Fable"}}}
            ]
        }
        """#)
        let values = try require(result["usage"] as? [String: Any])
        try expect(values["five_hour"] == nil && values["seven_day_fable"] == nil)
        try expect((values["seven_day"] as? [String: Any])?["utilization"] as? Double == 3)
        try expect(result["noActiveLimits"] as? Bool != true)
        let current = try bridgeSnapshot(result, now: quotaDate.addingTimeInterval(60))
        try expect(current.response.windows.map(\.id) == ["claude/primary"])
        history.ingest(current)
        try expect(history.selectedID == "claude/primary")
        try expect(Set(history.budgets.keys) == [before.accountKey + "/claude/primary"])
        try expect(history.snapshot?.response.windows.first?.window.usedPercent == 3)
    }

    func testModernOnlyActiveZeroAndExactModelMatching() throws {
        let result = try bridgeUsage(#"""
        {"limits":[
            {"kind":"session","percent":0,"is_active":true,"resets_at":"2026-11-01T16:00:00Z"},
            {"kind":"weekly_all","percent":7,"resets_at":"2026-11-07T12:00:00Z"},
            {"kind":"weekly_scoped","percent":11,"is_active":true,"resets_at":"2026-11-07T13:00:00Z",
                "scope":{"model":{"display_name":"Sonnet"}}},
            {"kind":"weekly_scoped","percent":12,"resets_at":"2026-11-07T14:00:00Z",
                "scope":{"model":{"display_name":"Opus"}}},
            {"kind":"weekly_scoped","percent":0,"is_active":true,"resets_at":null,
                "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_scoped","percent":88,"is_active":true,"scope":{"model":{"display_name":"fable"}}},
            {"kind":"weekly_scoped","percent":99,"is_active":true,"scope":{"model":{"display_name":"Other"}}}
        ]}
        """#)
        let snapshot = try bridgeSnapshot(result)
        try expect(snapshot.response.windows.count == 5)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.response.windows.map { ($0.id, $0.window) })
        try expect(byID["claude/secondary"]?.usedPercent == 0 && byID["claude/secondary"]?.remaining == 100)
        try expect(byID["claude/secondary"]?.windowDurationMins == 300)
        try expect(byID["claude/primary"]?.usedPercent == 7)
        try expect(byID["claude_sonnet/primary"]?.usedPercent == 11)
        try expect(byID["claude_opus/primary"]?.usedPercent == 12)
        try expect(byID["claude_fable/primary"]?.usedPercent == 0 && byID["claude_fable/primary"]?.remaining == 100)
        try expect(byID["claude_fable/primary"]?.resetsAt == nil)
        try expect(byID["claude_opus/primary"]?.resetDate == ISO8601DateFormatter().date(from: "2026-11-07T14:00:00Z"))
        try expect(result["noActiveLimits"] as? Bool != true)
    }

    func testModernInvalidOrAmbiguousRowsNeverFallBack() throws {
        let targets = [
            ("five_hour", #""kind":"session""#),
            ("seven_day", #""kind":"weekly_all""#),
            ("seven_day_sonnet", #""kind":"weekly_scoped","scope":{"model":{"display_name":"Sonnet"}}"#),
            ("seven_day_opus", #""kind":"weekly_scoped","scope":{"model":{"display_name":"Opus"}}"#)
        ]
        for (key, identity) in targets {
            for extra in [#""is_active":false,"percent":2"#, #""is_active":"false","percent":2"#,
                          #""is_active":0,"percent":2"#, #""is_active":null,"percent":2"#,
                          #""is_active":true,"percent":"2""#, #""is_active":true"#,
                          #""is_active":true,"percent":-1"#] {
                let result = try bridgeUsage("{\"\(key)\":{\"utilization\":91},\"limits\":[{\(identity),\(extra)}]}")
                let values = try require(result["usage"] as? [String: Any])
                try expect(values[key] == nil)
                if !extra.contains(#""is_active":false"#) {
                    try expect(result["noActiveLimits"] as? Bool != true)
                    try expectThrows { try bridgeSnapshot(result) }
                }
            }
            let row = "{\(identity),\"percent\":2,\"is_active\":true}"
            let result = try bridgeUsage("{\"\(key)\":{\"utilization\":91},\"limits\":[\(row),\(row)]}")
            try expect((result["usage"] as? [String: Any])?[key] == nil)
            try expect(result["noActiveLimits"] as? Bool != true)
            try expectThrows { try bridgeSnapshot(result) }
        }
        // Fable has no legacy alias; its matching row still obeys the same flag contract.
        for flag in ["false", "\"false\"", "1", "null"] {
            let result = try bridgeUsage("{\"seven_day\":{\"utilization\":3},\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":2,\"is_active\":\(flag),\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}]}")
            try expect((result["usage"] as? [String: Any])?["seven_day_fable"] == nil)
            try expect(try bridgeSnapshot(result).response.windows.map(\.id) == ["claude/primary"])
        }
    }

    func testLegacyFallbackRequiresNoModernMatchAndAnActiveFlag() throws {
        for limits in ["null", "[]", #"[{"kind":"unknown","is_active":false}]"#,
                       #"[{"kind":"weekly_scoped","percent":9,"scope":{"model":{"display_name":"SONNET"}}}]"#] {
            let result = try bridgeUsage("""
            {"five_hour":{"utilization":0,"resets_at":null},
             "seven_day":{"utilization":3,"is_active":true},
             "seven_day_sonnet":{"utilization":4},"seven_day_opus":{"utilization":5,"is_active":true},
             "limits":\(limits)}
            """)
            let values = try require(result["usage"] as? [String: Any])
            try expect(values.count == 4)
            try expect((values["five_hour"] as? [String: Any])?["utilization"] as? Double == 0)
            try expect((values["seven_day_sonnet"] as? [String: Any])?["utilization"] as? Double == 4)
            try expect(try bridgeSnapshot(result).response.windows.count == 4)
        }
        for key in ["five_hour", "seven_day_sonnet", "seven_day_opus"] {
            for flag in ["false", "\"false\"", "0", "null"] {
                let result = try bridgeUsage("{\"seven_day\":{\"utilization\":3},\"\(key)\":{\"utilization\":2,\"is_active\":\(flag)}}")
                try expect((result["usage"] as? [String: Any])?[key] == nil)
                try expect(try bridgeSnapshot(result).response.windows.map(\.id) == ["claude/primary"])
            }
        }
        let inactiveWeekly = try bridgeUsage(#"{"seven_day":{"utilization":2,"is_active":false},"five_hour":{"utilization":0}}"#)
        try expect(try bridgeSnapshot(inactiveWeekly).response.windows.map(\.id) == ["claude/secondary"])
    }

    func testExplicitAllInactiveClearsHistoryButUnknownEmptyIsRejected() throws {
        let before = try bridgeSnapshot(bridgeUsage(#"""
        {
            "five_hour":{"utilization":2,"resets_at":"2026-11-01T16:00:00Z"},
            "seven_day":{"utilization":3,"resets_at":"2026-11-07T12:00:00Z"}
        }
        """#))
        var history = ProviderHistory()
        history.ingest(before)
        history.selectedID = "claude/secondary"
        try expect(history.budgets.count == 2)
        let result = try bridgeUsage(#"""
        {
            "five_hour":{"utilization":2},"seven_day":{"utilization":3},
            "limits":[{"kind":"session","percent":2,"is_active":false},
                {"kind":"weekly_all","percent":3,"is_active":false},
                {"kind":"weekly_scoped","percent":2,"is_active":false,"scope":{"model":{"display_name":"Fable"}}}]
        }
        """#)
        try expect(result["noActiveLimits"] as? Bool == true)
        let inactive = try bridgeSnapshot(result, now: quotaDate.addingTimeInterval(60))
        try expect(inactive.accountKey == before.accountKey && inactive.response.windows.isEmpty)
        history.ingest(inactive)
        try expect(history.snapshot?.response.windows.isEmpty == true)
        try expect(history.budgets.isEmpty && history.selectedID.isEmpty)
        let restored = try JSONDecoder().decode(ProviderHistory.self, from: JSONEncoder().encode(history))
        try expect(restored.snapshot?.response.windows.isEmpty == true && restored.budgets.isEmpty)

        for payload in ["{}", #"{"limits":[]}"#, #"{"limits":null}"#,
                        #"{"limits":[{"kind":"unknown","is_active":false}]}"#,
                        #"{"limits":[{"kind":"session","percent":2,"is_active":"false"}]}"#,
                        #"{"limits":[{"kind":"session","is_active":true}]}"#,
                        #"{"limits":[{"kind":"session","is_active":false},{"kind":"unknown","is_active":true}]}"#] {
            let unknown = try bridgeUsage(payload)
            try expect(unknown["noActiveLimits"] as? Bool != true)
            try expectThrows { try bridgeSnapshot(unknown) }
        }
    }
}
