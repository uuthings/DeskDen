# AI subscription quotas

Subscription quota and local Token activity use different sources. A readable Claude Code session directory can supply Token records without supplying an account quota. Local Token totals never become subscription percentages or account-wide billing records.

## Codex

DeskDen reads the documented metering fields in local Codex session records. It retains the actual duration of each reported window, including a weekly window reported in the primary slot. Missing periods remain absent. No five-hour progress bar is synthesized from the subscription name.

The [official Codex pricing documentation](https://learn.chatgpt.com/docs/pricing) states that Pro plans currently have no five-hour limit. When a Pro account supplies only a weekly window, the card shows that weekly reading and a concise explanation. Any real five-hour window reported by the source is still displayed. Account limits and the official usage dashboard remain authoritative.

Some local metering records omit the membership name. Configuration can record an explicitly selected display preference, such as Plus or Pro. It appears as **用户设置** and is stored separately from quota snapshots. A plan supplied by the metering source takes precedence; the preference never changes quota history or authentication files.

## Claude Code

**连接本机订阅** reads the login the local Claude Code client already uses and queries its five-hour and weekly limits. The dialog and the connection manager show one action that follows the result: the quota once a membership login is found, **登录 Claude 会员** when Claude Code has no usable membership login, and **重新检测** after the person changes a login elsewhere. The Claude desktop app keeps its own login and does not share it with the Claude Code client in Terminal, so a paid desktop account does not make this query a membership login.

The official status reports where a login comes from. DeskDen responds without replacing a login of another kind:

- No login, an expired membership login or one without the profile scope: **登录 Claude 会员** runs the official `claude auth login --claudeai` for the configuration in use. The browser page completes authentication, and Terminal uses the same login afterwards.
- An Anthropic Console login (`apiKeySource` reported as `/login managed key`): DeskDen explains that it bills the API, not the membership, and shows `claude auth logout && claude auth login --claudeai`, which it can copy before opening Terminal. The person runs it; DeskDen never logs out an existing login.
- `apiKeyHelper`, an API key configured in Claude Code settings, or a provider such as Bedrock: the message names the override, and the separate login is the alternative.

**高级连接方式 → 为方寸单独登录会员** opens the official login with a DeskDen-only configuration directory, for people who keep a different login in Terminal. The local CLI login and existing status-line configuration remain intact. **改回本机登录** signs that configuration out through the official client and returns to the local login. Authentication and credential storage belong to the official client; DeskDen does not read or copy its tokens. The [official multi-account documentation](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts) describes this configuration-directory isolation.

Active quota queries use the unmodified, signed macOS native Claude Code client and its experimental `get_usage` control request with `skip_behaviors: true`. No user message, generation request, session-history scan, hook or MCP tool is sent or enabled. The client runs without inherited `ANTHROPIC_*`, `CLAUDE_CODE_*` and `CLAUDECODE` variables; only a chosen `CLAUDE_CONFIG_DIR` is kept. A credential, provider switch or host-session variable from a terminal, Xcode or another agent therefore cannot change which login is read. The interface is published in the [official Agent SDK release](https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.169) and remains experimental; the request and its response schema were checked with Claude Code 2.1.311. Unsupported clients receive an explicit update message rather than fabricated quota values.

Background queries share one in-flight request, cache successful readings for 60 seconds and back off after failures. Explicit rechecks bypass old identity results while retaining short click protection and rate-limit backoff. Queries run separately from local Token scanning. Timeouts, network failures, expired authorization and logins without membership quota have distinct connection messages; failures preserve the last valid observation and its original timestamp.

Only quota percentages, reset instants, collection time, source and a supplied membership plan enter quota history. Missing windows remain absent, not zero. The official response uses ISO 8601 reset timestamps; the legacy [status-line adapter](https://code.claude.com/docs/en/statusline) uses epoch seconds and remains supported separately. Existing quota JSON and manual imports remain available. Connecting no longer installs or replaces a status line automatically. Turning off automatic reading stops both active quota queries and local source scanning while retaining history.

## Quota colors and reset times

Subscription cards place the category tag beside the title, with a 32-point source icon and a smaller subtitle. Quota meters use the shared consumed-percentage colors: the normal theme color below 70%, yellow from 70% and red from 90%. Integer percentages round down, so a reading below 90% cannot display 90% while its bar remains yellow. The same thresholds apply to quota history, Mini and desktop widgets. Notification thresholds remain independently configurable; changing a notification rule does not change these colors. Local Token activity is a separate measurement and does not use quota danger thresholds.

A known reset shows remaining days and hours, or hours and minutes below 24 hours. Less than one minute is **即将重置**; after the instant passes, **已到重置时间，等待更新** preserves the previous reading. The countdown updates every minute and on return or wake without making extra source requests or assuming that an allowance has reset. Last-observation labels show elapsed time; the exact date/time remains in their tooltips and source details.

Reset details show the full workbench date and time, selected city or location label, timezone identifier and GMT offset at the reset instant. If the source explicitly supplies a named timezone, a second row shows that same instant in the source timezone. Otherwise it states that the source timezone was not provided: a Unix timestamp or an ISO timestamp's offset alone does not establish the provider's billing timezone. Switching the workbench timezone changes calendar labels, not the elapsed time until reset. Missing reset times remain unavailable; a date without a time is preserved without conversion or a countdown.

## State and freshness

- The green state dot means a fresh, valid quota reading is available.
- Configured sources waiting for their first window show a waiting state.
- Readings older than 15 minutes or crossing their reported reset time are marked stale, with their original value and sampling time retained.
- Imported and manually entered readings retain their provenance. They do not establish an authenticated account connection.
