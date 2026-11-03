import AppKit

if ProviderUsageBrowserHost.runIfRequested(arguments:CommandLine.arguments) {exit(0)}
if ClaudeQuotaStatusLineHost.runIfRequested(arguments:CommandLine.arguments) {exit(0)}

let application = NSApplication.shared
@MainActor func prepareNativeCheckWindows() async {
    // Mounted AppKit/SwiftUI checks create windows; .prohibited forbids them.
    if application.activationPolicy() != .accessory { _ = application.setActivationPolicy(.accessory) }
    guard application.activationPolicy() == .accessory else {
        FileHandle.standardError.write(Data("Unable to prepare the native UI check host\n".utf8)); exit(2)
    }
    guard await NativeUIFixtureAccessibility.prepareOwnProcessBridge() else {
        FileHandle.standardError.write(Data("Unable to query the native UI check process accessibility bridge\n".utf8)); exit(2)
    }
}
if !CommandLine.arguments.contains("--process-presentation-check"), !CommandLine.arguments.contains("--module-navigation-check"), !CommandLine.arguments.contains("--window-menu-check"), !CommandLine.arguments.contains("--update-interface-check"), !CommandLine.arguments.contains("--update-calendar-check"), !CommandLine.arguments.contains("--calendar-deadline-editor-check"), !CommandLine.arguments.contains("--calendar-layout-check"), !CommandLine.arguments.contains("--home-resize-check"), !CommandLine.arguments.contains("--home-fluid-check"), !CommandLine.arguments.contains("--home-feedback-check"), !CommandLine.arguments.contains("--top-entry-check"), !CommandLine.arguments.contains("--usage-ui-check"), !CommandLine.arguments.contains("--mini-data-check"), !CommandLine.arguments.contains("--mini-appearance-check"), !CommandLine.arguments.contains("--mini-drag-check"), !CommandLine.arguments.contains("--mini-activation-check"), !CommandLine.arguments.contains("--interaction-feedback-check"), !CommandLine.arguments.contains("--context-model-check"), !CommandLine.arguments.contains("--appearance-check"), !CommandLine.arguments.contains("--shortcut-responder-check"), !CommandLine.arguments.contains("--pointer-check"), !CommandLine.arguments.contains("--space-cleaning-system-trash-check"), !CommandLine.arguments.contains("--space-cleaning-model-check"), !CommandLine.arguments.contains("--space-cleaning-workspace-check"), !CommandLine.arguments.contains("--space-cleaning-check"), !CommandLine.arguments.contains("--self-check"), !CommandLine.arguments.contains("--device-check"), !CommandLine.arguments.contains("--form-check"), !CommandLine.arguments.contains("--vault-signing-check"), let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier:identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(CommandLine.arguments.contains("--launcher") ? "local.deskden.launcher.show":"local.deskden.workbench.show"),object:nil,userInfo:nil,deliverImmediately:true)
    exit(0)
}
if CommandLine.arguments.contains("--window-menu-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await WorkbenchWindowMenuChecks.run()
        print("Window and menu checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--update-calendar-check") || CommandLine.arguments.contains("--update-interface-check") {
    Task {
        await prepareNativeCheckWindows()
        let interfaceOnly = CommandLine.arguments.contains("--update-interface-check")
        let updates = interfaceOnly ? (count: 0, failures: 0) : await AppUpdateChecks.run()
        let presentation = await WorkbenchUpdatePresentationChecks.run()
        let calendar = interfaceOnly ? (count: 0, failures: 0) : await CalendarLayoutNativeChecks.run()
        let launcher = await LauncherPresentationNativeChecks.run()
        let count = updates.count + presentation.count + calendar.count + launcher.count
        let failures = updates.failures + presentation.failures + calendar.failures + launcher.failures
        print("\(interfaceOnly ? "Update interface" : "Update and calendar") checks: \(count) checks, \(failures) failures")
        exit(count > 0 && failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--calendar-deadline-editor-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await CalendarDeadlineEditorChecks.run()
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--calendar-layout-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await CalendarLayoutNativeChecks.run()
        print("Calendar layout checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--mini-activation-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await WorkbenchTopEntryChecks.runMiniActivation()
        print("Mini activation checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--process-presentation-check") {
    // Pure presentation/model checks: no window or real process operations.
    Task {
        let result = await DeviceProcessPresentationChecks.run()
        print("Process presentation checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--module-navigation-check") {
    // Pure routing/model checks: do not activate a window or the AX bridge.
    let result = WorkbenchModuleNavigationChecks.run()
    print("Module navigation checks: \(result.count) checks, \(result.failures) failures")
    exit(result.count > 0 && result.failures == 0 ? 0 : 1)
} else if CommandLine.arguments.contains("--interaction-feedback-check") {
    Task {
        await prepareNativeCheckWindows()
        let cards = await DeviceCardActionInteractionChecks.run()
        let pointer = await WorkbenchNativeControlHitChecks.pointerInteractionChecks()
        let chart = WorkbenchChartPerformanceChecks.run()
        let count = cards.count + pointer.count + chart.count
        let failures = cards.failures + pointer.filter { !$0.0 }.count + chart.failures
        for value in pointer { print("\(value.0 ? "PASS" : "FAIL") \(value.1)") }
        print("Interaction feedback checks: \(count) checks, \(failures) failures")
        exit(count > 0 && failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--home-fluid-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await WorkbenchResponsiveLayoutChecks.runHomeResizeFixture(fluidHome: true)
        print("Fluid home checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--home-resize-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await WorkbenchResponsiveLayoutChecks.runHomeResizeFixture()
        print("Home resize checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--home-feedback-check") {
    application.setActivationPolicy(.accessory)
    Task {
        guard await NativeUIFixtureAccessibility.prepareOwnProcessBridge() else { exit(2) }
        let usage = await UsageStatisticsChecks.run()
        let dates = await WorkbenchDateInputChecks.run()
        let context = await WorkbenchContextChecks.run()
        let drafts = await WorkbenchContextDraftChecks.run()
        let calendar = await CalendarMigrationChecks.run()
        let count = usage.count + dates.count + context.count + drafts.count + calendar.count
        let failures = usage.failures + dates.failures + context.failures + drafts.failures + calendar.failures
        print("Home feedback checks: \(count) checks, \(failures) failures")
        exit(count > 0 && failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--top-entry-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await WorkbenchTopEntryChecks.run()
        print("Top entry lifecycle checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--usage-ui-check") {
    application.setActivationPolicy(.accessory)
    Task {
        guard await NativeUIFixtureAccessibility.prepareOwnProcessBridge() else { exit(2) }
        let result = await UsageStatisticsChecks.run()
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--mini-data-check") {
    application.setActivationPolicy(.prohibited)
    Task {
        let result = await WorkbenchMiniDataChecks.run()
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--mini-drag-check") {
    application.setActivationPolicy(.accessory)
    Task {
        await prepareNativeCheckWindows()
        await WorkbenchMiniAppearanceChecks.runPointerDrag()
    }
    application.run()
} else if CommandLine.arguments.contains("--mini-appearance-check") {
    application.setActivationPolicy(.accessory)
    Task {
        let result = await WorkbenchMiniAppearanceChecks.run()
        print("Mini appearance checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--context-model-check") {
    application.setActivationPolicy(.prohibited)
    Task {
        let result = await WorkbenchContextChecks.run()
        print("Context model checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--appearance-check") {
    application.setActivationPolicy(.accessory)
    Task { exit(await WorkbenchAppearanceChecks.run() == 0 ? 0 : 1) }
    application.run()
} else if CommandLine.arguments.contains("--vault-signing-check") {
    application.setActivationPolicy(.prohibited)
    Task { exit(await VaultSigningChecks.run()) }
    application.run()
} else if CommandLine.arguments.contains("--space-cleaning-system-trash-check") {
    Task {
        let result = await SpaceCleaningModelChecks.runSystemTrash()
        print("System Trash fixture checks: \(result.count) checks, \(result.failures) failures")
        exit(result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--space-cleaning-workspace-check") {
    Task {
        await prepareNativeCheckWindows()
        let result = await SpaceCleaningWorkspaceChecks.run()
        print("Space cleaning workspace checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--space-cleaning-model-check") {
    application.setActivationPolicy(.prohibited)
    Task {
        let result = await SpaceCleaningModelChecks.run()
        let search = SpaceCleaningHistorySearchChecks.run()
        let queries = await SpaceCleaningHistorySearchChecks.runAsync()
        print("Space cleaning model checks: \(result.count + search.count + queries.count) checks, \(result.failures + search.failures + queries.failures) failures")
        exit(result.count > 0 && result.failures + search.failures + queries.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--space-cleaning-check") {
    Task {
        await prepareNativeCheckWindows()
        let model = await SpaceCleaningModelChecks.run()
        let native = await SpaceCleaningNativeChecks.run()
        print("Space cleaning checks: \(model.count + native.count) checks, \(model.failures + native.failures) failures")
        exit(model.failures + native.failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--shortcut-responder-check") {
    Task {
        await prepareNativeCheckWindows()
        var pointerFailures = 0
        if CommandLine.arguments.contains("--pointer-check") {
            let checks = await WorkbenchNativeControlHitChecks.pointerInteractionChecks()
            for check in checks { print("\(check.0 ? "PASS" : "FAIL") \(check.1)") }
            let device = await DeviceCardActionInteractionChecks.run()
            pointerFailures = checks.filter { !$0.0 }.count + device.failures
            print("Pointer checks: \(checks.count + device.count) checks, \(pointerFailures) failures")
        }
        let result = await WorkbenchShortcutResponderChecks.run()
        print("Shortcut responder checks: \(result.count) checks, \(result.failures) failures")
        exit(result.failures + pointerFailures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--pointer-check") {
    Task {
        await prepareNativeCheckWindows()
        let checks = await WorkbenchNativeControlHitChecks.pointerInteractionChecks()
        for check in checks { print("\(check.0 ? "PASS" : "FAIL") \(check.1)") }
        let device = await DeviceCardActionInteractionChecks.run()
        let failures = checks.filter { !$0.0 }.count + device.failures
        print("Pointer checks: \(checks.count + device.count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    application.run()
} else if CommandLine.arguments.contains("--form-check") {
    Task { await prepareNativeCheckWindows(); let failures = await DeviceMonitoringFormChecks.run(); exit(failures == 0 ? 0 : 1) }
    application.run()
} else if CommandLine.arguments.contains("--device-check") {
    Task { await prepareNativeCheckWindows(); let failures = await DeviceModuleChecks.run(); exit(failures == 0 ? 0 : 1) }
    application.run()
} else if CommandLine.arguments.contains("--self-check") {
    Task { await prepareNativeCheckWindows(); let failures = await NativeChecks.run(); exit(failures == 0 ? 0 : 1) }
    application.run()
} else {
    _ = ApplicationIconController.shared.applyCurrentIcon()
    let controller = LauncherController()
    application.delegate = controller
    application.run()
}
