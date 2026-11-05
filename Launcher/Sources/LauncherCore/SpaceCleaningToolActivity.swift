import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Recognizes package managers and build tools that own known caches.
/// Interpreted tools are identified by the script they run, never by the
/// interpreter name alone: npm runs as `node`, Homebrew as `bash` and `ruby`,
/// pip as `Python`. Unrelated Node, Ruby, shell or Python processes do not count.
public enum SpaceCleaningToolActivity {
    /// Identities understood by the scanner's cache-owner rules.
    public static let npm = "npm"
    public static let homebrew = "brew"
    public static let pip = "pip"
    public static let yarn = "yarn"
    public static let pnpm = "pnpm"
    public static let bun = "bun"
    public static let uv = "uv"
    public static let poetry = "poetry"
    public static let gradle = "gradle"
    public static let cargo = "cargo"
    public static let go = "go"
    public static let cocoapods = "pod"
    public static let carthage = "carthage"
    public static let deno = "deno"
    public static let composer = "composer"
    public static let playwright = "playwright"
    /// Browsers that Playwright and Puppeteer download and launch from their caches.
    public static let testBrowser = "test-browser"
    /// Used when the process table cannot be read: every tool-owned cache stays protected.
    public static let unreadableProcessTable: Set<String> = [
        npm, homebrew, pip, yarn, pnpm, bun, uv, poetry, gradle, cargo, go, cocoapods, carthage, deno, composer,
        playwright, testBrowser, "xcodebuild", "swift"
    ]

    /// Native executables that are reported under their own names.
    static let nativeTools: Set<String> = [
        "xcodebuild", "swift", "swift-frontend", "swift-driver", "swift-build", "swift-package",
        "clang", "clang++", "XCBBuildService", "SWBBuildService", "swift-test", "swift-run", "sourcekit-lsp"
    ]
    /// Native executables that map to a cache owner identity.
    private static let nativeOwners: [String: String] = [
        "yarn": yarn, "pnpm": pnpm, "bun": bun, "uv": uv, "uvx": uv, "cargo": cargo, "go": go,
        "carthage": carthage, "deno": deno, "chrome-headless-shell": testBrowser,
        "google chrome for testing": testBrowser, "headless_shell": testBrowser
    ]
    private static let npmScripts: Set<String> = ["npm", "npx", "npm-cli.js", "npx-cli.js", "npm.js", "npx.js"]
    private static let yarnScripts: Set<String> = ["yarn", "yarn.js", "yarn.cjs", "yarnpkg"]
    private static let pnpmScripts: Set<String> = ["pnpm", "pnpm.cjs", "pnpm.js", "pnpx", "pnpx.cjs"]

    enum Interpreter { case env, node, shell, ruby, python, java, php }

    static func interpreter(_ name: String) -> Interpreter? {
        let name = name.lowercased()
        if name == "env" { return .env }
        if name == "node" || name == "nodejs" { return .node }
        if ["sh", "bash", "zsh", "dash", "ksh"].contains(name) { return .shell }
        if name.hasPrefix("ruby") { return .ruby }
        if name.hasPrefix("python") { return .python }
        if name == "java" { return .java }
        if name == "php" || name.hasPrefix("php8") || name.hasPrefix("php7") { return .php }
        return nil
    }

    /// `executable` is a process name or executable path; `arguments` is argv,
    /// including argv[0]. Returns the tool identities this process represents.
    public static func identities(executable: String, arguments: [String]) -> Set<String> {
        var result = Set<String>()
        let name = basename(executable)
        if nativeTools.contains(name) { result.insert(name) }
        let lower = name.lowercased()
        if lower == "npm" || lower == "npx" { result.insert(npm) }
        if lower == "brew" { result.insert(homebrew) }
        if isPipName(lower) { result.insert(pip) }
        if let owner = nativeOwners[lower] { result.insert(owner) }
        let operands = Array(arguments.dropFirst())
        // A path argument is specific enough to count anywhere in argv; a bare
        // word only counts when it is the script the interpreter was started with.
        let paths = operands.filter { $0.contains("/") }
        let script = operands.first { !$0.hasPrefix("-") }
        switch interpreter(lower) {
        case .env:
            // `/usr/bin/env [-options] [NAME=value ...] program [arguments ...]`
            if let index = operands.firstIndex(where: { !$0.hasPrefix("-") && !$0.contains("=") }) {
                result.formUnion(identities(executable: operands[index], arguments: Array(operands[index...])))
            }
        case .node:
            let candidates = paths + (script.map { [$0] } ?? [])
            if candidates.contains(where: { npmScripts.contains(basename($0).lowercased()) || $0.contains("/node_modules/npm/bin/") }) {
                result.insert(npm)
            }
            if candidates.contains(where: { yarnScripts.contains(basename($0).lowercased()) || $0.contains("/node_modules/yarn/bin/") }) {
                result.insert(yarn)
            }
            if candidates.contains(where: { pnpmScripts.contains(basename($0).lowercased()) || $0.contains("/node_modules/pnpm/bin/") }) {
                result.insert(pnpm)
            }
            if candidates.contains(where: { basename($0).lowercased() == "playwright" || $0.contains("/node_modules/playwright/") ||
                $0.contains("/node_modules/@playwright/test/") || $0.contains("/node_modules/playwright-core/") }) {
                result.insert(playwright)
            }
        case .shell:
            if paths.contains(where: { basename($0) == "brew" || $0.hasSuffix("/Library/Homebrew/brew.sh") }) { result.insert(homebrew) }
        case .ruby:
            if operands.contains(where: { $0.hasSuffix("/Homebrew/brew.rb") }) { result.insert(homebrew) }
            let candidates = paths + (script.map { [$0] } ?? [])
            if candidates.contains(where: { basename($0) == "pod" || $0.contains("/gems/cocoapods-") }) { result.insert(cocoapods) }
        case .python:
            if let index = operands.firstIndex(of: "-m"), index + 1 < operands.count {
                let module = operands[index + 1].lowercased()
                if isPipName(module) || module.hasPrefix("pip.") { result.insert(pip) }
            }
            let candidates = paths + (script.map { [$0] } ?? [])
            if candidates.contains(where: { isPipName(basename($0).lowercased()) }) { result.insert(pip) }
            if candidates.contains(where: { basename($0).lowercased() == "poetry" }) ||
                operands.firstIndex(of: "-m").map({ $0 + 1 < operands.count && operands[$0 + 1].lowercased() == "poetry" }) == true {
                result.insert(poetry)
            }
        case .java:
            // Gradle daemons, wrappers and launchers all run Gradle classes.
            if operands.contains(where: { $0.contains("org.gradle.") }) { result.insert(gradle) }
        case .php:
            let candidates = paths + (script.map { [$0] } ?? [])
            if candidates.contains(where: { ["composer", "composer.phar"].contains(basename($0).lowercased()) }) { result.insert(composer) }
        case nil:
            break
        }
        return result
    }

    /// Parses the `KERN_PROCARGS2` layout: argc, executable path, padding, argv, environment.
    /// The environment is never returned.
    public static func parseProcessArguments(_ bytes: [UInt8]) -> (executable: String, arguments: [String])? {
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4_096 else { return nil }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        guard let executable = nextString(), !executable.isEmpty else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let value = nextString() else { return nil }
            arguments.append(value)
        }
        return (executable, arguments)
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
    static func isPipName(_ name: String) -> Bool {
        name.hasPrefix("pip") && name.dropFirst(3).allSatisfy { $0.isNumber || $0 == "." }
    }

    #if canImport(Darwin)
    /// Reads the current process table. Launch arguments are read only for
    /// interpreter processes; an unreadable table counts as every tool running.
    public static func currentIdentities() -> Set<String> {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 1_000_000 else { return unreadableProcessTable }
        var identifiers = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return unreadableProcessTable }
        var result = Set<String>()
        var reader = ArgumentReader()
        for pid in identifiers.prefix(min(Int(count), identifiers.count)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 1_024)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let kind = interpreter(name) else {
                result.formUnion(identities(executable: name, arguments: [name])); continue
            }
            if let parsed = reader.arguments(of: pid) {
                result.formUnion(identities(executable: parsed.executable, arguments: parsed.arguments))
            } else if kind == .node {
                // Another user's Node process (for example `sudo npm`) can still
                // write the shared package caches; its script cannot be confirmed.
                result.formUnion([npm, yarn, pnpm, playwright])
            } else if kind == .java {
                result.insert(gradle)
            }
        }
        return result
    }

    /// Executable paths of running processes. A build output that contains a
    /// running program (a dev server, a test host) stays protected.
    public static func currentExecutablePaths() -> [String] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 1_000_000 else { return [] }
        var identifiers = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var result = Set<String>()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in identifiers.prefix(min(Int(count), identifiers.count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            result.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return result.sorted()
    }

    /// Simulator UDIDs and device names that running processes refer to (see
    /// `SpaceCleaningSimulators.references`). Only those values are kept. An
    /// unreadable process table counts as referring to every simulator.
    public static func currentSimulatorReferences() -> Set<String> {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 1_000_000 else { return [SpaceCleaningSimulators.unknownReferences] }
        var identifiers = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [SpaceCleaningSimulators.unknownReferences] }
        var result = Set<String>()
        var reader = ArgumentReader()
        for pid in identifiers.prefix(min(Int(count), identifiers.count)) where pid > 0 {
            guard let parsed = reader.arguments(of: pid) else { continue }
            result.formUnion(SpaceCleaningSimulators.references(executable: parsed.executable, arguments: parsed.arguments))
        }
        return result
    }

    private struct ArgumentReader {
        private var buffer: [UInt8] = []
        mutating func arguments(of pid: pid_t) -> (executable: String, arguments: [String])? {
            if buffer.isEmpty {
                var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
                var maximum: Int32 = 0
                var size = MemoryLayout<Int32>.size
                guard sysctl(&mib, 2, &maximum, &size, nil, 0) == 0, maximum > 0, maximum <= 16 << 20 else { return nil }
                buffer = [UInt8](repeating: 0, count: Int(maximum))
            }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count
            let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
            guard status == 0, size > 0, size <= buffer.count else { return nil }
            return SpaceCleaningToolActivity.parseProcessArguments(Array(buffer.prefix(size)))
        }
    }
    #endif
}
