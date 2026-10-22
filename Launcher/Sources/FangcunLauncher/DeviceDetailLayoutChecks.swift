import AppKit
import LauncherCore

/// Uses the existing isolated, service-disabled workbench window. These checks
/// measure mounted production card surfaces, rather than their layout constants.
/// Routing and resizing do not inject pointer events or start device sampling.
@MainActor enum DeviceDetailLayoutChecks {
    static func run(model: WorkbenchAppModel, window: NSWindow) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(message)")
        }
        @MainActor func checkLinkedArrow(_ identifier: String, in host: NSView, label: String) {
            let card = frame(identifier, in: host), action = frame(identifier + ".action", in: host)
            check(action.map { abs($0.width - 28) < 1 && abs($0.height - 30) < 1 } == true,
                  "mounted \(label) navigation Button remains accessible with its transparent 28×30 pt target")
            check(card.flatMap { surface in action.map { button in
                // 14 pt card padding + half the 22 pt title row. The target
                // extends one point beyond the glyph's aligned right edge.
                abs(surface.maxX - button.maxX - 13) < 1 && abs(surface.maxY - button.midY - 25) < 1
            } } == true, "mounted \(label) arrow target stays in the 22 pt title row without moving its right-aligned glyph or growing the header")
            print("DETAIL device-detail linked-arrow \(label) card=\(String(describing: card)) action=\(String(describing: action))")
        }
        guard let host = window.contentView, !model.device.isSampling, !model.modals.isPresented else {
            check(false, "device detail layout fixture is mounted, service-disabled and has no modal")
            return (count, failures)
        }
        let originalFrame = window.frame, originalRoute = model.route, originalDetail = model.deviceDetail
        defer {
            model.deviceDetail = originalDetail; model.navigate(originalRoute)
            window.setFrame(originalFrame, display: false)
        }
        let samples: [(size: NSSize, pageWidth: CGFloat)] = [
            (.init(width: 1120, height: 758), 864),
            (.init(width: 960, height: 720), 736),
            (.init(width: 1728, height: 993), 1360)
        ]
        for sample in samples {
            window.setContentSize(sample.size)
            let label = "\(Int(sample.size.width))×\(Int(sample.size.height))"
            for route in [DeviceCardID.cpu, .thermal, .storage] {
                model.deviceDetail = route; model.navigate(.device)
                let identifiers: [String]
                switch route {
                case .cpu: identifiers = ["当前使用率", "用户进程", "系统"].map { "fc.device.detail.card." + $0 }
                case .thermal: identifiers = ["CPU 温度", "GPU 温度", "温度提醒"].map { "fc.device.detail.card." + $0 }
                default: identifiers = ["fc.device.detail.card.storage-usage", "fc.device.detail.card.卷信息"]
                }
                _ = await wait(window) {
                    let cards = identifiers.compactMap { frame($0, in: host) }
                    return cards.count == identifiers.count && abs(cards.reduce(0) { $0 + $1.width } + CGFloat(cards.count - 1) * 12 - sample.pageWidth) < 2
                }
                let cards = identifiers.compactMap { frame($0, in: host) }
                let expectedWidth = (sample.pageWidth - CGFloat(identifiers.count - 1) * 12) / CGFloat(identifiers.count)
                check(cards.count == identifiers.count && cards.allSatisfy { abs($0.width - expectedWidth) < 1.5 },
                      "mounted \(route.rawValue) detail cards share the frozen equal columns in \(label)")
                let top = cards.first?.maxY, bottom = cards.first?.minY
                check(cards.count == identifiers.count && cards.allSatisfy { card in
                    top.map { abs(card.maxY - $0) < 1 } == true && bottom.map { abs(card.minY - $0) < 1 } == true
                }, "mounted \(route.rawValue) card surfaces stretch to identical top and bottom edges in \(label)")
                // This service-disabled fixture has the same one-line content
                // structure as the frozen card. Real longer values can grow;
                // the production layout uses a minimum, never a fixed height.
                let expectedHeight: CGFloat = route == .storage ? 218.0625 : 128.25
                check(cards.count == identifiers.count && cards.allSatisfy { abs($0.height - expectedHeight) < 1 },
                      "mounted \(route.rawValue) one-line card surfaces retain the frozen \(expectedHeight) pt absolute height in \(label)")
                print("DETAIL device-detail \(route.rawValue) \(label) surfaces=\(cards)")
                if route == .cpu {
                    let lowerIdentifiers = ["fc.device.detail.card.cpu-processor", "fc.device.detail.card.cpu-processes"]
                    let lower = lowerIdentifiers.compactMap { frame($0, in: host) }
                    check(lower.count == 2 && lower.allSatisfy { abs($0.width - (sample.pageWidth - 12) / 2) < 1.5 } &&
                          abs(lower[0].minY - lower[1].minY) < 1 && abs(lower[0].maxY - lower[1].maxY) < 1,
                          "mounted CPU lower cards share equal columns and matching top and bottom edges in \(label)")
                    // The short-metadata fixture uses three native 16 pt facts,
                    // two 12 pt gaps, a 22+10 pt title and 28 pt card padding.
                    // Real longer metadata remains free to grow. This fixture
                    // does not populate process rows, so their 23 pt cadence
                    // still requires the actual sampled screenshot review.
                    check(lower.count == 2 && lower.allSatisfy { abs($0.height - 132) < 1 },
                          "mounted CPU lower cards retain the native 132 pt short-content structure in \(label)")
                    print("DETAIL device-detail cpu-lower \(label) surfaces=\(lower)")
                    checkLinkedArrow("fc.device.detail.card.cpu-processes", in: host, label: "CPU related processes \(label)")
                }
                if route == .thermal {
                    check(frame("device-battery-cycle-count", in: host) != nil,
                          "mounted thermal detail retains the real or explicitly unavailable battery cycle field in \(label)")
                }
            }
            for route in [DeviceCardID.profile, .storage] {
                model.deviceDetail = route; model.navigate(.device)
                let identifier = "device-detail-\(route.rawValue)-notice"
                _ = await wait(window) { frame(identifier, in: host).map { abs($0.width - sample.pageWidth) < 1.5 } == true }
                let notice = frame(identifier, in: host)
                // The frozen notice includes 10 pt vertical padding around its
                // single line, plus a 14 pt icon. Longer real text may wrap.
                check(notice.map { abs($0.width - sample.pageWidth) < 1.5 && $0.height >= 35 && $0.height < 100 } == true,
                      "mounted \(route.rawValue) notice occupies the full page in a padded surface in \(label)")
                print("DETAIL device-detail \(route.rawValue) \(label) notice=\(String(describing: notice))")
            }
            model.deviceDetail = .memory; model.navigate(.device)
            _ = await wait(window) { frame("device-detail-open-health", in: host) != nil && frame("fc.page.device.memory", in: host) != nil }
            check(frame("device-detail-open-health", in: host).map { abs($0.height - 32) < 1 } == true,
                  "mounted memory detail exposes its 32 pt health-center action in \(label)")
            model.deviceDetail = .network; model.navigate(.device)
            _ = await wait(window) { frame("device-network-interface-picker", in: host) != nil }
            let picker = frame("device-network-interface-picker", in: host)
            check(picker.map { abs($0.height - 32) < 1 && abs($0.width - 174) < 1.5 } == true,
                  "mounted speed interface summary stays one 32 pt control instead of expanding for multiple interface names in \(label)")
            print("DETAIL device-detail network \(label) interfacePicker=\(String(describing: picker))")
            checkLinkedArrow("fc.device.detail.card.network-traffic", in: host, label: "network traffic \(label)")
        }
        print("Device detail layout checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }

    private static func wait(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() {
                try? await Task.sleep(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                return condition()
            }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return condition()
    }
    private static func frame(_ identifier: String, in root: NSView) -> NSRect? {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>(), result: [NSRect] = []
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier,
               object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let value = object.value(forKey: "accessibilityFrame") as? NSValue {
                let rect = value.rectValue
                if rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite { result.append(rect) }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result.max { $0.width * $0.height < $1.width * $1.height }
    }
}
