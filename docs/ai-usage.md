# AI subscription quotas

Subscription quota and local Token activity use different sources. A readable Claude Code session directory can supply Token records without supplying an account quota. Local Token totals never become subscription percentages or account-wide billing records.

## Codex

Fangcun reads the documented metering fields in local Codex session records. It retains the actual duration of each reported window, including a weekly window reported in the primary slot. Missing periods remain absent. No five-hour progress bar is synthesized from the subscription name.

The [official Codex pricing documentation](https://learn.chatgpt.com/docs/pricing) states that Pro plans currently have no five-hour limit. When a Pro account supplies only a weekly window, the card shows that weekly reading and a concise explanation. Any real five-hour window reported by the source is still displayed. Account limits and the official usage dashboard remain authoritative.

Some local metering records omit the membership name. Configuration can record an explicitly selected display preference, such as Plus or Pro. It appears as **用户设置** and is stored separately from quota snapshots. A plan supplied by the metering source takes precedence; the preference never changes quota history or authentication files.

## Claude Code

Use **连接 Claude 额度 → 启用额度同步** to connect the [official Claude Code status line](https://code.claude.com/docs/en/statusline). This is an explicit setup action. Fangcun adds its own status-line command only when no other command is configured. An existing different status line is preserved; use the exported adapter or an existing quota JSON file to combine sources manually.

After setup, restart Claude Code and complete a request. The status line invokes a short-lived mode of the Fangcun app, so the automatic connection does not require a separate Python installation. Keep the app at the location used during setup. If it moves, review the Claude status-line command before reconnecting.

Only the official `rate_limits.five_hour` and `rate_limits.seven_day` percentages and reset times are written to the private quota snapshot. Context-window percentages, prompts, credentials and other status-line fields are discarded. A snapshot is not created until a real quota window is available. Missing windows do not become zero, and a response without quota fields preserves the last reading, which can become stale.

Claude Code exposes these fields only for supported subscription or gateway accounts, after a response. Each window may be absent independently. The status-line schema does not provide a reliable subscription plan name, so any selected Pro, Max, Team or Enterprise name is marked as a user setting.

Selecting a quota JSON remains available for an existing status-line setup. The advanced exported Python adapter is an alternative for manual integration; exporting it alone does not configure Claude Code. Disabling automatic reading or removing the JSON connection stops Fangcun from reading that source and retains existing local history.

## State and freshness

- The green state dot means a fresh, valid quota reading is available.
- Configured sources waiting for their first window show a waiting state.
- Readings older than 15 minutes or crossing their reported reset time are marked stale, with their original value and sampling time retained.
- Imported and manually entered readings retain their provenance. They do not establish an authenticated account connection.
