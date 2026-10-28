import AppKit
import SwiftUI

enum WBDateInputComponents: Equatable { case date, time }

/// Editable choices use the same choices, material and 32-point surface as WBSelect.
struct WBEditableCombo: NSViewRepresentable {
    let title: String
    @Binding var selection: String
    let options: [String]
    var suffix = ""
    var accepts: (String) -> Bool = { !$0.isEmpty }
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    func makeNSView(context: Context) -> WBEditableComboSurface { WBEditableComboSurface() }
    func updateNSView(_ view: WBEditableComboSurface, context: Context) {
        view.commitValue = { value in guard accepts(value) else { return false }; selection = value; return true }
        view.configure(title: title, value: selection, options: options, suffix: suffix, enabled: enabled, palette: palette)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WBEditableComboSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: 32)
    }
}

final class WBEditableComboSurface: NSView, NSTextFieldDelegate {
    let field = WBComboTextField()
    let choices = WBComboMenuButton(frame: .zero, pullsDown: false)
    private let unit = NSTextField(labelWithString: "")
    private var acceptedValue = ""
    private var values: [String] = []
    var commitValue: (String) -> Bool = { _ in false }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        choices.target = self; choices.action = #selector(choseOption)
        choices.font = .systemFont(ofSize: 12); choices.autoenablesItems = false
        addSubview(choices)
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.focusRingType = .none; field.delegate = self
        field.target = self; field.action = #selector(typedValue)
        field.lineBreakMode = .byClipping; field.maximumNumberOfLines = 1; field.cell?.usesSingleLineMode = true
        field.openChoices = { [weak self] in self?.choices.performClick(nil) }
        choices.choiceReturnTarget = field
        addSubview(field)
        unit.font = .systemFont(ofSize: 11); unit.alignment = .right; addSubview(unit)
        setAccessibilityElement(false)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 90, height: 32) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    func configure(title: String, value: String, options: [String], suffix: String, enabled: Bool, palette: ThemePalette) {
        acceptedValue = value
        if field.currentEditor() == nil && field.stringValue != value { field.stringValue = value }
        values = options
        let titles = options.map { $0 + (suffix.isEmpty ? "" : " " + suffix) }
        if choices.itemTitles != titles { choices.removeAllItems(); choices.addItems(withTitles: titles) }
        if let index = options.firstIndex(of: value) { choices.selectItem(at: index) } else { choices.select(nil) }
        for (index, item) in choices.itemArray.enumerated() { item.state = options[index] == value ? .on : .off }
        field.isEnabled = enabled; choices.isEnabled = enabled && !options.isEmpty
        choices.workbenchTheme = palette.theme; choices.interfaceOpacity = palette.opacity; choices.interfaceLight = palette.light
        field.textColor = palette.nsText.withAlphaComponent(enabled ? 1 : 0.4)
        unit.stringValue = suffix; unit.textColor = palette.nsSecondary.withAlphaComponent(enabled ? 1 : 0.4)
        field.setAccessibilityLabel(title); field.toolTip = title + "：可输入或从下拉列表选择"
        choices.setAccessibilityLabel(title + "选项"); choices.setAccessibilityValue(value)
        needsLayout = true; choices.needsDisplay = true
    }
    override func layout() {
        super.layout(); choices.frame = bounds
        let suffixWidth: CGFloat = unit.stringValue.isEmpty ? 0 : 15
        field.frame = NSRect(x: 9, y: (bounds.height - 18) / 2, width: max(12, bounds.width - 35 - suffixWidth), height: 18)
        unit.frame = NSRect(x: max(0, bounds.width - 25 - suffixWidth), y: (bounds.height - 16) / 2, width: suffixWidth, height: 16)
    }
    @discardableResult func commitEditing() -> Bool {
        guard field.isEnabled else { field.stringValue = acceptedValue; return false }
        let proposed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = acceptedValue
        guard commitValue(proposed) else { field.stringValue = acceptedValue; return false }
        if acceptedValue == previous { acceptedValue = proposed }
        // The binding may normalize a typed value (for example 5 to 05).
        if field.currentEditor() == nil { field.stringValue = acceptedValue }
        return true
    }
    /// Resolve the field editor in the owning modal window before taking a
    /// snapshot of its draft. Invalid input keeps Save open.
    static func commitActive(in window: NSWindow?) -> Bool {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField,
              let combo = field.superview as? WBEditableComboSurface else { return true }
        field.stringValue = editor.string
        guard combo.commitEditing() else { NSSound.beep(); return false }
        return window.makeFirstResponder(nil)
    }
    @objc private func typedValue() { _ = commitEditing() }
    @objc private func choseOption() {
        guard choices.isEnabled, values.indices.contains(choices.indexOfSelectedItem) else { return }
        field.stringValue = values[choices.indexOfSelectedItem]; _ = commitEditing()
        field.currentEditor()?.string = field.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) { _ = commitEditing(); choices.fieldFocused = false }
    func controlTextDidBeginEditing(_ notification: Notification) { choices.fieldFocused = true }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) { choices.performClick(nil); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            guard textView.string != acceptedValue else { return false }
            field.stringValue = acceptedValue; textView.string = acceptedValue; return true
        }
        return false
    }
}

final class WBComboTextField: NSTextField {
    var openChoices: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 { openChoices?() } else { super.keyDown(with: event) }
    }
}

/// The editor overlays a full-width choices trigger so its list aligns to the combo.
final class WBComboMenuButton: WBPopUpButton {
    var fieldFocused = false { didSet { needsDisplay = true } }
    private var hovering = false
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hovering = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let palette = ThemePalette(theme: workbenchTheme, opacity: interfaceOpacity, light: interfaceLight)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(palette.control).setFill(); path.fill()
        let active = isEnabled && (hovering || fieldFocused || isHighlighted)
        (active ? palette.nsAccent.withAlphaComponent(0.5) : NSColor(palette.controlBorder)).setStroke()
        path.lineWidth = 1; path.stroke()
        drawSymbol("chevron.down", in: NSRect(x: bounds.width - 18, y: (bounds.height - 9) / 2, width: 9, height: 9), color: palette.nsText.withAlphaComponent(isEnabled ? 0.7 : 0.35))
    }
}

/// Three date choices and two time choices retain the supplied civil timezone.
struct WBDateInput: NSViewRepresentable {
    let title: String
    @Binding var selection: Date
    let components: WBDateInputComponents
    let calendar: Calendar
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    init(_ title: String, selection: Binding<Date>, components: WBDateInputComponents, calendar: Calendar) {
        self.title = title; self._selection = selection; self.components = components; self.calendar = calendar
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, calendar: calendar) }
    func makeNSView(context: Context) -> WBDateInputSurface { WBDateInputSurface() }
    func updateNSView(_ view: WBDateInputSurface, context: Context) {
        context.coordinator.selection = $selection; context.coordinator.calendar = calendar; context.coordinator.enabled = enabled
        view.changed = { [weak coordinator = context.coordinator] date in coordinator?.changed(date) }
        view.configure(title: title, date: selection, components: components, calendar: calendar, enabled: enabled, palette: palette)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WBDateInputSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? (components == .date ? 240 : 150), height: 32)
    }
    @MainActor final class Coordinator {
        var selection: Binding<Date>
        var calendar: Calendar
        var enabled = true
        init(selection: Binding<Date>, calendar: Calendar) { self.selection = selection; self.calendar = calendar }
        func changed(_ date: Date) { if enabled && Self.isValid(date, calendar: calendar) { selection.wrappedValue = date } }
        static func isValid(_ date: Date, calendar: Calendar) -> Bool {
            guard date.timeIntervalSince1970.isFinite else { return false }
            let values = calendar.dateComponents([.era, .year], from: date)
            return values.era == 1 && values.year.map { (1...9999).contains($0) } == true
        }
    }
}

final class WBDateInputSurface: NSView {
    private(set) var fields: [WBEditableComboSurface] = []
    private(set) var components = WBDateInputComponents.date
    private(set) var calendar = Calendar.current
    private(set) var date = Date()
    private var title = ""
    private var palette = ThemePalette()
    private var enabled = true
    var changed: (Date) -> Void = { _ in }
    private var parts: [Calendar.Component] { components == .date ? [.year, .month, .day] : [.hour, .minute] }
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 32)); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: components == .date ? 240 : 150, height: 32) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    func configure(title: String, date: Date, components: WBDateInputComponents, calendar: Calendar, enabled: Bool, palette: ThemePalette) {
        self.title = title; self.date = date; self.components = components; self.calendar = calendar; self.enabled = enabled; self.palette = palette
        if fields.count != parts.count {
            fields.forEach { $0.removeFromSuperview() }
            fields = parts.map { _ in let field = WBEditableComboSurface(); addSubview(field); return field }
        }
        for (index, part) in parts.enumerated() {
            let field = fields[index], value = calendar.component(part, from: date)
            let range: ClosedRange<Int>
            switch part {
            case .year: range = max(1, value - 100)...min(9999, value + 100)
            case .month: range = 1...12
            case .day: range = 1...(calendar.range(of: .day, in: .month, for: date)?.count ?? 31)
            case .hour: range = 0...23
            default: range = 0...59
            }
            let unit = part == .year ? "年" : part == .month ? "月" : part == .day ? "日" : part == .hour ? "时" : "分"
            let format: (Int) -> String = { part == .year ? String($0) : String(format: "%02d", $0) }
            field.configure(title: title + " · " + unit, value: format(value), options: range.map(format), suffix: unit, enabled: enabled, palette: palette)
            field.field.setAccessibilityIdentifier("workbench-" + (part == .year ? "year" : part == .month ? "month" : part == .day ? "day" : part == .hour ? "hour" : "minute") + "-input")
            field.commitValue = { [weak self] text in self?.commit(text, part: part) ?? false }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let gap: CGFloat = 6, available = max(0, bounds.width - gap * CGFloat(max(0, fields.count - 1)))
        let weights: [CGFloat] = components == .date ? [1.2, 1, 1] : [1, 1]
        let total = weights.reduce(0, +)
        var x: CGFloat = 0
        for (index, field) in fields.enumerated() {
            let width = available * weights[index] / total
            field.frame = NSRect(x: x, y: 0, width: width, height: 32); x += width + gap
        }
    }
    @discardableResult private func commit(_ text: String, part: Calendar.Component) -> Bool {
        guard enabled, !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text) else { return false }
        let limits: ClosedRange<Int> = part == .year ? 1...9999 : part == .month ? 1...12 : part == .day ? 1...31 : part == .hour ? 0...23 : 0...59
        guard limits.contains(value) else { return false }
        var civil = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        civil.setValue(value, for: part)
        if part == .month || part == .year {
            var beginning = civil; beginning.day = 1; beginning.hour = 12
            guard let first = calendar.date(from: beginning), let days = calendar.range(of: .day, in: .month, for: first) else { return false }
            civil.day = min(civil.day ?? 1, days.count)
        }
        guard let next = calendar.date(from: civil), WBDateInput.Coordinator.isValid(next, calendar: calendar) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        guard actual.year == civil.year, actual.month == civil.month, actual.day == civil.day, actual.hour == civil.hour, actual.minute == civil.minute else { return false }
        date = next; changed(next)
        configure(title: title, date: next, components: components, calendar: calendar, enabled: enabled, palette: palette)
        return true
    }
}
