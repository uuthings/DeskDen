import SwiftUI

/// Date tiles share the home calendar's treatment (现行规范 9.1, 9.3 K2): the
/// selected day is a filled tile (white with accent text in dark), today is
/// outlined, and hover only tints.
struct WorkbenchCalendarDayStyle: ButtonStyle {
    var selected: Bool
    var today: Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    static func textColor(selected: Bool, today: Bool, palette: ThemePalette) -> Color {
        selected ? (palette.light ? .white : ThemePalette(light: true).accent) : today ? palette.accent : palette.secondary
    }
    func makeBody(configuration: Configuration) -> some View {
        let fill = palette.light ? palette.accent : Color.white.opacity(0.94)
        let pressed = enabled && configuration.isPressed
        return configuration.label
            .background(selected ? fill.opacity(pressed ? 0.85 : 1) : palette.accent.opacity(pressed ? 0.14 : enabled && hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            // The filled selection still answers hover, like a primary button (4.3).
            .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(selected && enabled && hovering && !pressed ? 0.06 : 0)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.accent.opacity(today && !selected ? 1 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = enabled && $0 }
            .clickableCursor()
    }
}

enum WorkbenchCalendarDayMetrics {
    static let aspectRatio: CGFloat = 1.4
    static let minimumHeight: CGFloat = 54
    static let maximumHomeWidth: CGFloat = 974
    static func height(forWidth width: CGFloat) -> CGFloat { max(minimumHeight, width / aspectRatio) }
}

struct WorkbenchCalendarDayButton: View {
    let date: Date
    let calendar: Calendar
    let selected: Bool
    var outside = false
    var showsHolidays = true
    var eventMarkers: [Bool] = []
    let label: String
    let identifier: String
    let action: () -> Void
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        let today = calendar.isDate(date, inSameDayAs: Date())
        let info = CalendarCivilDay(date: date, calendar: calendar, showsHolidays: showsHolidays)
        let selectedText = WorkbenchCalendarDayStyle.textColor(selected: true, today: today, palette: palette)
        Button(action: action) {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(selected ? selectedText : today ? palette.accent : palette.text).frame(height: 17)
                Text(info.label).font(.system(size: 11)).foregroundStyle(selected ? selectedText.opacity(0.85) : info.color(palette))
                    .lineLimit(1).frame(height: 14)
                HStack(spacing: 3) {
                    ForEach(Array(eventMarkers.prefix(3).enumerated()), id: \.offset) { _, systemEvent in
                        Circle().fill(selected ? selectedText : systemEvent ? palette.cool : palette.accent).frame(width: 4, height: 4)
                    }
                }.frame(height: 4).padding(.top, 2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 3).padding(.horizontal, 2)
                .overlay(alignment: .topTrailing) { CalendarHolidayBadge(day: info).padding(3) }
        }.buttonStyle(WorkbenchCalendarDayStyle(selected: selected, today: today)).disabled(outside)
            .accessibilityLabel(label)
            .accessibilityValue(selected ? "已选择" : today ? "今天" : outside ? "不在当前月份" : "未选择")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier(identifier)
    }
}
