import SwiftUI

/// Date tiles share their state treatment across Home, month and week views.
struct WorkbenchCalendarDayStyle: ButtonStyle {
    var selected: Bool
    var today: Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovering = enabled && $0 }
            .clickableCursor()
    }
    private func fill(pressed: Bool) -> Color {
        if enabled && pressed { return palette.accent.opacity(0.23) }
        if selected { return palette.navSelected.opacity(enabled && hovering ? 0.95 : 0.65) }
        if enabled && hovering { return palette.accent.opacity(0.10) }
        return today ? palette.accent.opacity(0.04) : .clear
    }
    private var border: Color {
        palette.accent.opacity(today ? 0.45 : selected ? 0.38 : enabled && hovering ? 0.22 : 0)
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
        Button(action: action) {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 16, weight: today ? .semibold : .regular))
                    .foregroundStyle(today ? palette.accent : palette.text).frame(height: 22)
                Text(info.label).font(.system(size: 11)).foregroundStyle(info.color(palette))
                    .lineLimit(1).frame(height: 14)
                HStack(spacing: 3) {
                    ForEach(Array(eventMarkers.prefix(3).enumerated()), id: \.offset) { _, systemEvent in
                        Circle().fill(systemEvent ? palette.cool : palette.accent).frame(width: 3, height: 3)
                    }
                }.frame(height: 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 4).padding(.horizontal, 2)
                .overlay(alignment: .topTrailing) { CalendarHolidayBadge(day: info).padding(4) }
        }.buttonStyle(WorkbenchCalendarDayStyle(selected: selected, today: today)).disabled(outside)
            .accessibilityLabel(label)
            .accessibilityValue(selected ? "已选择" : today ? "今天" : outside ? "不在当前月份" : "未选择")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier(identifier)
    }
}
