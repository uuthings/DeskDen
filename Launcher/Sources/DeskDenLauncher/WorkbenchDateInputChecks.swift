import AppKit
import SwiftUI
import LauncherCore

/// Mounts the production editable combos in a hidden, service-free fixture.
@MainActor enum WorkbenchDateInputChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ name: String) { count += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") \(name)") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let due = ReminderDue(year: 2026, month: 11, day: 1, hour: 9, minute: 30, timeZoneIdentifier: calendar.timeZone.identifier)
        let item = ReminderItem(id: "date-input-fixture", title: "合成提醒", due: due)
        let box = DateInputCheckState(draft: .init(item: item, creating: false, defaultDate: due.date!, calendar: calendar))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 524, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DateInputCheckView(state: box).nativeCheckAccessibility())
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 524, height: 32)
        defer { window.contentView = nil; window.close() }
        _ = await wait(host) { surfaces(host).count == 2 && surfaces(host).reduce(0, { $0 + $1.fields.count }) == 5 }
        let views = surfaces(host)
        guard let date = views.first(where: { $0.components == .date }), let time = views.first(where: { $0.components == .time }) else {
            check(false, "shared date/time groups mount real editable combos"); return (count, failures)
        }
        let fields = date.fields + time.fields
        check(date.fields.count == 3 && time.fields.count == 2 && fields.allSatisfy { $0.field.isEditable && $0.choices.numberOfItems > 0 },
              "year, month, day, hour and minute each support both typing and a real choice menu")
        check(fields.allSatisfy { abs($0.frame.height - 32) < 1 && $0.bounds.contains($0.field.frame) && $0.bounds.contains($0.choices.frame) },
              "all five controls retain the shared height and keep text and arrows inside their own surface")
        check(fields.allSatisfy { !$0.field.isBordered && !$0.field.drawsBackground && $0.field.font?.pointSize == 12 },
              "combo editors use the shared text size without a second native bezel")
        check(views.allSatisfy { $0.calendar.timeZone.identifier == calendar.timeZone.identifier } && (try? box.draft.value().due) == due,
              "mounting the combos preserves the reminder's exact civil date, time and original timezone")
        let yearField = date.fields[0]
        yearField.field.selectText(nil)
        if let editor = yearField.field.currentEditor() as? NSTextView {
            editor.string = "2029"
            check(WBEditableComboSurface.commitActive(in: window) && calendar.component(.year, from: box.draft.date) == 2029,
                  "saving while the year field is still editing commits the latest field editor text")
            yearField.field.stringValue = "2026"; _ = yearField.commitEditing(); await settle(host)
            editor.string = "2027"
            let cancelled = yearField.control(yearField.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            let forwarded = yearField.control(yearField.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            check(cancelled && !forwarded && calendar.component(.year, from: box.draft.date) == 2026,
                  "Escape first reverts pending text then hands the next Escape back to the modal")
            yearField.field.selectText(nil)
            if let index = yearField.choices.itemTitles.firstIndex(of: "2028 年") {
                yearField.choices.selectItem(at: index)
                _ = yearField.choices.sendAction(yearField.choices.action, to: yearField.choices.target)
                check(yearField.field.currentEditor()?.string == "2028" && calendar.component(.year, from: box.draft.date) == 2028,
                      "choosing a year refreshes the active text editor so typing can continue from the selected value")
                yearField.field.stringValue = "2026"; _ = yearField.commitEditing(); _ = window.makeFirstResponder(nil); await settle(host)
            } else { check(false, "the year list contains the nearby selectable year") }
        } else { check(false, "the real combo field can create its field editor without showing the fixture window") }
        date.fields[2].field.stringValue = "02"
        let dateEdit = date.fields[2].commitEditing()
        time.fields[0].choices.selectItem(at: 18)
        let hourEdit = time.fields[0].choices.sendAction(time.fields[0].choices.action, to: time.fields[0].choices.target)
        time.fields[1].field.stringValue = "45"
        let minuteEdit = time.fields[1].commitEditing()
        await settle(host)
        let editedDue = try? box.draft.value().due
        check(dateEdit && hourEdit && minuteEdit && editedDue == ReminderDue(year: 2026, month: 11, day: 2, hour: 18, minute: 45, timeZoneIdentifier: "America/New_York"),
              "typed date/minute and a menu-selected hour combine into the requested reminder without timezone conversion")
        box.displayZone = TimeZone(identifier: "Asia/Tokyo")!; await settle(host)
        check(views.allSatisfy { $0.calendar.timeZone.identifier == "America/New_York" } && (try? box.draft.value().due) == editedDue,
              "a surrounding display timezone change cannot rewrite the reminder")
        box.draft.date = calendar.date(from: DateComponents(year: 2028, month: 1, day: 31, hour: 12))!; await settle(host)
        date.fields[1].choices.selectItem(at: 1)
        _ = date.fields[1].choices.sendAction(date.fields[1].choices.action, to: date.fields[1].choices.target); await settle(host)
        check(calendar.component(.month, from: box.draft.date) == 2 && calendar.component(.day, from: box.draft.date) == 29 && date.fields[2].choices.numberOfItems == 29,
              "choosing February clamps January 31 to the real leap-month end and updates the day choices")
        date.fields[0].field.stringValue = "2027"; _ = date.fields[0].commitEditing(); await settle(host)
        check(calendar.component(.year, from: box.draft.date) == 2027 && calendar.component(.day, from: box.draft.date) == 28 && date.fields[2].choices.numberOfItems == 28,
              "typing a non-leap year clamps the existing leap day to February 28")
        let beforeInvalid = box.draft.date
        date.fields[2].field.stringValue = "31"
        check(!date.fields[2].commitEditing() && box.draft.date == beforeInvalid, "invalid typed civil dates are rejected instead of silently rolling into March")
        date.fields[0].field.stringValue = "invalid"
        check(!date.fields[0].commitEditing() && box.draft.date == beforeInvalid, "non-numeric input leaves the saved draft unchanged")
        var dayOnly = box.draft; dayOnly.hasTime = false
        check((try? dayOnly.value().due?.hasTime) == false && (try? dayOnly.value().due?.hour) == nil, "date-only reminders do not acquire an invented midnight")
        var absent = box.draft; absent.hasDate = false
        check((try? absent.value().due) == nil, "retained combo values do not invent a date when its switch is disabled")
        var gap = box.draft
        gap.date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        gap.time = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30))!
        var rejectsGap = false; do { _ = try gap.value() } catch { rejectsGap = true }
        check(rejectsGap, "the original validator still rejects a combined nonexistent daylight-saving time")
        let beforeDisabled = box.draft
        box.enabled = false
        _ = await wait(host) { fields.allSatisfy { !$0.field.isEnabled && !$0.choices.isEnabled } }
        date.fields[2].field.stringValue = "15"
        check(!date.fields[2].commitEditing() && box.draft == beforeDisabled, "disabled combos reject input and retain the complete draft")
        check(!WBDateInput.Coordinator.isValid(Date(timeIntervalSince1970: .nan), calendar: calendar), "invalid instants cannot become an epoch or current-time fallback")
        check(!WBDateInput.Coordinator.isValid(calendar.date(from: DateComponents(year: 10000, month: 1, day: 1))!, calendar: calendar), "year validation retains the supported civil range")
        check(!window.isVisible && !window.isKeyWindow, "date input verification never activates its hidden fixture window")
        print("Date input checks: \(count) checks, \(failures) failures")
        return (count, failures)
    }
    private static func surfaces(_ view: NSView) -> [WBDateInputSurface] { (view as? WBDateInputSurface).map { [$0] } ?? view.subviews.flatMap(surfaces) }
    private static func wait(_ host: NSView, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<60 { host.layoutSubtreeIfNeeded(); if condition() { return true }; try? await Task.sleep(for: .milliseconds(4)) }; return condition()
    }
    private static func settle(_ host: NSView) async { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(4)) } }
}
@MainActor private final class DateInputCheckState: ObservableObject {
    @Published var draft: CalendarReminderDraft
    @Published var displayZone = TimeZone(identifier: "UTC")!
    @Published var enabled = true
    init(draft: CalendarReminderDraft) { self.draft = draft }
}
private struct DateInputCheckView: View {
    @ObservedObject var state: DateInputCheckState
    var body: some View {
        HStack(spacing: 12) {
            WBDateInput("提醒日期", selection: $state.draft.date, components: .date, calendar: state.draft.calendar).frame(width: 310, height: 32)
            WBDateInput("提醒时间", selection: $state.draft.time, components: .time, calendar: state.draft.calendar).frame(width: 202, height: 32)
        }.frame(width: 524, height: 32).environment(\.timeZone, state.displayZone).disabled(!state.enabled)
    }
}
