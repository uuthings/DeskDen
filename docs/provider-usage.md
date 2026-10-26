# Provider usage and network monitoring

The **用量统计** navigation entry combines existing AI quotas and local Token activity with independent service quota sources. Each IPRoyal order and Bandwagon VPS keeps its own identity, balance, last successful observation and reset rule. The **网络监控** module remains separate and keeps its existing single local traffic budget.

Service balances come from the provider. Local received/sent bytes are only an activity signal that decides when to query again; they are never subtracted from a provider balance or attributed to a particular subscription. Unknown values remain unknown. A failed query retains the last successful reading and its timestamp.

## Bandwagon VPS

Add a source with a display name, VEID and API Key. A successful read is required before replacing the saved configuration or credential. The key is kept in the macOS Keychain; the JSON configuration only holds an opaque credential reference. Leaving the key blank while editing preserves the existing key.

The client uses the fixed HTTPS `getServiceInfo` endpoint with a POST body. It reads `plan_monthly_data`, `data_counter`, `monthly_data_multiplier` and `data_next_reset`; the multiplier applies to both the allowance and counter. Values use the platform's binary GB convention. The application does not apply an additional upload/download multiplier. Reset timestamps are displayed in the selected workbench timezone, including daylight-saving changes.

An API Key may have broader management permissions at the provider; this integration only implements the read operation. It does not modify the VPS, plan or billing settings. HTTP authentication failures pause automatic querying until reconfiguration. Rate limiting and temporary failures keep the previous reading and delay retrying.

## IPRoyal static ISP

The official reseller API Token supports product and order reads, but has not authorized the dashboard's static ISP quota endpoint. Entering that Token is therefore not offered as a working static ISP quota connection.

The optional Chrome connector reuses the user's ordinary dashboard login. It observes only quota and reset fields from known order GET responses; it does not extract Google credentials, login cookies, tokens or request headers. Its source, exact permissions, installation and removal instructions are in [the connector guide](../Launcher/BrowserConnectors/IPRoyal/README.md).

Export a connection kit from the IPRoyal connection dialog, install it yourself, enable the extension and add the static ISP order number. The App and exported kit must remain at stable locations. Exporting does not install or grant permissions. Real Chrome installation, Google login, quota comparison and session persistence require manual acceptance before relying on this route. A successful synthetic test does not establish a real login's lifetime.

The provider's `bandwidth_limit_reset_at` is currently a date-only value. It is shown as the provider's date with timezone unconfirmed, without inventing midnight or converting it into a different day. Quota observations may lag actual traffic; the query timestamp is not a billing cutoff timestamp.

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
