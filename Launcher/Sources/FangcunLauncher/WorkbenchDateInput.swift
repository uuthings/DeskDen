import AppKit
import SwiftUI

enum WBDateInputComponents: Equatable { case date, time }

/// Native segmented editing and validation inside the same 32-point surface as
/// other workbench inputs. The supplied calendar owns the reminder's timezone.
struct WBDateInput: NSViewRepresentable {
    let title: String
    @Binding var selection: Date
    let components: WBDateInputComponents
    let calendar: Calendar
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette

    init(_ title: String, selection: Binding<Date>, components: WBDateInputComponents, calendar: Calendar) {
        self.title = title; self._selection = selection; self.components = components; self.calendar = calendar
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, calendar: calendar) }
    func makeNSView(context: Context) -> WBDateInputSurface {
        let view = WBDateInputSurface(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.picker.target = context.coordinator; view.picker.action = #selector(Coordinator.changed(_:))
        return view
    }
    func updateNSView(_ view: WBDateInputSurface, context: Context) {
        context.coordinator.selection = $selection; context.coordinator.calendar = calendar; context.coordinator.enabled = enabled
        view.configure(title: title, date: selection, components: components, calendar: calendar, locale: locale, enabled: enabled, palette: palette)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WBDateInputSurface, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? nsView.intrinsicContentSize.width), height: 32)
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Date>
        var calendar: Calendar
        var enabled = true
        init(selection: Binding<Date>, calendar: Calendar) { self.selection = selection; self.calendar = calendar }
        @objc func changed(_ sender: NSDatePicker) {
            guard enabled, sender.isEnabled else { return }
            guard Self.isValid(sender.dateValue, calendar: calendar) else { sender.dateValue = selection.wrappedValue; return }
            selection.wrappedValue = sender.dateValue
        }
        static func isValid(_ date: Date, calendar: Calendar) -> Bool {
            guard date.timeIntervalSince1970.isFinite else { return false }
            let components = calendar.dateComponents([.era, .year], from: date)
            return components.era == 1 && components.year.map { (1...9999).contains($0) } == true
        }
    }
}

final class WBDateInputSurface: NSView {
    let picker = WBDateInputPicker()
    private var palette = ThemePalette()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picker.datePickerStyle = .textField
        picker.datePickerMode = .single
        picker.isBordered = false; picker.isBezeled = false
        picker.drawsBackground = false; picker.backgroundColor = .clear
        picker.focusRingType = .none; picker.font = .systemFont(ofSize: 12)
        picker.alignment = .left
        picker.controlSize = .regular
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.focusChanged = { [weak self] in self?.needsDisplay = true }
        addSubview(picker)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: max(140, picker.intrinsicContentSize.width + 20), height: 32) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    func configure(title: String, date: Date, components: WBDateInputComponents, calendar: Calendar,
                   locale: Locale, enabled: Bool, palette: ThemePalette) {
        self.palette = palette
        if components == .date {
            if picker.datePickerElements != .yearMonthDay { picker.datePickerElements = .yearMonthDay }
        } else if picker.datePickerElements != .hourMinute { picker.datePickerElements = .hourMinute }
        if picker.calendar != calendar { picker.calendar = calendar }
        if picker.timeZone != calendar.timeZone { picker.timeZone = calendar.timeZone }
        if picker.locale != locale { picker.locale = locale }
        if picker.dateValue != date { picker.dateValue = date }
        picker.isEnabled = enabled; picker.textColor = palette.nsText.withAlphaComponent(enabled ? 1 : 0.4)
        picker.setAccessibilityLabel(title); picker.toolTip = title
        picker.setAccessibilityIdentifier(components == .date ? "workbench-date-input" : "workbench-time-input")
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let height = min(bounds.height, max(18, picker.intrinsicContentSize.height))
        picker.frame = NSRect(x: 10, y: (bounds.height - height) / 2, width: max(0, bounds.width - 20), height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(palette.soft).setFill(); path.fill()
        let focused = window?.firstResponder === picker || picker.currentEditor() != nil
        (focused ? palette.nsAccent.withAlphaComponent(0.55) : NSColor(palette.line)).setStroke()
        path.lineWidth = 1; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        if picker.isEnabled { window?.makeFirstResponder(picker) }
    }
}

final class WBDateInputPicker: NSDatePicker {
    var focusChanged: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); focusChanged?(); return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); focusChanged?(); return accepted }
}
