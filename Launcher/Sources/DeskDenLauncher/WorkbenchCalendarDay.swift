import SwiftUI

/// Home, month and week dates use the same selection fill and today outline.
struct WorkbenchCalendarDayStyle: ButtonStyle {
    var selected: Bool
    var today: Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    static func textColor(selected: Bool, today: Bool, otherwise: Color, palette: ThemePalette) -> Color {
        selected ? palette.calendarSelectionText : today ? palette.calendarToday : otherwise
    }
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: WBControlMetrics.cornerRadius)
        let pressed = enabled && configuration.isPressed
        let hovered = enabled && hovering
        let fill = selected ? palette.calendarSelection : palette.calendarToday.opacity(pressed ? 0.14 : hovered ? 0.08 : 0)
        return configuration.label
            .background {
                shape.fill(fill).overlay {
                    if selected {
                        shape.fill(palette.calendarSelectionText.opacity(pressed ? 0.03 : hovered ? 0.015 : 0))
                    }
                }
            }
            .overlay {
                if today && !selected {
                    shape.strokeBorder(palette.calendarToday, lineWidth: 1).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
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
        let dateText = WorkbenchCalendarDayStyle.textColor(selected: selected, today: today, otherwise: palette.text, palette: palette)
        Button(action: action) {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(dateText).frame(height: 17)
                Text(info.label).font(.system(size: 11)).foregroundStyle(selected ? palette.calendarSelectionText : info.color(palette))
                    .lineLimit(1).frame(height: 14)
                HStack(spacing: 3) {
                    ForEach(Array(eventMarkers.prefix(3).enumerated()), id: \.offset) { _, systemEvent in
                        Circle().fill(selected ? palette.calendarSelectionText : systemEvent ? palette.cool : palette.accent).frame(width: 4, height: 4)
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
