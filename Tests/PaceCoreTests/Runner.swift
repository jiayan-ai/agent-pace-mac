import Foundation
import PaceCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) throws {
    guard try condition() else { throw TestFailure(description: "\(file):\(line): assertion failed") }
}
func require<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line): expected a value") }
    return value
}
func expectThrows<T>(_ operation: () throws -> T) throws {
    do { _ = try operation() } catch { return }
    throw TestFailure(description: "Expected an error")
}

@main
struct Runner {
    static func main() async {
        Localization.language = .simplifiedChinese
        let budget = BudgetTests()
        let client = ClientTests()
        let providers = ProviderTests()
        let resets = ResetTests()
        let web = ClaudeWebTests()
        let radar = ResetRadarTests()
        let session = ClaudeSessionTests()
        let localization = LocalizationTests()
        let cases: [(String, () throws -> Void)] = [
            ("语言跟随系统、显式覆盖和偏好持久化", localization.testLanguageResolutionAndPersistence),
            ("语言即时切换、错误和倒计时翻译且预算不变", localization.testLiveTranslationAndInterpolation),
            ("英文词条完整性与动态参数一致性", localization.testCatalogArgumentsAndEnglishCoverage),
            ("Claude 5 小时按小时动态均摊且不受午夜影响", session.testRollingHourlyAllowanceAndMidnight),
            ("Claude 最后不足一小时、倒计时与到期等待", session.testFinalHourAndCountdownBoundaries),
            ("Claude 未知、耗尽、重置后新窗口及周额度隔离", session.testUnknownExhaustedAndNewSession),
            ("日预算与逐点扣减", budget.testDailyAllowanceAndOneForOneSubtraction),
            ("超额显示负数且次日不重复扣减", budget.testSpendingBeyondBudgetShowsNegativeBalance),
            ("小数天数与不足一天", budget.testFractionalDaysAndFinalHours),
            ("跨天重新分配", budget.testNextDayRebalancesRemaining),
            ("重置与服务端修正", budget.testResetAndUsageDecreaseStartFreshBudget),
            ("缺失、过期与耗尽额度", budget.testMissingExpiredAndExhaustedData),
            ("预算保存与恢复", budget.testBudgetSurvivesPersistence),
            ("午夜与时区变化", budget.testDayBoundaryAndTimezoneChange),
            ("多额度窗口及排序", budget.testMultipleBucketsPreferredAndLongestCodexWindowFirst),
            ("兼容旧格式与空值", budget.testLegacyAndNullFields),
            ("只读连接流程", client.testReadOnlyHandshakeAndResponseDecoding),
            ("连接超时与进程退出", client.testTimeoutIsBounded),
            ("Claude 周额度、小时额度与精确重置时间", providers.testClaudeWindowsAndDates),
            ("Claude 缺失重置时间不虚构预算", providers.testClaudeMissingResetDoesNotInventBudget),
            ("Fable 周额度、独立预算与选择持久化", providers.testFableWeeklyBudgetIsIndependentOfOverallWeeklyBudget),
            ("Fable 缺失与零用量", providers.testFableMissingAndZeroUsage),
            ("切换平台、异步返回与独立预算", providers.testProviderIsolationAndPersistence),
            ("升级保留旧版超额记录", providers.testLegacyMigrationPreservesNegativeBalance),
            ("重置时间秒级浮动不清零当天记录", providers.testResetTimestampJitterKeepsDailySpending),
            ("Claude 网页账户校验与状态错误", web.testWebIdentityAndMissingFields),
            ("Claude 网页来源约束", web.testOriginValidation),
            ("网页桥接只返回额度并要求明确选择组织", web.testBridgeOnlyReturnsUsageAndRequiresOrganizationChoice),
            ("网页登录失效、验证和限流", web.testBridgeAuthExpiryChallengeAndRateLimit),
            ("网页桥接保留 Fable 额度并过滤无关字段", web.testBridgeIncludesFableWithoutLeakingOtherFields),
            ("Fable 模型范围、零用量和重复条目", web.testFableScopeZeroMissingAndAmbiguousRows),
            ("旧版本无历史接口仍能同步额度", client.testUnavailableHistoryDoesNotBreakQuotas),
            ("Reset 总数、部分明细与未知状态", resets.testResetCountsAndUnknownDetails),
            ("近月窗口、缺失日期与去重", resets.testRollingMonthAndMissingDays),
            ("星期偏好、趋势和稀疏历史", resets.testBusyWeekdayAndTrend),
            ("实际额度、忙闲模式与自然重置建议", resets.testAdviceUsesActualQuotaInsteadOfDailyOverspend),
            ("过期券与额度重置边界", resets.testExpiringCreditsAndResetBoundaries),
            ("Reset 券到期前按小时滚动均摊", resets.testCreditPaceUsesEarliestExpiryAndCurrentRemaining),
            ("Reset 券未知、过期与自然重置边界", resets.testCreditPaceRejectsUncertainOrInapplicableData),
            ("Reset 券三天门槛及同步状态", resets.testCreditPaceThreeDayHorizonAndConfirmation),
            ("历史持久化、旧数据迁移与账户隔离", resets.testActivityPersistenceAndAccountIsolation),
            ("全局 reset、发券与来源核验等级", radar.testRecordedConfirmedAndBankedAreDistinct),
            ("Tibo 动态跨时区和午夜归属", radar.testTodayUsesLocalDayInsteadOfUpstreamUTCStatus),
            ("HTTP 成功不掩盖过期、失败及未知来源", radar.testFreshHTTPDoesNotHideStaleOrFailedSource),
            ("Reset 预告、未来记录与日期精度", radar.testPlannedFutureAndDateOnlyNeverClaimDelivery),
            ("未知记录与不可信来源链接", radar.testUnknownRecordsAndUntrustedLinksAreExcluded),
            ("Reset 缓存、去重与损坏响应", radar.testCacheAndMalformedResponses)
        ]
        var failed = 0
        for (name, test) in cases {
            do { try test(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        do { try await radar.testPublicTransportAndFailureHandling(); print("PASS 公开只读请求与失败隔离") }
        catch { failed += 1; print("FAIL 公开只读请求与失败隔离: \(error)") }
        print("\(cases.count + 1 - failed)/\(cases.count + 1) checks passed")
        exit(failed == 0 ? 0 : 1)
    }
}
