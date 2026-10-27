# Modular Mini dashboard

The top-edge panel shares the workbench material, theme, light/dark appearance and interface opacity. The top shoulders attach to the screen edge, and the header avoids the actual camera notch. Date/time and weather are independently visible; long header content is reduced within the available safe space rather than crossing the notch.

Click either the date/time or weather header to open the homepage's city, weather and time dialog in the existing main window, including before a city is selected. Existing dialogs and unsaved configuration keep their navigation protection. Header text uses a consistent **12 pt** size, including time and temperature values.

**Show seconds** is available in the Mini's display settings and the main window's top-entry settings. It defaults to off and saves independently of header visibility. The visible clock updates each second when enabled, otherwise on minute boundaries, using the homepage's timezone and 12/24-hour preference. It does not change reminder times or increase weather/provider polling.

Cards retain a fixed width of **220 pt**. Small cards are **72 pt** high and medium cards are **113 pt** high, separated by **10 pt**. A column holds at most three small cards or two medium cards. The default eight cards occupy three columns: **748 × 292 pt** on the common 32 pt top-safe-area geometry. The maximum panel width is **978 pt** (four columns); extra cards paginate. Unusual safe areas can increase the height to protect the header. Available screen width can reduce the number of visible columns, with pagination preserving access to every enabled card.

Default content:

- Codex quota, Claude quota and the local network budget.
- Disk usage, memory usage and one upcoming reminder.
- Realtime upload/download with a bounded graph, and CPU/GPU temperatures plus both fans.

Missing hardware, weather or account readings show an unavailable state instead of sample values. Provider quotas include observation/reset information. Additional configured service sources can be enabled individually in the panel. Their IDs survive renaming and reordering.

Clicking a card opens its corresponding workbench page or source. There is no duplicate workbench button or hover-only detail arrow. Enter layout editing to drag cards or use the ordering controls; normal mode never interprets a click as a reorder. Display settings control individual cards and the two header groups, and can restore defaults. Disabling every card leaves the configuration entry reachable.

The saved layout is independent of temporary screen-width pagination. Previous explicit direct-workbench and disabled top-entry choices remain valid after preference migration. The Mini reuses existing collectors and snapshots; opening it does not start another provider quota poller. Weather, calendar and hardware visibility follow the shared lifecycle, and hidden content releases its host after the close animation.

These point measurements describe the native layout, not an HTML screenshot's pixel scaling. Test fixtures render real views offscreen with synthetic data; actual pointer dragging across monitors and long-running sensor/account behavior remain separate acceptance activities.
