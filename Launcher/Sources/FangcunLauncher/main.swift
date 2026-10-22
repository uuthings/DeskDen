import AppKit

let application = NSApplication.shared
if !CommandLine.arguments.contains("--self-check"), !CommandLine.arguments.contains("--device-check"), !CommandLine.arguments.contains("--form-check"), !CommandLine.arguments.contains("--vault-signing-check"), let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier:identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(CommandLine.arguments.contains("--launcher") ? "local.fangcun.launcher.show":"local.fangcun.workbench.show"),object:nil,userInfo:nil,deliverImmediately:true)
    exit(0)
}
if CommandLine.arguments.contains("--vault-signing-check") {
    application.setActivationPolicy(.prohibited)
    Task { exit(await VaultSigningChecks.run()) }
    application.run()
} else if CommandLine.arguments.contains("--form-check") {
    application.setActivationPolicy(.prohibited)
    Task { let failures = await DeviceMonitoringFormChecks.run(); exit(failures == 0 ? 0 : 1) }
    application.run()
} else if CommandLine.arguments.contains("--device-check") {
    application.setActivationPolicy(.prohibited)
    Task { let failures = await DeviceModuleChecks.run(); exit(failures == 0 ? 0 : 1) }
    application.run()
} else if CommandLine.arguments.contains("--self-check") {
    application.setActivationPolicy(.prohibited)
    Task { let failures = await NativeChecks.run(); exit(failures == 0 ? 0 : 1) }
    application.run()
} else {
    _ = ApplicationIconController.shared.applyCurrentIcon()
    let controller = LauncherController()
    application.delegate = controller
    application.run()
}
