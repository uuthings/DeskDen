import Foundation
import Sparkle

struct ProbeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class Probe: NSObject, SPUUpdaterDelegate {
    var newestSignedBuild: String?
    var offeredSignedBuild: String?
    var finished = false
    var updateError: NSError?

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        if let newest = appcast.items.first, newest.signingValidationStatus == .succeeded {
            newestSignedBuild = newest.versionString
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if item.signingValidationStatus == .succeeded { offeredSignedBuild = item.versionString }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        updateError = error as NSError?
        finished = true
    }
}

@MainActor func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, let expected = Int(arguments[2]), expected > 0 else {
        throw ProbeError("Usage: probe-stable-update <DeskDen.app> <published build number>")
    }
    let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
    guard var info = Bundle(url: source)?.infoDictionary,
          info["CFBundleIdentifier"] as? String == "local.deskden.launcher",
          let version = info["CFBundleShortVersionString"] as? String,
          let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString),
          build > 0, build <= expected, info["SURequireSignedFeed"] as? Bool == true,
          info["SUPublicEDKey"] is String, info["SUFeedURL"] is String else {
        throw ProbeError("Expected a DeskDen release with a signed feed and a build at or below the published build.")
    }

    // Sparkle reloads a host's Info.plist from disk. Give it a metadata-only host
    // with its own identity and preferences, preserving the release's feed and key.
    let suite = "test.deskden.stable-probe." + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let hostURL = directory.appendingPathComponent("Probe.app")
    let contents = hostURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    info["CFBundleIdentifier"] = suite
    info["SUDefaultsDomain"] = suite
    info["SUEnableAutomaticChecks"] = false
    let metadata = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    try metadata.write(to: contents.appendingPathComponent("Info.plist"))
    guard let host = Bundle(url: hostURL), host.bundleIdentifier == suite,
          host.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String == suite else {
        throw ProbeError("Could not construct the isolated Sparkle host.")
    }

    let delegate = Probe()
    let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
    let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: delegate)
    updater.userAgentString = "DeskDen/\(version) Sparkle"
    try updater.start()
    updater.checkForUpdateInformation()
    let deadline = Date().addingTimeInterval(60)
    while !delegate.finished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard delegate.finished else { throw ProbeError("The stable feed check timed out.") }
    let error = delegate.updateError
    let expectedResult = build == expected
        ? error?.domain == SUSparkleErrorDomain && error?.code == Int(SUError.noUpdateError.rawValue) && delegate.offeredSignedBuild == nil
        : error == nil && delegate.offeredSignedBuild == String(expected)
    guard delegate.newestSignedBuild == String(expected), expectedResult else {
        throw ProbeError("Unexpected update result. Signed feed build \(delegate.newestSignedBuild ?? "none"), offered build \(delegate.offeredSignedBuild ?? "none"), error \(error?.localizedDescription ?? "none").")
    }
    print("Host build \(build), signed feed build \(expected), offered build \(delegate.offeredSignedBuild ?? "none").")
}

do {
    try MainActor.assumeIsolated { try run() }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
