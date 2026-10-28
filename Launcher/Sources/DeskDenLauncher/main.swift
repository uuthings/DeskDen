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
if !CommandLine.arguments.contains("--home-feedback-check"), !CommandLine.arguments.contains("--top-entry-check"), !CommandLine.arguments.contains("--usage-ui-check"), !CommandLine.arguments.contains("--mini-data-check"), !CommandLine.arguments.contains("--mini-appearance-check"), !CommandLine.arguments.contains("--context-model-check"), !CommandLine.arguments.contains("--appearance-check"), !CommandLine.arguments.contains("--shortcut-responder-check"), !CommandLine.arguments.contains("--pointer-check"), !CommandLine.arguments.contains("--space-cleaning-system-trash-check"), !CommandLine.arguments.contains("--space-cleaning-model-check"), !CommandLine.arguments.contains("--space-cleaning-check"), !CommandLine.arguments.contains("--self-check"), !CommandLine.arguments.contains("--device-check"), !CommandLine.arguments.contains("--form-check"), !CommandLine.arguments.contains("--vault-signing-check"), let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier:identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(CommandLine.arguments.contains("--launcher") ? "local.deskden.launcher.show":"local.deskden.workbench.show"),object:nil,userInfo:nil,deliverImmediately:true)
    exit(0)
}
if CommandLine.arguments.contains("--home-feedback-check") {
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
} else if CommandLine.arguments.contains("--space-cleaning-model-check") {
    application.setActivationPolicy(.prohibited)
    Task {
        let result = await SpaceCleaningModelChecks.run()
        print("Space cleaning model checks: \(result.count) checks, \(result.failures) failures")
        exit(result.count > 0 && result.failures == 0 ? 0 : 1)
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
