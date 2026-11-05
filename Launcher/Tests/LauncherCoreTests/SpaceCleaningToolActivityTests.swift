import XCTest
@testable import LauncherCore

final class SpaceCleaningToolActivityTests: XCTestCase {
    private typealias Activity = SpaceCleaningToolActivity

    func testInterpretedToolsRequireTheirScriptAndIgnoreOtherInterpreterWork() {
        // npm and npx run under node; the script, not the interpreter, identifies them.
        XCTAssertEqual(Activity.identities(executable: "/opt/homebrew/bin/node", arguments: ["node", "/Users/test/.local/bin/npm", "install"]), [Activity.npm])
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node", "--max-old-space-size=4096", "/usr/local/lib/node_modules/npm/bin/npx-cli.js", "create"]), [Activity.npm])
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node", "/Users/test/project/server.js", "--name", "npm"]), [])
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node"]), [])
        // Homebrew starts in bash and continues in ruby.
        XCTAssertEqual(Activity.identities(executable: "/bin/bash", arguments: ["/bin/bash", "/opt/homebrew/bin/brew", "upgrade"]), [Activity.homebrew])
        XCTAssertEqual(Activity.identities(executable: "ruby", arguments: ["ruby", "-W1", "--disable=gems,rubyopt", "/opt/homebrew/Library/Homebrew/brew.rb", "upgrade"]), [Activity.homebrew])
        XCTAssertEqual(Activity.identities(executable: "/bin/zsh", arguments: ["/bin/zsh", "/Users/test/scripts/build.sh"]), [])
        XCTAssertEqual(Activity.identities(executable: "ruby", arguments: ["ruby", "app.rb"]), [])
        // pip runs as a module, a virtual-environment script or the system shim.
        XCTAssertEqual(Activity.identities(executable: "Python", arguments: ["/usr/bin/python3", "-m", "pip", "install", "requests"]), [Activity.pip])
        XCTAssertEqual(Activity.identities(executable: "python3.12", arguments: ["/Users/test/venv/bin/python3.12", "/Users/test/venv/bin/pip3.12", "install"]), [Activity.pip])
        XCTAssertEqual(Activity.identities(executable: "pip3", arguments: ["pip3"]), [Activity.pip])
        XCTAssertEqual(Activity.identities(executable: "Python", arguments: ["Python", "-m", "http.server"]), [])
        XCTAssertEqual(Activity.identities(executable: "Python", arguments: ["Python", "/Users/test/tools/pipeline.py"]), [])
        // env resolves to the program it starts.
        XCTAssertEqual(Activity.identities(executable: "/usr/bin/env", arguments: ["/usr/bin/env", "FOO=1", "node", "/Users/test/.local/bin/npm", "ci"]), [Activity.npm])
        // Native build tools keep their own names, including the Swift Build service.
        XCTAssertEqual(Activity.identities(executable: "SWBBuildService", arguments: ["SWBBuildService"]), ["SWBBuildService"])
        XCTAssertEqual(Activity.identities(executable: "/usr/bin/xcodebuild", arguments: ["xcodebuild", "build"]), ["xcodebuild"])
    }

    func testNewCacheOwnersAreRecognizedByTheirScriptsAndBinaries() {
        // Yarn, pnpm and Playwright run as Node scripts; unrelated Node work does not count.
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/yarn/bin/yarn.js", "install"]), [Activity.yarn])
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node", "/Users/test/.cache/node/corepack/v1/pnpm/9.0.0/bin/pnpm.cjs", "i"]), [Activity.pnpm])
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node", "/Users/test/app/node_modules/@playwright/test/cli.js", "test"]), [Activity.playwright])
        XCTAssertEqual(Activity.identities(executable: "node", arguments: ["node", "/Users/test/app/scripts/yarn-report.js"]), [])
        // Native tools report their own names.
        XCTAssertEqual(Activity.identities(executable: "/opt/homebrew/bin/uv", arguments: ["uv", "pip", "install"]), [Activity.uv])
        XCTAssertEqual(Activity.identities(executable: "uvx", arguments: ["uvx", "ruff"]), [Activity.uv])
        XCTAssertEqual(Activity.identities(executable: "cargo", arguments: ["cargo", "build"]), [Activity.cargo])
        XCTAssertEqual(Activity.identities(executable: "chrome-headless-shell", arguments: ["chrome-headless-shell"]), [Activity.testBrowser])
        // Gradle runs inside Java; other Java work does not count.
        XCTAssertEqual(Activity.identities(executable: "java", arguments: ["java", "-Xmx2g", "-cp", "/Users/test/.gradle/wrapper/dists/gradle-8.7/lib/gradle-launcher.jar",
                                                                          "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.7"]), [Activity.gradle])
        XCTAssertEqual(Activity.identities(executable: "java", arguments: ["java", "-jar", "/Users/test/server.jar"]), [])
        // CocoaPods, Poetry and Composer run through their interpreters.
        XCTAssertEqual(Activity.identities(executable: "ruby", arguments: ["ruby", "/opt/homebrew/bin/pod", "install"]), [Activity.cocoapods])
        XCTAssertEqual(Activity.identities(executable: "Python", arguments: ["Python", "/Users/test/.local/bin/poetry", "install"]), [Activity.poetry])
        XCTAssertEqual(Activity.identities(executable: "php", arguments: ["php", "/usr/local/bin/composer", "install"]), [Activity.composer])
        XCTAssertTrue(Activity.unreadableProcessTable.isSuperset(of: [Activity.yarn, Activity.uv, Activity.gradle, Activity.testBrowser]))
    }

    func testProcessArgumentsParserReturnsArgvWithoutEnvironment() {
        var bytes = withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) }
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/Users/test/.local/bin/npm".utf8) + [0] + Array("install".utf8) + [0]
        bytes += Array("SECRET_TOKEN=value".utf8) + [0] + Array("HOME=/Users/test".utf8) + [0]
        let parsed = Activity.parseProcessArguments(bytes)
        XCTAssertEqual(parsed?.executable, "/opt/homebrew/bin/node")
        XCTAssertEqual(parsed?.arguments, ["node", "/Users/test/.local/bin/npm", "install"])

        XCTAssertNil(Activity.parseProcessArguments([]))
        var truncated = withUnsafeBytes(of: Int32(2).littleEndian) { Array($0) }
        truncated += Array("/bin/sh".utf8) + [0, 0] + Array("only-one".utf8)
        XCTAssertNil(Activity.parseProcessArguments(truncated))
        var negative = withUnsafeBytes(of: Int32(-1).littleEndian) { Array($0) }
        negative += Array("/bin/sh".utf8) + [0]
        XCTAssertNil(Activity.parseProcessArguments(negative))
    }

    func testCurrentProcessTableIsReadable() {
        // Exercises the live process-table and launch-argument path.
        XCTAssertNotEqual(Activity.currentIdentities(), Activity.unreadableProcessTable)
    }
}
