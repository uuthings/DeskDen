# Provider usage and network monitoring

The **用量与额度** navigation entry combines existing AI quotas and local Token activity with independent service quota sources. Each IPRoyal order and Bandwagon VPS keeps its own identity, balance, last successful observation and reset rule. The **网络监控** module remains separate and keeps its existing single local traffic budget.

The overview uses one responsive list with a minimum card width of 248 logical points, 14-point padding and 12-point gaps. Cards expand into equal-width columns and wrap when necessary. Categories, filters and sorting affect presentation only; they do not stop querying, change balances or delete records. **Token 活动** is a separate summary destination, with detailed history in each AI source.

Use **配置用量** to manage the two categories. AI cards use the supported Codex and Claude source identities; hiding or restoring a card does not disconnect its collector or delete activity records. It does not create additional accounts sharing one set of readings. Service sources remain independently configurable. Card display names and icons are separate from connection metadata. Choose an included symbol or import a static PNG, JPEG or WebP image up to 2 MB; DeskDen keeps a small normalized local copy, so the original file can move. Card icons contain no authentication information.

Service cards show remaining allowance, cycle consumption and total allowance, the provider's reset information, and the last successful observation. Missing or stale data remains explicit. Details include **打开 IPRoyal 订单** for the configured order's official dashboard page, or **打开搬瓦工服务** for the provider's services page. These links open in the default browser without attaching the API Key or browser-session material.

Service balances come from the provider. Local received/sent bytes are only an activity signal that decides when to query again; they are never subtracted from a provider balance or attributed to a particular subscription. Unknown values remain unknown. A failed query retains the last successful reading and its timestamp.

## Bandwagon VPS

Add a source with a display name, VEID and API Key. A successful read is required when adding a VPS, changing its identity or replacing its credential. The key is kept in the macOS Keychain; the JSON configuration only holds an opaque credential reference. Leaving the key blank while editing the same instance preserves the existing key without querying it again.

### Connect a VPS

1. Open **用量与额度 → 配置用量 → 服务流量 → 新增服务流量**, then choose **搬瓦工**. The connection form also links to the [official services page](https://bandwagonhost.com/services).
2. In the provider's services page, choose the intended VPS and open **Open KiwiVM → API → Show API Key**. Use its **VEID**, not the billing service/order number. Copy the existing key; **Reset API Key** replaces it and can break other integrations.
3. Enter the VEID and API Key directly in DeskDen's secure connection form. A website or VPS password is not required. No browser extension is required, and the key should not be sent in a chat, screenshot or support report. This is the instance's provider-issued key, which may also permit management operations; DeskDen itself only calls the read endpoint below.
4. Click **验证并保存**. The app queries the provider before saving anything. Compare the resulting consumed/total allowance with **KiwiVM → Main controls → Bandwidth usage**; allow for the two observations being taken at different times. The remaining allowance is the provider-adjusted total minus consumed usage, clamped to zero when exhausted.
5. Check the next-reset timestamp and its displayed timezone, then refresh once and reopen DeskDen to check saved-connection continuity. Each additional VPS repeats this flow with its own key, allowance and reset timestamp.

Editing only the name, icon, visibility or refresh policy while leaving the saved key unchanged uses **保存修改**. It does not claim that the credential was queried again. Enter a key to validate a new or replacement connection; failures retain the prior saved connection and reading.

The client uses the fixed HTTPS `getServiceInfo` endpoint with a POST body. It reads `plan_monthly_data`, `data_counter`, `monthly_data_multiplier` and `data_next_reset`; the multiplier applies to both the allowance and counter. Values use the platform's binary GB convention. The application does not apply an additional upload/download multiplier. Reset timestamps are displayed in the selected workbench timezone, including daylight-saving changes.

The authoritative API documentation is available under **KiwiVM → API** after signing in. It permits GET or POST parameters and defines the reset value as a Unix timestamp. `getServiceInfo` already includes the quota fields; `getLiveServiceInfo` adds VM status and may take up to 15 seconds, so it is not needed for quota queries. The reset detail shows the full date and timezone identifier with the UTC offset **at that reset instant**. It does not assume a fixed monthly reset day, the VPS location's timezone or the billing renewal date. A provider date shown without a time cannot by itself verify that instant.

An API Key may have broader management permissions at the provider; this integration only implements the read operation. It does not modify the VPS, plan or billing settings. HTTP authentication failures pause automatic querying until reconfiguration. Rate limiting and temporary failures keep the previous reading and delay retrying.

## IPRoyal static ISP

The official reseller API Token supports product and order reads, but has not authorized the dashboard's static ISP quota endpoint. Entering that Token is therefore not offered as a working static ISP quota connection.

The optional Chrome connector reuses the user's ordinary dashboard login. It observes only quota and reset fields from known order GET responses; it does not extract Google credentials, login cookies, tokens or request headers. Its source, exact permissions, installation and removal instructions are in [the connector guide](../Launcher/BrowserConnectors/IPRoyal/README.md).

In the IPRoyal connection dialog, click **安装本机连接** to register Chrome's local connection for the current user, then export a connection kit and load its `Extension` folder from `chrome://extensions` with Developer mode enabled. Enable the connector in its popup and add the static ISP order number in DeskDen. This setup does not require opening a downloaded script or administrator access. Older App versions without the installation button can follow the explicit Terminal steps in [the installation guide](../Launcher/BrowserConnectors/IPRoyal/INSTALL.md#旧版-app-的安装方式).

The App and exported kit must remain at stable locations; reinstall the local connection after moving the App, or reload the extension after moving its folder. Exporting does not install or grant permissions. Real Chrome installation, Google login, quota comparison and session persistence require manual acceptance before relying on this route. A successful synthetic test does not establish a real login's lifetime.

The provider's `bandwidth_limit_reset_at` is currently a date-only value. It is shown as the provider's date with timezone unconfirmed, without inventing midnight or converting it into a different day. Quota observations may lag actual traffic; the query timestamp is not a billing cutoff timestamp.

Details retain a bounded cycle-change log. A later provider date together with lower usage and higher remaining allowance creates a candidate; a subsequent compatible reading confirms what DeskDen observed. An allowance change or balance increase alone is not treated as a reset. The log shows the last old-cycle observation, first new-cycle observation and confirmation time in the workbench timezone. These observations do not establish the provider's actual reset instant or timezone. Up to 12 confirmed changes are retained, with at most one pending candidate.

## Refresh policy

The default policy for each source is:

- Query initially when connected, then after at least one hour if physical network traffic accumulated since the last successful request reaches 1 GB (1000 MB).
- Query after six hours even below that activity threshold, so small amounts do not leave the cache permanently stale.
- Allow manual refresh while respecting an explicit provider rate-limit cooldown.
- Stagger automatic sources instead of starting a burst of requests.
- Suspend requests during sleep or offline periods, then reassess the persisted state after recovery.

Threshold and interval settings are editable per source. A successful request acknowledges only bytes accumulated before that request started; traffic during the request remains pending. Failed or cancelled requests retain the accumulated amount. A known reset timestamp triggers a new query once it is due and the minimum interval permits it. The local counter uses the stable physical/all ledger, unaffected by changing the local budget or resetting a realtime graph.

Disabling automatic updates does not remove the source or its cache. Removing a source asks for confirmation and removes local metadata and its own credential; it does not cancel a provider subscription. Malformed local storage is preserved and automatic writes stop until it is recovered.

## Developer checks

Core tests cover quota parsing, persistence and refresh decisions. `Launcher/scripts/check-provider-usage.sh` runs isolated HTTP and model fixtures. The App's `--usage-ui-check` renders hidden native views with synthetic sources and checks layout, navigation and draft protection. `--mini-data-check` and `--mini-appearance-check` cover the shared Mini projections and layout. These checks do not use real credentials or install the connector.

The Bandwagon fixtures exercise the full HTTP 200 → validation → save → refresh path, fractional and whole multipliers, exhausted allowances, provider JSON errors, preservation of old credentials/readings, and bounded failures. Native checks cover the connection form at narrow, normal and large widths in both appearances, as well as reset-time daylight-saving conversion. These fixtures do not establish a real account's API authorization. The initial key entry, live allowance comparison and saved-connection reopening are separate account acceptance steps.
