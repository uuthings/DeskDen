import AppKit
import SwiftUI
import LauncherCore

/// Native date controls are mounted offscreen. Only synthetic reminder drafts
/// are edited; no calendar provider, notifications, sensor or user file is used.
@MainActor enum WorkbenchDateInputChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) { count += 1; if !condition { failures += 1 }; print("\(condition ? "PASS" : "FAIL") \(name)") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let due = ReminderDue(year: 2026, month: 11, day: 1, hour: 9, minute: 30, timeZoneIdentifier: calendar.timeZone.identifier)
        let item = ReminderItem(id: "date-input-fixture", title: "合成提醒", due: due)
        let box = DateInputCheckState(draft: .init(item: item, creating: false, defaultDate: due.date!, calendar: calendar))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 434, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DateInputCheckView(state: box))
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 434, height: 32)
        defer { window.contentView = nil; window.close() }
        _ = await wait(host) { surfaces(host).count == 2 }
        let views = surfaces(host)
        guard let date = views.first(where: { $0.picker.datePickerElements == .yearMonthDay }),
              let time = views.first(where: { $0.picker.datePickerElements == .hourMinute }) else {
            check(false, "native shared date and time inputs mount their real NSDatePicker controls"); return (count, failures)
        }
        check(views.count == 2, "native shared inputs retain separate editable date and time controls")
        check(views.allSatisfy { abs($0.frame.height - 32) < 0.1 && $0.intrinsicContentSize.height == 32 },
              "both native input surfaces occupy the full shared 32-point height")
        check(abs(date.frame.width - 211) < 1 && abs(time.frame.width - 211) < 1,
              "date and time fill equal available columns with a twelve-point gap")
        check(views.allSatisfy { !$0.picker.isBordered && !$0.picker.isBezeled && !$0.picker.drawsBackground },
              "native small rectangular bezels and backgrounds are removed behind the shared surface")
        check(views.allSatisfy { $0.picker.datePickerStyle == .textField && $0.picker.font?.pointSize == 12 && $0.picker.acceptsFirstResponder },
              "segmented NSDatePicker editing retains keyboard focus and the shared twelve-point font")
        check(views.allSatisfy { $0.picker.timeZone?.identifier == calendar.timeZone.identifier && $0.picker.calendar?.timeZone.identifier == calendar.timeZone.identifier },
              "both real native controls use the reminder's original IANA time zone")
        check((try? box.draft.value().due) == due,
              "mounting native date controls preserves the exact original civil reminder due value")
        let editedDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        date.picker.dateValue = editedDate
        let dateAction = date.picker.sendAction(date.picker.action, to: date.picker.target)
        let editedTime = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 18, minute: 45))!
        time.picker.dateValue = editedTime
        let timeAction = time.picker.sendAction(time.picker.action, to: time.picker.target)
        check(dateAction && timeAction && box.draft.date == editedDate && box.draft.time == editedTime,
              "real native control actions update separate SwiftUI draft bindings")
        let editedDue = try? box.draft.value().due
        check(editedDue == ReminderDue(year: 2026, month: 11, day: 2, hour: 18, minute: 45, timeZoneIdentifier: "America/New_York"),
              "date and time edits combine into the requested civil due date without timezone conversion")
        box.displayZone = TimeZone(identifier: "Asia/Tokyo")!
        await settle(host)
        check(views.allSatisfy { $0.picker.timeZone?.identifier == "America/New_York" } && (try? box.draft.value().due) == editedDue,
              "changing surrounding display timezone cannot rewrite control timezone or reminder due")
        var dayOnly = box.draft; dayOnly.hasTime = false
        check((try? dayOnly.value().due?.hasTime) == false && (try? dayOnly.value().due?.hour) == nil,
              "a day-only reminder remains untimed instead of receiving a fabricated midnight")
        var absent = box.draft; absent.hasDate = false
        check((try? absent.value().due) == nil,
              "retained input values do not fabricate a due date when the reminder has no date")
        var gap = box.draft
        gap.date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        gap.time = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30))!
        var rejectedGap = false
        do { _ = try gap.value() } catch { rejectedGap = true }
        check(rejectedGap, "combined nonexistent daylight-saving time is still rejected by the original reminder validator")
        let beforeDate = box.draft.date, beforeTime = box.draft.time
        box.enabled = false
        let disabled = await wait(host) { views.allSatisfy { !$0.picker.isEnabled } }
        date.picker.dateValue = editedDate.addingTimeInterval(86_400)
        _ = date.picker.sendAction(date.picker.action, to: date.picker.target)
        check(disabled && box.draft.date == beforeDate && box.draft.time == beforeTime,
              "disabled date inputs reject a synthetic action rather than mutating a read-only draft")
        check(!WBDateInput.Coordinator.isValid(Date(timeIntervalSince1970: .nan), calendar: calendar),
              "invalid date values cannot become an epoch-zero or current-time fallback")
        let outsideRange = calendar.date(from: DateComponents(year: 10_000, month: 1, day: 1, hour: 12))!
        check(!WBDateInput.Coordinator.isValid(outsideRange, calendar: calendar),
              "native binding validation respects the reminder's supported civil year range")
        return (count, failures)
    }
    private static func surfaces(_ view: NSView) -> [WBDateInputSurface] {
        (view as? WBDateInputSurface).map { [$0] } ?? view.subviews.flatMap(surfaces)
    }
    private static func wait(_ host: NSView, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat { host.layoutSubtreeIfNeeded(); if condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) } while ContinuousClock.now < deadline
        return condition()
    }
    private static func settle(_ host: NSView) async { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(2)) } }
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
            WBDateInput("提醒日期", selection: $state.draft.date, components: .date, calendar: state.draft.calendar).frame(maxWidth: .infinity).frame(height: 32)
            WBDateInput("提醒时间", selection: $state.draft.time, components: .time, calendar: state.draft.calendar).frame(maxWidth: .infinity).frame(height: 32)
        }.frame(width: 434, height: 32).environment(\.timeZone, state.displayZone).environment(\.locale, Locale(identifier: "en_US_POSIX")).disabled(!state.enabled)
    }
}
