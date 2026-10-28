# API balances

API balances are separate from subscription quotas, local Token records, and network traffic. The initial adapter uses DeepSeek's documented read endpoint, [`GET /user/balance`](https://api-docs.deepseek.com/api/get-user-balance/).

The balance response supplies a currency, total balance, granted balance, and topped-up balance. The app retains the provider's exact decimal strings and currency; it does not combine different currencies or translate a balance into a quota percentage. `is_available` describes whether the account can make API calls. A successful response with an insufficient balance remains a valid balance reading.

Creating a connection or changing its API Key explicitly verifies the key before saving the connection. Keys are stored in the local, non-synchronizing Keychain under a dedicated service; the metadata file contains only an opaque credential reference. Renaming a saved connection with an empty key field retains its existing key. No model-generation, top-up, or other account-changing API is called.

Manual refresh queries the saved connection. While the app runs, previously verified connections can refresh every 30 minutes; startup waits for the scheduled check rather than immediately querying. A missing credential cannot trigger a request. Authentication errors pause automatic refresh until a replacement key is verified. Provider rate limits defer repeated queries, and failed refreshes retain the last valid balance with its original timestamp.

Connection metadata and cached balances are stored independently in `Workbench/APIBalance/api-balances.json`, using an atomic private file. Invalid or redirected storage is retained and blocks further writes and background queries. Removing a connection requires the interface's confirmation and removes its metadata and dedicated credential. Balance responses do not provide Token activity, so this adapter does not invent a DeepSeek source in local Token history.

Run `Launcher/scripts/check-api-balance.sh` for deterministic client/amount/storage/lifecycle checks. These checks inject a fake credential store and provider response; they do not read a real API Key or query an account.
