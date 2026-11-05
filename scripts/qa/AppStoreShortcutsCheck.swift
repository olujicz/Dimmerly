import AppKit
import ApplicationServices
import CoreGraphics

/// Checks the global shortcuts of an installed, signed App Store or TestFlight build of Dimmerly.
///
/// It covers the parts of the App Store shortcut checklist that need the real sandboxed binary:
/// the main and preset shortcuts work from another app without an Accessibility or Input
/// Monitoring prompt, and Safari and Finder keep their Command-number shortcuts. The recorder
/// rules (unsafe and duplicate bindings, re-record and cancel) are the same code in every build
/// and are covered by the unit tests, so they stay a short manual check.
///
/// Before running, configure in Dimmerly: the main shortcut (default Shift-Option-Command-D) and
/// one preset on Control-Option-1, or pass `--preset` with the shortcut a preset already uses.
/// That preset's values must differ from the current display state. Close any
/// other Dimmerly copy. The check dims the displays, presses Escape to wake them and applies the
/// preset, so expect the screen to change.
@main
enum AppStoreShortcutsCheck {
    static func main() {
        do {
            let options = try Options(arguments: CommandLine.arguments)
            let check = Check(options: options)
            defer { check.report.printSummary() }
            do {
                try check.run()
            } catch let error as CheckError {
                check.report.fail(error.message)
            }
            exit(check.report.failed ? 1 : 0)
        } catch let error as CheckError {
            FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(2)
        }
    }
}

struct CheckError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

// MARK: - Options

struct Shortcut: CustomStringConvertible {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let text: String

    var description: String {
        text
    }

    /// Parses `shift+option+command+d`, `control+option+1` and similar.
    init(_ text: String) throws {
        var flags: CGEventFlags = []
        var key: String?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "command", "cmd": flags.insert(.maskCommand)
            default:
                guard key == nil else { throw CheckError("More than one key in shortcut \(text)") }
                key = part
            }
        }
        guard let key, let code = Self.keyCodes[key] else {
            throw CheckError("Unsupported key in shortcut \(text); use a letter, a digit or escape")
        }
        keyCode = code
        self.flags = flags
        self.text = text
    }

    private init(keyCode: CGKeyCode, flags: CGEventFlags, text: String) {
        self.keyCode = keyCode
        self.flags = flags
        self.text = text
    }

    static let escape = Shortcut(keyCode: 53, flags: [], text: "escape")
    static let defaultMain = Shortcut(keyCode: 2, flags: [.maskShift, .maskAlternate, .maskCommand],
                                      text: "shift+option+command+d")
    static let defaultPreset = Shortcut(keyCode: 18, flags: [.maskControl, .maskAlternate], text: "control+option+1")

    static func command(_ digit: Int) -> Shortcut {
        Shortcut(keyCode: keyCodes[String(digit)]!, flags: .maskCommand, text: "command+\(digit)")
    }

    /// ANSI virtual key codes.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "escape": 53,
    ]
}

struct Options {
    var mainShortcut = Shortcut.defaultMain
    var presetShortcut = Shortcut.defaultPreset
    var skipSafari = false
    var skipFinder = false

    static let usage = """
    Usage: AppStoreShortcutsCheck [--main SHORTCUT] [--preset SHORTCUT] [--skip-safari] [--skip-finder]
      SHORTCUT is modifiers and a key joined by +, for example shift+option+command+d.
      Defaults: --main shift+option+command+d --preset control+option+1
    """

    init(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--main", "--preset":
                guard index + 1 < arguments.count else { throw CheckError(Self.usage) }
                let shortcut = try Shortcut(arguments[index + 1])
                if arguments[index] == "--main" {
                    mainShortcut = shortcut
                } else {
                    presetShortcut = shortcut
                }
                index += 2
            case "--skip-safari": skipSafari = true; index += 1
            case "--skip-finder": skipFinder = true; index += 1
            case "--help", "-h": print(Self.usage); exit(0)
            default: throw CheckError(Self.usage)
            }
        }
    }
}

// MARK: - Report

struct Report {
    private(set) var lines: [(passed: Bool?, text: String)] = []

    var failed: Bool {
        lines.contains { $0.passed == false }
    }

    mutating func pass(_ text: String) {
        record(true, text)
    }

    mutating func fail(_ text: String) {
        record(false, text)
    }

    mutating func note(_ text: String) {
        record(nil, text)
    }

    private mutating func record(_ passed: Bool?, _ text: String) {
        lines.append((passed, text))
        let mark = passed.map { $0 ? "PASS" : "FAIL" } ?? "NOTE"
        print("[\(mark)] \(text)")
    }

    func printSummary() {
        let passed = lines.filter { $0.passed == true }.count
        let failed = lines.filter { $0.passed == false }.count
        print("\n\(passed) passed, \(failed) failed.")
        print("""

        Still to check by hand in Settings › Shortcuts (logic covered by unit tests):
          - Command-1, Option-1 and Shift-Option-1 are refused in the main and preset recorders,
            and the two-modifier message stays visible.
          - Reusing a binding that is already taken shows a conflict and keeps the old binding.
          - Re-recording and cancelling a binding leaves it working from another app.
        """)
    }
}

// MARK: - Check

final class Check {
    let options: Options
    var report = Report()
    private var dimmerly: NSRunningApplication!

    init(options: Options) {
        self.options = options
    }

    func run() throws {
        guard AXIsProcessTrusted() else {
            let host = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
            throw CheckError("""
            This process can't post keyboard events. Allow \(host) in System Settings › \
            Privacy & Security › Accessibility, then run the check again.
            """)
        }
        let startedAt = Date()
        dimmerly = try findStoreBuild()
        try checkMainShortcut()
        try checkPresetShortcut()
        if !options.skipSafari {
            try checkSafari()
        }
        if !options.skipFinder {
            try checkFinder()
        }
        checkNoPermissionRequests(since: startedAt)
    }

    // MARK: Store build

    private func findStoreBuild() throws -> NSRunningApplication {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "rs.in.olujic.dimmerly")
        guard !running.isEmpty else { throw CheckError("Dimmerly isn't running. Open the TestFlight build first.") }
        guard running.count == 1 else {
            let paths = running.compactMap { $0.bundleURL?.path }.joined(separator: ", ")
            throw CheckError("More than one Dimmerly is running (\(paths)). Quit all but the TestFlight build.")
        }
        let app = running[0]
        guard let url = app.bundleURL else { throw CheckError("Can't locate the running Dimmerly bundle.") }
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let receipt = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
        let sandboxed = Self.isSandboxed(url)
        if receipt, sandboxed {
            report.pass(
                "Running the store build: \(url.lastPathComponent) \(version) (\(build)), sandboxed, with receipt"
            )
        } else {
            throw CheckError("""
            \(url.path) \(version) (\(build)) isn't an App Store or TestFlight build \
            (receipt: \(receipt), sandboxed: \(sandboxed)).
            """)
        }
        return app
    }

    private static func isSandboxed(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    // MARK: Main shortcut

    private func checkMainShortcut() throws {
        try activate(bundleID: "com.apple.finder")
        guard blankingWindowCount() == 0 else {
            throw CheckError("Displays are already dimmed. Wake them and run the check again.")
        }
        Keyboard.press(options.mainShortcut)
        let dimmed = waitUntil(seconds: 4) { blankingWindowCount() > 0 }
        let screens = NSScreen.screens.count
        if dimmed {
            let count = blankingWindowCount()
            let covered = "\(count) blanking windows for \(screens) screens"
            report.pass("Main shortcut \(options.mainShortcut) dimmed displays from Finder (\(covered))")
        } else {
            report.fail("Main shortcut \(options.mainShortcut) didn't dim the displays with Finder frontmost")
            return
        }
        // Blanking ignores input briefly after it starts, then any wake setting accepts Escape.
        Thread.sleep(forTimeInterval: 1.5)
        Keyboard.press(.escape)
        if waitUntil(seconds: 4, { blankingWindowCount() == 0 }) {
            report.pass("Escape woke the displays")
        } else {
            report.fail("Displays stayed dimmed after Escape; wake them with your configured input")
            _ = waitUntil(seconds: 30) { blankingWindowCount() == 0 }
        }
    }

    /// Dimmerly's blanking overlays: its windows at screen-saver level. Layer, owner and bounds
    /// are available without Screen Recording permission.
    private func blankingWindowCount() -> Int {
        let level = Int(CGWindowLevelForKey(.screenSaverWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == dimmerly.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int ?? 0) >= level
        }.count
    }

    // MARK: Preset shortcut

    private func checkPresetShortcut() throws {
        try activate(bundleID: "com.apple.finder")
        let before = Gamma.snapshot()
        Keyboard.press(options.presetShortcut)
        if waitUntil(seconds: 4, { Gamma.snapshot() != before }) {
            report.pass("Preset shortcut \(options.presetShortcut) changed the displays from Finder")
            report.note("The preset is still applied; switch back to your usual preset afterwards")
        } else {
            report.fail("""
            Preset shortcut \(options.presetShortcut) didn't change any display's gamma. Check that a preset \
            is bound to \(options.presetShortcut) (or pass --preset with the shortcut one uses) and that its \
            values differ from the current state, then run again.
            """)
        }
    }

    // MARK: Safari

    private func checkSafari() throws {
        let opened = try AppleScript.run("""
        tell application "Safari"
            make new document with properties {URL:"about:blank"}
            tell front window
                make new tab with properties {URL:"about:blank"}
                make new tab with properties {URL:"about:blank"}
                set current tab to tab 1
            end tell
            return id of front window
        end tell
        """)
        defer { _ = try? AppleScript.run("tell application \"Safari\" to close (every window whose id is \(opened))") }
        try activate(bundleID: "com.apple.Safari")
        Thread.sleep(forTimeInterval: 0.5)
        let gammaBefore = Gamma.snapshot()
        var results: [String] = []
        var ok = true
        for digit in [2, 3, 1] {
            Keyboard.press(.command(digit))
            let reached = waitUntil(seconds: 2) {
                (try? AppleScript.run("tell application \"Safari\" to return index of current tab of front window"))
                    == String(digit)
            }
            results.append("⌘\(digit)\(reached ? "✓" : "✗")")
            ok = ok && reached
        }
        let untouched = blankingWindowCount() == 0 && Gamma.snapshot() == gammaBefore
        if ok, untouched {
            report.pass("Safari kept ⌘1–⌘3 for tabs (\(results.joined(separator: " "))) and Dimmerly didn't react")
        } else if !ok {
            report.fail("""
            Safari didn't switch tabs on every Command-number (\(results.joined(separator: " "))). If \
            Safari › Settings › Tabs has \"Use ⌘-1 through ⌘-9 to switch tabs\" off, turn it on and rerun.
            """)
        } else {
            report.fail("Dimmerly changed the displays while Safari received Command-number")
        }
    }

    // MARK: Finder

    private func checkFinder() throws {
        let opened = try AppleScript.run("""
        tell application "Finder"
            make new Finder window to home
            return id of front Finder window
        end tell
        """)
        // Finder saves the view per folder, so put the home folder's original view back.
        let originalView = try AppleScript.run("""
        tell application "Finder" to return (current view of (Finder window id \(opened))) as text
        """)
        defer {
            _ = try? AppleScript.run("""
            tell application "Finder"
                set current view of (Finder window id \(opened)) to \(originalView)
                close (Finder window id \(opened))
            end tell
            """)
        }
        try activate(bundleID: "com.apple.finder")
        Thread.sleep(forTimeInterval: 0.5)
        let gammaBefore = Gamma.snapshot()
        let expected = [1: "icon view", 2: "list view", 3: "column view"]
        var results: [String] = []
        var ok = true
        for digit in [2, 3, 1] {
            Keyboard.press(.command(digit))
            let reached = waitUntil(seconds: 2) {
                let view = "tell application \"Finder\" to return (current view of front Finder window) as text"
                return (try? AppleScript.run(view))
                    .map { $0.contains(expected[digit]!.components(separatedBy: " ")[0]) } ?? false
            }
            results.append("⌘\(digit)\(reached ? "✓" : "✗")")
            ok = ok && reached
        }
        let untouched = blankingWindowCount() == 0 && Gamma.snapshot() == gammaBefore
        if ok, untouched {
            report.pass("Finder kept ⌘1–⌘3 for views (\(results.joined(separator: " "))) and Dimmerly didn't react")
        } else if !ok {
            report.fail("Finder didn't switch views on every Command-number (\(results.joined(separator: " ")))")
        } else {
            report.fail("Dimmerly changed the displays while Finder received Command-number")
        }
    }

    // MARK: Permission requests

    /// Dimmerly must not ask for Accessibility or Input Monitoring. Any request appears in the
    /// TCC log, whether or not a dialog was answered.
    private func checkNoPermissionRequests(since start: Date) {
        let seconds = Int(Date().timeIntervalSince(start)) + 5
        let predicate = """
        subsystem == "com.apple.TCC" AND eventMessage CONTAINS "rs.in.olujic.dimmerly" AND \
        (eventMessage CONTAINS "kTCCServiceAccessibility" OR eventMessage CONTAINS "kTCCServiceListenEvent" \
        OR eventMessage CONTAINS "kTCCServicePostEvent")
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "\(seconds)s", "--style", "compact", "--predicate", predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            let hits = output.split(separator: "\n").filter { $0.contains("kTCCService") }
            if hits.isEmpty {
                report.pass("No Accessibility, Input Monitoring or event-posting request from Dimmerly during the run")
            } else {
                let lines = hits.prefix(3).joined(separator: "\n  ")
                report.fail("Dimmerly requested a privacy permission during the run:\n  \(lines)")
            }
        } catch {
            report.note("Couldn't read the TCC log (\(error)); confirm no permission dialog appeared")
        }
    }

    // MARK: Helpers

    private func activate(bundleID: String) throws {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw CheckError("Can't find \(bundleID)")
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            _ = waitUntil(seconds: 5) {
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            }
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        guard waitUntil(seconds: 3, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }) else {
            throw CheckError("Couldn't bring \(bundleID) to the front")
        }
    }
}

func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if condition() {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return condition()
}

// MARK: - Keyboard

enum Keyboard {
    /// Posts the key at the HID level so it reaches Carbon hotkeys and the frontmost app the same
    /// way a physical keyboard does. Requires Accessibility permission for this process.
    static func press(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down)
            event?.flags = shortcut.flags
            event?.post(tap: .cghidEventTap)
            usleep(30000)
        }
        usleep(150_000)
    }
}

// MARK: - Gamma

enum Gamma {
    /// Each online display's current gamma table, which software dimming and presets change.
    static func snapshot() -> [[Float]] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.map { display in
            let capacity = CGDisplayGammaTableCapacity(display)
            var red = [CGGammaValue](repeating: 0, count: Int(capacity))
            var green = red, blue = red
            var sampleCount: UInt32 = 0
            CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &sampleCount)
            let n = Int(sampleCount)
            // Rounded so float noise doesn't count as a change.
            return (red.prefix(n) + green.prefix(n) + blue.prefix(n)).map { ($0 * 1000).rounded() / 1000 }
        }
    }
}

// MARK: - AppleScript

enum AppleScript {
    @discardableResult
    static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw CheckError("Invalid AppleScript") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                throw CheckError("""
                Automation isn't allowed. Approve the prompt, or allow it in System Settings › Privacy & \
                Security › Automation, then run again. (\(message))
                """)
            }
            throw CheckError("AppleScript failed: \(message)")
        }
        return result.stringValue ?? ""
    }
}
