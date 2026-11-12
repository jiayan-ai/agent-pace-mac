import Foundation
import CryptoKit

public struct ClaudeOrganization: Decodable, Equatable {
    public let uuid: String
    public let name: String
}

/// Only quota data crosses the WebKit boundary; session cookies stay in WebKit.
public struct ClaudeWebReply: Decodable {
    public let status: Int
    public let organizations: [ClaudeOrganization]?
    public let organization: String?
    public let usage: ClaudeUsageResponse?
    public let retryAfter: Double?
    public let noActiveLimits: Bool?
    public let readFailurePhase: String?
    public let soleOrganization: Bool?
    public struct ResetSection: Decodable {
        let text: String
        let hasEnabledResetButton: Bool
        let organization: String
    }
    public let resetSection: ResetSection?

    public func snapshot(now: Date = Date(), observedSection: ResetSection? = nil) throws -> UsageSnapshot {
        switch status {
        case 200: break
        case 401: throw ClaudeUsageError.notSignedIn
        case 403: throw ClaudeUsageError.scopeMissing
        case 409: throw ClaudeUsageError.ambiguousAccount
        case 429: throw ClaudeUsageError.throttled(max(300, min(3600, retryAfter ?? 600)))
        default: throw ClaudeUsageError.network
        }
        guard let organization, UUID(uuidString: organization) != nil,
              organizations?.contains(where: { $0.uuid.lowercased() == organization.lowercased() }) == true,
              let usage else { throw ClaudeUsageError.invalidResponse }
        var response = usage.normalized
        response.claudeNoActiveLimits = noActiveLimits == true
        if let section = observedSection ?? resetSection, section.organization.lowercased() == organization.lowercased() {
            response.claudeLimitResets = ClaudeLimitResets.parse(sectionText: section.text,
                                                                hasEnabledResetButton: section.hasEnabledResetButton)
        }
        guard !response.windows.isEmpty || noActiveLimits == true || response.claudeLimitResets != nil else {
            throw ClaudeUsageError.unavailable
        }
        // A web subscription is scoped to an organization. A separate namespace
        // intentionally starts a fresh baseline when migrating from desktop OAuth.
        let identity = "claude-web/" + organization.lowercased()
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return UsageSnapshot(response: response, accountKey: hash, fetchedAt: now)
    }
}

public enum ClaudeWebAPI {
    public static let usagePage = URL(string: "https://claude.ai/settings/usage")!

    public static func isClaudeOrigin(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host?.lowercased() == "claude.ai" && (url?.port == nil || url?.port == 443)
    }

    public static func isUsagePage(_ url: URL?) -> Bool {
        isClaudeOrigin(url) && (url?.path == "/settings/usage" || url?.path == "/settings/usage/"
            || url?.fragment == "settings/usage")
    }

    // A normal browser navigation loads the signed-in settings page. Confine
    // the observation to its own rendered reset section; never press its controls.
    static let readResetSection = #"""
        function readResetSection() {
            if (location.origin !== 'https://claude.ai') return null;
            const canonical = /^\/settings\/usage\/?$/.test(location.pathname);
            if (!canonical && location.hash !== '#settings/usage') return null;
            const visible = el => !el.closest('[hidden], [inert], [aria-hidden="true"], nav, aside') &&
                el.getClientRects().length && getComputedStyle(el).visibility === 'visible';
            const dialogs = Array.from(document.querySelectorAll('[role="dialog"], dialog[open], [aria-modal="true"]')).filter(visible);
            const headings = 'h1,h2,h3,h4,h5,h6,[role="heading"]';
            const title = /^(?:usage(?: settings)?|用量|使用情况|使用量)$/i;
            const label = /^(?:limit resets?|额度重置|限额重置|使用限额重置|用量限额重置|用量限制重置|用量重置|使用限制重置|限制重置)$/i;
            const allHeadings = Array.from(document.querySelectorAll(headings));
            readerStatus.dialog = dialogs.length > 0;
            readerStatus.usageTitle = allHeadings.some(h => title.test(h.textContent.trim()));
            readerStatus.resetTitle = allHeadings.some(h => label.test(h.textContent.trim()));
            readerStatus.resetVisible = allHeadings.some(h => label.test(h.innerText.trim()) && visible(h));
            readerStatus.offerButton = Array.from(document.querySelectorAll('button,[role="button"]')).some(b =>
                /^(?:reset for free|免费重置)/i.test((b.innerText || b.getAttribute('aria-label') || '').trim()));
            const settings = dialogs.find(el => Array.from(el.querySelectorAll(headings)).some(h =>
                visible(h) && title.test(h.innerText.trim())));
            let root = settings || (canonical && !dialogs.length ? document.querySelector('main, [role="main"]') || document.body : null);
            if (!root && !dialogs.length && location.hash === '#settings/usage') {
                const titles = Array.from(document.querySelectorAll(headings)).filter(h => title.test(h.innerText.trim()) && visible(h));
                if (titles.length === 1) {
                    let box = titles[0].parentElement;
                    while (box && box !== document.body) {
                        if (Array.from(box.querySelectorAll(headings)).some(h => label.test(h.innerText.trim()) && visible(h))) { root = box; break; }
                        box = box.parentElement;
                    }
                }
            }
            readerStatus.scopedRoot = !!root;
            if (!root) return null;
            let heading = Array.from(root.querySelectorAll(headings)).find(h => label.test(h.innerText.trim()) && visible(h));
            for (const el of root.querySelectorAll('h1,h2,h3,h4,h5,h6,[role="heading"],p,span,strong,div')) {
                if (heading) break;
                if (el.childElementCount === 0 && label.test(el.textContent.trim()) && visible(el)) {
                    heading = el.closest('h1,h2,h3,h4,h5,h6,[role="heading"]') || el;
                    break;
                }
            }
            readerStatus.sectionTitle = !!heading;
            if (!heading) return null;
            const section = heading.closest('section, [role="region"]') || root;
            const level = el => Number(el.getAttribute('aria-level') || el.tagName.slice(1)) || 3;
            const boundary = Array.from(section.querySelectorAll(headings)).find(el =>
                (heading.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) &&
                !heading.contains(el) && visible(el) && level(el) <= level(heading) &&
                !/(?:reset|fable|重置)/i.test(el.innerText));
            const within = el => (heading.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) &&
                (!boundary || (boundary.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING));
            const lines = section.innerText.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
            const start = lines.findIndex(s => label.test(s));
            readerStatus.lineFound = start >= 0;
            if (start < 0) return null;
            const end = boundary?.innerText.trim();
            const text = [lines[start]];
            for (const line of lines.slice(start + 1, start + 65)) {
                if (line === end || /^(?:usage credits?|extra usage|weekly limits?|plan usage limits?|payment method|用量点数|额外用量|额外使用量|每周限额|付款方式)$/i.test(line)) break;
                if (line.length > 400) break;
                // All copied labels must belong to a reset offer. In particular
                // never return adjacent workspace names, emails or payment data.
                if (/(?:reset|expires?|expir(?:y|ation)|remaining|available|Fable|重置|到期|有效期|剩余|可用)/i.test(line) ||
                    /^(?:[0-9]{1,3}|[\d\s:.,/-]{4,30}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}(?:,\s*\d{4})?)$/i.test(line)) {
                    text.push(line);
                }
            }
            const action = /^(?:reset for free(?: (?:full|fable|weekly|session) reset)?|免费重置|免費重置)$/i;
            const hasEnabledResetButton = Array.from(section.querySelectorAll('button, [role="button"]')).some(el =>
                within(el) && visible(el) && !el.disabled && el.getAttribute('aria-disabled') !== 'true' &&
                action.test((el.innerText || el.getAttribute('aria-label') || '').trim()));
            if (text.length < 2 && !hasEnabledResetButton) return null;
            return {text:text.join('\n'), hasEnabledResetButton};
        }
    """#

    // Read the rendered offers only when attributed to the selected workspace.
    public static let resetSectionScript = #"""
    if (location.origin !== 'https://claude.ai') return null;
    const canonical = /^\/settings\/usage\/?$/.test(location.pathname);
    const hash = location.hash === '#settings/usage';
    const groups = {usage:new Set(), reset:new Set(), metering:new Set(), workspace:new Set()};
    const classify = ids => ids.size === 0 ? 'none' : ids.size !== 1 ? 'multiple' :
        (ids.has(selectedOrganization.toLowerCase()) ? 'selected' : 'different');
    const readerStatus = {route:canonical ? 'usage' : (hash ? 'dialog' : 'other'), single:soleOrganization, matched:false, heading:false};
    if (!canonical && !hash) return {readerStatus};
    // This is a new document in a separate WebView. It never runs the API
    // bridge, so its observed /usage request can only have come from Claude.
    for (const item of performance.getEntriesByType('resource')) {
        const u = new URL(item.name, location.origin);
        if (u.origin !== location.origin || !['fetch','xmlhttprequest'].includes(item.initiatorType)) continue;
        const m = /^\/api\/organizations\/([0-9a-f-]{36})(?:\/(.*))?$/i.exec(u.pathname);
        if (!m) continue;
        const id = m[1].toLowerCase(), path = (m[2] || '').toLowerCase();
        groups.workspace.add(id);
        if (/^usage\/?$/.test(path)) groups.usage.add(id);
        if (/reset/.test(path)) groups.reset.add(id);
        if (/(?:usage|limit)/.test(path)) groups.metering.add(id);
    }
    readerStatus.usage = classify(groups.usage);
    readerStatus.reset = classify(groups.reset);
    readerStatus.metering = classify(groups.metering);
    readerStatus.workspace = classify(groups.workspace);
    const positive = readerStatus.usage === 'selected';
    const conflict = ['usage','reset','metering'].some(key =>
        readerStatus[key] === 'different' || readerStatus[key] === 'multiple');
    readerStatus.matched = !conflict && (positive || (soleOrganization &&
        (readerStatus.workspace === 'none' || readerStatus.workspace === 'selected')));
    if (!readerStatus.matched) return {readerStatus};
    \#(readResetSection)
    const section = readResetSection();
    readerStatus.heading = !!section;
    if (section) section.organization = selectedOrganization;
    return {section, readerStatus};
    """#

    // Runs in an isolated content world on claude.ai, using that page's own
    // session. Never reads cookies, passwords, messages, or a desktop keychain.
    public static let script = #"""
    if (location.origin !== 'https://claude.ai') return JSON.stringify({status:401});
    const get = async (path, phase) => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 30000);
        try {
            const r = await fetch(path, {method:'GET', credentials:'same-origin',
                cache:'no-store', redirect:'error', headers:{Accept:'application/json'}, signal:controller.signal});
            if (!r.ok) return {status:r.status, retryAfter:Number(r.headers.get('Retry-After')) || 600, readFailurePhase:phase+' http'};
            if (!(r.headers.get('Content-Type') || '').includes('application/json')) return {status:401};
            const text = await r.text();
            if (text.length > 1000000) return {status:502};
            return {status:200, data:JSON.parse(text)};
        } catch {
            return {status:503, readFailurePhase:phase+(controller.signal.aborted ? ' timeout' : ' read')};
        } finally { clearTimeout(timer); }
    };
    try {
        const result = await get('/api/organizations', 'workspaces');
        if (result.status !== 200) return JSON.stringify(result);
        if (!Array.isArray(result.data)) return JSON.stringify({status:502});
        const organizations = result.data.filter(o => typeof o.uuid === 'string' &&
            /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(o.uuid))
            .map(o => ({uuid:o.uuid, name:typeof o.name === 'string' ? o.name.slice(0,120) : 'Claude'}));
        const selected = organizations.find(o => o.uuid === selectedOrganization);
        // Never silently switch to a different organization when a saved choice disappears.
        const org = selected || (!selectedOrganization && organizations.length === 1 ? organizations[0] : null);
        if (!org) return JSON.stringify({status:organizations.length ? 409 : 401, organizations});
        const resultUsage = await get('/api/organizations/' + encodeURIComponent(org.uuid) + '/usage', 'usage');
        if (resultUsage.status !== 200) return JSON.stringify({status:resultUsage.status, retryAfter:resultUsage.retryAfter, readFailurePhase:resultUsage.readFailurePhase, organizations});
        const usage = {};
        const limits = Array.isArray(resultUsage.data?.limits) ? resultUsage.data.limits : [];
        const modelRows = name => limits.filter(row => row?.kind === 'weekly_scoped' &&
            row?.scope?.model?.display_name === name);
        const groups = [
            ['five_hour', limits.filter(row => row?.kind === 'session')],
            ['seven_day', limits.filter(row => row?.kind === 'weekly_all')],
            ['seven_day_sonnet', modelRows('Sonnet')],
            ['seven_day_opus', modelRows('Opus')],
            ['seven_day_fable', modelRows('Fable')]
        ];
        for (const [key, rows] of groups) {
            // Current limits can explicitly disable a legacy meter while the
            // old percentage and reset timestamp continue to be returned.
            // An ambiguous or malformed current row must not revive that meter.
            if (rows.length > 1) continue;
            const window = rows.length === 1 ? rows[0] :
                (key === 'seven_day_fable' ? null : resultUsage.data?.[key]);
            if (!window || (window.is_active !== undefined && window.is_active !== true)) continue;
            const percent = rows.length === 1 ? window.percent : window.utilization;
            if (typeof percent !== 'number' || !Number.isFinite(percent) || percent < 0) continue;
            usage[key] = {utilization:percent,
                resets_at:typeof window.resets_at === 'string' ? window.resets_at : null};
        }
        // Only an explicit all-inactive response may clear a cached snapshot.
        // Unknown/empty/malformed data still reports an error, not "no limits".
        const noActiveLimits = Object.keys(usage).length === 0 && limits.length > 0 &&
            groups.some(([,rows]) => rows.length > 0) &&
            limits.every(row => row && row.is_active === false);
        return JSON.stringify({status:200, organizations, organization:org.uuid, usage, noActiveLimits, soleOrganization:result.data.length === 1 && organizations.length === 1});
    } catch { return JSON.stringify({status:503, readFailurePhase:'bridge'}); }
    """#
}
