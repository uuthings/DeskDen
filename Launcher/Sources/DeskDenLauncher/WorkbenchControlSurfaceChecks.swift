import AppKit
import SwiftUI
import LauncherCore

/// Isolated layout and drawing checks. No window is ordered, no global mouse
/// events are posted, and the fixture never reads or saves user preferences.
@MainActor enum WorkbenchControlSurfaceChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let previousCursor = ButtonCursorPolicy.shared.preference
        defer { ButtonCursorPolicy.shared.apply(previousCursor) }
        let state = ControlSurfaceState()
        let host = NSHostingView(rootView: ControlSurfaceFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 360)
        defer { window.contentView = nil; window.close() }
        await settle(host)
        let geometry = probes(host)
        let regular = geometry.first { $0.name == "regular" }
        let compact = geometry.first { $0.name == "compact" }
        let select = nativeSelect(host)
        check(regular != nil && compact != nil && select != nil,
              "hidden production button and select surfaces mount")
        check(regular.map { abs($0.bounds.height - 32) < 0.5 } == true
              && select.map { abs($0.bounds.height - 32) < 0.5 } == true,
              "regular buttons and dropdowns have matching 32-point geometry")
        check(compact.map { abs($0.bounds.height - 28) < 0.5 } == true,
              "explicit compact actions retain their 28-point height")

        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        for light in [true, false] {
            let popup = WBPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 32), pullsDown: false)
            popup.addItems(withTitles: ["全部分类", "订阅"])
            popup.interfaceLight = light
            popup.reduceMotion = true
            let frame = popup.frame
            let before = draw(popup)
            popup.mouseEntered(with: event)
            let hovered = draw(popup)
            popup.highlight(true)
            let pressed = draw(popup)
            let mode = light ? "light" : "dark"
            if let before, let hovered, let pressed {
                let edge = [NSPoint(x: 0, y: 15), NSPoint(x: 159, y: 15), NSPoint(x: 70, y: 0), NSPoint(x: 70, y: 31)]
                let interior = [NSPoint(x: 40, y: 5), NSPoint(x: 80, y: 5), NSPoint(x: 100, y: 25)]
                check(delta(before, hovered, at: edge) < 0.08 && delta(before, pressed, at: edge) < 0.08,
                      "\(mode) dropdown edges keep their neutral tone during hover and press")
                check(delta(before, hovered, at: interior) > 0.008
                      && delta(hovered, pressed, at: interior) > 0.004,
                      "\(mode) dropdown hover and press still provide an interior fill response")
            } else { check(false, "\(mode) dropdown renders all three states") }
            check(popup.frame == frame && popup.intrinsicContentSize.height == 32,
                  "\(mode) dropdown feedback never changes its geometry")
            popup.highlight(false)
            popup.mouseExited(with: event)
            popup.isEnabled = false
            let disabled = draw(popup), windowCount = NSApp.windows.count
            popup.mouseEntered(with: event)
            popup.highlight(true)
            popup.mouseDown(with: event)
            let disabledHovered = draw(popup)
            check(disabled != nil && disabledHovered != nil
                  && delta(disabled!, disabledHovered!, at: [NSPoint(x: 40, y: 5), NSPoint(x: 0, y: 15)]) < 0.001
                  && popup.indexOfSelectedItem == 0 && NSApp.windows.count == windowCount,
                  "\(mode) disabled dropdown ignores hover and cannot open a choice window")
        }

        for light in [true, false] {
            state.light = light
            await settle(host)
            let palette = ThemePalette(light: light)
            let mode = light ? "light" : "dark"
            let surfaces = probes(host)
            let rendered = capture(host)
            if let note = surfaces.first(where: { $0.name == "note" }), let image = rendered {
                let rect = note.convert(note.bounds, to: host)
                let point = NSPoint(x: rect.minX + 24, y: rect.maxY - 5)
                let background = color(image, point: point, size: host.bounds.size)
                check(background.map { contrast(palette.nsSecondary, $0) >= 4.5 } == true,
                      "\(mode) supporting text has readable contrast on the rendered note surface")
            } else { check(false, "supporting note surface renders for contrast measurement") }
            func sample(_ name: String, inset: CGFloat) -> NSColor? {
                guard let rendered, let probe = surfaces.first(where: { $0.name == name }) else { return nil }
                let rect = probe.convert(probe.bounds, to: host)
                return color(rendered, point: NSPoint(x: rect.minX + inset, y: rect.midY), size: host.bounds.size)
            }
            // Window bitmaps use the display profile. Compare colors drawn into
            // this same bitmap so the fixture is independent of that profile.
            func matches(_ name: String, inset: CGFloat, reference: NSColor?) -> Bool {
                guard let value = sample(name, inset: inset), let reference else { return false }
                return distance(value, reference) < 0.04
            }
            let primary = NSColor(palette.primary)
            check(matches("primary", inset: 5, reference: sample("primary-swatch", inset: 5))
                  && distance(primary, palette.nsAccent) > 0.10
                  && contrast(NSColor(palette.primaryText), primary) >= 4.5,
                  "\(mode) shared primary renders its action color and readable text pairing")
            let selection = sample("selection-swatch", inset: 5)
            let selected = ["day-selected", "day-selected-today"].allSatisfy { name in
                [0.5, 12].allSatisfy { inset in matches(name, inset: inset, reference: selection) }
            }
            check(selected && contrast(NSColor(palette.calendarSelectionText), NSColor(palette.calendarSelection)) >= 4.5,
                  "\(mode) shared date selection renders a solid fill, including when selecting today")
            check(matches("day-today", inset: 0.5, reference: sample("today-swatch", inset: 5))
                  && matches("day-today", inset: 12, reference: sample("day-ordinary", inset: 12)),
                  "\(mode) unselected today renders an outline with the ordinary date background")
            let initial = checkboxSamples(host)
            ButtonCursorPolicy.shared.apply(.arrow)
            state.revision += 1
            await settle(host)
            ButtonCursorPolicy.shared.apply(.pointingHand)
            state.revision += 1
            await settle(host)
            let refreshed = checkboxSamples(host)
            check(state.checked && !state.unchecked && state.selection == 0,
                  "theme and cursor refreshes preserve checkbox and selection values")
            check(initial.count == 2 && refreshed.count == 2
                  && distance(initial[0], initial[1]) > 0.12
                  && zip(initial, refreshed).allSatisfy { distance($0.0, $0.1) < 0.02 },
                  "\(mode) checked and unchecked surfaces stay distinct after cursor refresh")
        }
        check(!window.isVisible && !window.isKeyWindow,
              "all control rendering checks leave the fixture window hidden")
        return (count, failures)
    }

    private static func settle(_ host: NSView) async {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(12))
        }
    }
    private static func probes(_ view: NSView) -> [ControlSurfaceProbeView] {
        (view as? ControlSurfaceProbeView).map { [$0] } ?? view.subviews.flatMap(probes)
    }
    private static func nativeSelect(_ view: NSView) -> WBPopUpButton? {
        if let popup = view as? WBPopUpButton { return popup }
        return view.subviews.lazy.compactMap(nativeSelect).first
    }
    private static func draw(_ view: NSView) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The same opaque backing in every state isolates the control's own
        // border and feedback rather than sampling the desktop wallpaper.
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        view.bounds.fill()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }
    private static func color(_ image: NSBitmapImageRep, point: NSPoint, size: NSSize) -> NSColor? {
        let x = min(image.pixelsWide - 1, max(0, Int(point.x / size.width * CGFloat(image.pixelsWide))))
        let y = min(image.pixelsHigh - 1, max(0, Int(point.y / size.height * CGFloat(image.pixelsHigh))))
        return image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
    private static func delta(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep, at points: [NSPoint]) -> Double {
        points.compactMap { point -> Double? in
            guard let a = first.colorAt(x: Int(point.x), y: Int(point.y)),
                  let b = second.colorAt(x: Int(point.x), y: Int(point.y)) else { return nil }
            return distance(a, b)
        }.max() ?? .infinity
    }
    private static func distance(_ first: NSColor, _ second: NSColor) -> Double {
        guard let a = first.usingColorSpace(.sRGB), let b = second.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(Double(a.redComponent - b.redComponent)),
                   abs(Double(a.greenComponent - b.greenComponent)), abs(Double(a.blueComponent - b.blueComponent)))
    }
    private static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let value = color.usingColorSpace(.sRGB)!
            func linear(_ component: CGFloat) -> Double {
                let c = Double(component); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent) + 0.0722 * linear(value.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    private static func checkboxSamples(_ host: NSView) -> [NSColor] {
        guard let image = capture(host) else { return [] }
        return ["checked", "unchecked"].compactMap { name in
            guard let probe = probes(host).first(where: { $0.name == name }) else { return nil }
            let rect = probe.convert(probe.bounds, to: host)
            // The left half of the checkbox avoids the checkmark itself.
            return color(image, point: NSPoint(x: rect.minX + 4, y: rect.midY), size: host.bounds.size)
        }
    }
}

@MainActor private final class ControlSurfaceState: ObservableObject {
    @Published var light = true
    @Published var checked = true
    @Published var unchecked = false
    @Published var selection = 0
    @Published var revision = 0
}
private struct ControlSurfaceFixture: View {
    @ObservedObject var state: ControlSurfaceState
    var body: some View {
        let palette = ThemePalette(light: state.light)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("管理分类") {}.buttonStyle(WBButtonStyle()).background(ControlSurfaceProbe(name: "regular"))
                WBSelect("全部分类", selection: $state.selection, options: [(0, "全部分类"), (1, "订阅")]).frame(width: 164)
                Button("返回") {}.buttonStyle(WBButtonStyle(compact: true)).background(ControlSurfaceProbe(name: "compact"))
            }
            HStack {
                Button("保存") {}.buttonStyle(WBButtonStyle(primary: true)).background(ControlSurfaceProbe(name: "primary"))
                date("day-ordinary", selected: false, today: false)
                date("day-today", selected: false, today: true)
                date("day-selected", selected: true, today: false)
                date("day-selected-today", selected: true, today: true)
                swatch("primary-swatch", color: palette.primary)
                swatch("selection-swatch", color: palette.calendarSelection)
                swatch("today-swatch", color: palette.calendarToday)
            }
            WBPageNote { Text("存储按十进制显示（1 GB = 10 亿字节）。") }
                .background(ControlSurfaceProbe(name: "note"))
            Toggle("实时网络", isOn: $state.checked).toggleStyle(WBCheckboxToggleStyle())
                .background(ControlSurfaceProbe(name: "checked"))
            Toggle("运行内存", isOn: $state.unchecked).toggleStyle(WBCheckboxToggleStyle())
                .background(ControlSurfaceProbe(name: "unchecked"))
            Text("\(state.revision)").hidden().accessibilityHidden(true)
            Spacer(minLength: 0)
        }.padding(16)
            .frame(width: 440, height: 360, alignment: .topLeading)
            .background(state.light ? Color.cyan : Color.black)
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false, appearance: state.light ? .light : .dark)
    }

    private func date(_ name: String, selected: Bool, today: Bool) -> some View {
        Button {} label: { Color.clear.frame(width: 36, height: 34) }
            .buttonStyle(WorkbenchCalendarDayStyle(selected: selected, today: today))
            .background(ControlSurfaceProbe(name: name))
    }

    private func swatch(_ name: String, color: Color) -> some View {
        color.frame(width: 12, height: 12).background(ControlSurfaceProbe(name: name))
    }
}
private final class ControlSurfaceProbeView: NSView { var name = "" }
private struct ControlSurfaceProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> ControlSurfaceProbeView { let view = ControlSurfaceProbeView(); view.name = name; return view }
    func updateNSView(_ view: ControlSurfaceProbeView, context: Context) { view.name = name }
}
