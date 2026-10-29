# Agent Pace for macOS

Windows version: [agent-pace-windows](https://github.com/jiayan-ai/agent-pace-windows).

English · [简体中文](README.zh-CN.md)

A native macOS menu bar app that helps you pace your **Codex and Claude subscription usage**. See how much you can use today—or per hour in Claude's five-hour window—and when your quota resets.

[Download the latest release](https://github.com/jiayan-ai/agent-pace-mac/releases/latest)

## Features

- Switch between Codex and Claude Code, with separate records for each provider and quota window.
- Weekly windows: a fixed daily allowance, with actual usage deducted throughout the day. Overspending stays visible as a negative balance and appears red in the details panel.
- Claude five-hour window: a rolling hourly allowance and a prominent reset countdown. In the final partial hour, see the actual quota left before reset.
- Claude Fable: a separate weekly view when the account reports a Fable quota.
- Codex reset credits: available count, reported expiry dates and rule-based advice using the last 30 days of account activity.
- Tibo reset updates: public announcement records, source links and an in-app window for the Will Codex Reset community forecast.
- English and Simplified Chinese, with an in-app language switch.
- Automatic quota sync every five minutes, refresh after wake, and optional launch at login.
- Native SwiftUI, AppKit and WebKit. No third-party libraries, model requests or automatic reset redemption.

## Install

1. Download `Agent-Pace-…-universal.zip` from [Releases](https://github.com/jiayan-ai/agent-pace-mac/releases/latest).
2. Quit any older copy, unzip the download and move **Agent Pace.app** to **Applications**.
3. Open the app. Click its menu bar label to view details; click again or click outside to close them. A separate window is also available from the panel's More options menu.

Requires **macOS 13 or later**. The download contains Apple Silicon and Intel binaries. Apple Silicon has been tested on a real Mac; Intel has not yet been tested on hardware.

**Signing status:** the current download is ad-hoc signed, not Developer ID signed or notarized. macOS may block the first launch. After verifying the download source, follow [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445). Do not disable system security checks. A `.sha256` file accompanies each release.

Agent Pace does not need macOS **App Management** permission to update or delete other applications. It has no app installer or automatic app updater. Launch at login is a separate, optional setting.

## Language

The app supports **English** and **简体中文**. On first launch it follows your system's preferred supported language, falling back to English.

Click the **globe icon** at the top of the panel and choose **System**, **English** or **简体中文**. The change takes effect immediately and is remembered across launches. It covers the panel, menu bar messages, errors, reset advice and the Claude connection window. Your account records and budgets do not change.

Third-party web pages and names supplied by the services retain their original language.

## Connect your accounts

### Codex

Install and sign in to ChatGPT / Codex Desktop or the Codex CLI. Agent Pace uses the existing subscription account through the local Codex app server; you do not need to enter an API key. API-key-only sign-in does not supply subscription quota data.

### Claude

Click **Connect Claude**, sign in at `claude.ai` inside Agent Pace's connection window, then click **Sync usage**. Use the same account as Claude Desktop Code. Agent Pace remembers its own web session and refreshes automatically; it does not require a CLI sign-in or a Mac Keychain password.

Users upgrading from the old desktop-credential integration must connect once using this flow. An expired session may require signing in again. For accounts with multiple organizations, select the organization explicitly.

Claude's subscription quota is shared across its apps. This view cannot isolate usage generated only by Desktop Code. Fable usage also counts toward the overall weekly quota and remains subject to the five-hour limit; it is not an extra independent weekly allowance. See [Claude's Fable plan documentation](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).

## How pacing works

### Daily budgets for weekly windows

At the first successful sync each local day:

```text
Remaining R = clamp(100 − used percent, 0, 100)
Planning days D = max(1, seconds until reset ÷ 86,400)
Daily allowance B = R ÷ D
Available today = min(current remaining, B − usage since today's first sync)
```

For example, 70% remaining with seven days until reset gives a 10% daily allowance. Using another four percentage points leaves 6% for today. The daily allowance is fixed rather than recalculated after every refresh.

If you use 17 percentage points against a 10% allowance, the balance is **−7.0%**. The details panel turns red; the menu bar follows the system's normal color. The next day starts from the actual remaining quota without deducting yesterday's excess again.

- Fractional days are retained. Less than one day is treated as one day.
- Budgets reset on a new local day, account or timezone change, a material reset-time change, or a decrease in reported usage. Small timestamp jitter does not erase the daily record.
- Usage before the first sync cannot be reconstructed reliably; the panel shows the observation start time.
- Records survive app restarts. Each quota window is tracked separately; percentages from different windows are not directly comparable.

### Codex reset credit expiring sooner

When a usable Codex reset credit expires within 72 hours and before the selected main Codex quota window's natural reset, Agent Pace uses the **credit expiry as a planning deadline**. The main panel and menu bar show a rolling hourly suggestion instead of the daily balance, even if the earlier daily budget was exceeded. For example, 50% of the window remaining with 10 hours until the credit expires gives **5% / hour**. The countdown and suggestion change as time passes and usage is synced. In the final partial hour, the panel shows the actual remaining quota before expiry.

This is a plan for the existing quota, not an automatic reset. The credit expiring does **not** reset the account; use it manually in Codex if needed. The natural reset remains separate. When no credit meets these conditions, the normal daily budget remains in view. The app uses the earliest known, available credit, requires confirmed account data, and never guesses an unknown expiry. If a credit reaches its recorded expiry while the server still reports it as available, refresh to confirm the current status.

### Claude's five-hour window

Choose **Claude · 5 hours** in the quota picker:

```text
Suggested hourly allowance = remaining quota ÷ hours until reset
```

With 60% remaining and three hours until reset, the suggestion is **20% / hour**, shown as `Claude 20.0%/h` in the menu bar. It changes with time and newly synced usage.

With less than an hour left, the panel switches to **Available before reset** and shows the actual remaining quota. The menu bar adds `<1h`; the app does not inflate the number into an hourly rate you cannot actually spend.

The countdown updates every 15 seconds. When it reaches zero, the app waits for the server to confirm the next window instead of assuming quota has returned to 100%. It checks expired Claude windows at intervals of at least 60 seconds, while respecting sign-in state and server throttling.

These are percentage points of a quota, **not minutes of work**. Consumption depends on the model and task. Overall weekly or model-specific limits may run out before the selected window.

### Missing or stale data

Missing data is never treated as zero usage. Expired windows wait for fresh data. Offline or unconfirmed records are labeled as last known; the menu bar uses `≈` for stale estimates. A one-decimal display does not imply the service measures usage to that precision.

## Reset advisor

The Codex panel reads available reset counts, reported expiry details and 30 days of daily token activity through the local app server. Expand **30-day patterns & reset details** to see the chart and recommendations.

- Only complete dates in the preceding 30 days are considered, using the API's UTC date labels. Missing days are not zero; duplicate buckets are not added together.
- Pattern advice needs at least 14 valid days. Weekday patterns need at least three samples for that weekday and are smoothed toward the overall mean. Recent trends require sufficient data in both comparison periods.
- Each Codex window is assessed independently. When nearly depleted windows reset naturally within six hours, waiting is preferred if work can wait. A depleted window with more than six hours to go may justify a reset if you need to continue.
- Low quota combined with likely higher demand prompts reassessment before focused work. Credits expiring within three days are prioritized when a reset is actually needed.
- Stale quota, expired credit details or incomplete windows require a refresh before advice. History older than six hours is not used for pattern advice.

This is explainable, local rule-based guidance. Token activity cannot be converted directly into quota percentage, so the app does not promise an accurate depletion forecast. It never redeems credits automatically or encourages unnecessary usage just to spend a credit. A negative daily budget alone is not a reason to reset.

Claude's current endpoint does not provide reset credits or account-wide monthly history. Agent Pace does not invent those values or provide monthly reset advice for Claude.

## Tibo reset updates

The Codex panel checks the anonymous [Codex Reset public API](https://codexreset.dev/api/) every 15 minutes, with a minimum one-minute interval for manual refreshes. It distinguishes community records, tracker-verified events and pending announcements, and links to original sources. “Today” is based on your Mac's local timezone.

**View 24 / 48-hour forecast** opens [Will Codex Reset](https://willcodexreset.com/) in a separate app-owned browser window. There is no numerical API integration, background scraping, probability cache or reinterpretation of that site's predictions. Loading status, timestamps and methodology are determined by the website itself.

Announcements, credit grants and actual delivery to your account are different events. Public records never increase your budget or redeem a credit. No record today does not mean no reset will happen. Outdated, failed or unknown sources are labeled unconfirmed, retaining the last record. Community forecasts are not OpenAI commitments.

Automatic public-feed sync can be disabled under **Records & sources**.

## Privacy and data sources

### Codex

Agent Pace uses the [Codex app server](https://learn.chatgpt.com/docs/app-server) methods `initialize`, `account/read`, `account/rateLimits/read` and `account/usage/read`. It does not call `turn/start` or `account/rateLimitResetCredit/consume`, launch model inference or read Codex authentication tokens.

Account identity and workspace routing are hashed to separate records. Plaintext email addresses are not persisted. Quota snapshots, daily baselines, reset information and activity history are stored locally in:

```text
~/Library/Application Support/CodexPace/state.json
```

The old directory name is retained for upgrade compatibility. History is analyzed locally and is not uploaded to an analytics service. Errors do not log raw service responses.

### Claude

Agent Pace uses its own persistent WebKit session. It does not read Claude Desktop's configuration, OAuth cache, Safe Storage or another browser's cookies. The quota bridge makes same-origin GET requests for organizations and usage, and returns organization identity and quota windows—not cookies or passwords.

This is a normal Claude web sign-in, not an official quota-only authorization. The account identity is hashed in budget history; the selected organization UUID is stored in local preferences. **Disconnect Claude** stops syncing and removes Agent Pace's website session without signing out other apps or browsers.

Claude's usage endpoint is not a stable public third-party API. Site changes can require maintenance. Sign-in expiry, verification challenges and throttling are surfaced explicitly. If verification is unsupported in the embedded browser, the app remains disconnected; it does not fall back to Keychain decryption or bypass verification.

### Public reset sources

The reset feed uses anonymous GET requests without account data, credentials, cookies or usage history. Its separate cache is `reset-radar.json` beside the local state file. The forecast window uses a nonpersistent WebKit session without a script bridge or page extraction, and loads only when requested. The website can load its own third-party resources under its own privacy policy.

## Build from source

Requires macOS 13+ and a Swift 6 toolchain, supplied by Xcode 16+ or compatible Apple Command Line Tools. There are no third-party package dependencies.

```sh
git clone https://github.com/jiayan-ai/agent-pace-mac.git
cd agent-pace-mac
bash scripts/test.sh
bash scripts/build.sh
open "dist/Agent Pace.app"
```

Build a universal release archive:

```sh
bash scripts/package-release.sh
```

Read-only live connection checks (Claude must already be connected in the app):

```sh
"dist/Agent Pace.app/Contents/MacOS/AgentPace" --check-connection
"dist/Agent Pace.app/Contents/MacOS/AgentPace" --check-claude
"dist/Agent Pace.app/Contents/MacOS/AgentPace" --check-reset-radar
```

On a Mac with a graphical desktop, check menu bar rendering, repeated open/close actions and screen boundaries. This briefly opens a test popover without fetching account data:

```sh
"dist/Agent Pace.app/Contents/MacOS/AgentPace" --check-menu
```

Signing and notarization scripts are documented in the [signing guide (Chinese)](docs/NOTARIZATION.md). Having those scripts does not mean Apple has accepted a notarization submission; only a verified notarized artifact receives the `-notarized.zip` suffix.

## Feedback and project status

When reporting a problem, include the macOS version, app version and error message. Do not attach authentication tokens, Keychain secrets, Claude configuration files or complete personal usage records.

Agent Pace is not affiliated with OpenAI or Anthropic. The repository does not currently specify an open-source license.
