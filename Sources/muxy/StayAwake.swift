import AppKit
import IOKit.ps

/// Keeps the Mac running while Muxy runs — lid closed, on battery, no
/// external display — so agents keep working and the phone keeps reaching
/// them. An idle-sleep assertion can't do that; only the system-wide
/// `pmset disablesleep` can, and it needs root. A one-time setup lets
/// Muxy run exactly `pmset -a disablesleep 1|0` without a password.
///
/// That switch survives anything, so Muxy guards it:
/// - quitting Muxy turns it off,
/// - a watcher process turns it off if Muxy dies without quitting,
/// - on battery below `batteryFloor` the Mac may sleep again.
@MainActor
final class StayAwake: ObservableObject {
    static let shared = StayAwake()
    static let enabledKey = "stayAwake"
    /// Muxy switched sleep off and hasn't switched it back yet — survives a
    /// crash, so the next launch can clean up after it (and only after it).
    static let holdingKey = "stayAwakeHolding"
    static let batteryFloor = 20

    static let sudoersPath = "/etc/sudoers.d/muxy-stay-awake"
    private static let pmset = "/usr/bin/pmset"

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    /// Sleep is switched off right now.
    @Published private(set) var holding = false
    @Published private(set) var isSetUp = false
    @Published private(set) var lowBattery = false
    @Published private(set) var problem: String?

    private var timer: Timer?
    private var watcher: Process?

    func start() {
        isSetUp = Self.canSwitch()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { StayAwake.shared.release() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { StayAwake.shared.apply() }
        }
        apply()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on, !isSetUp { setUp() }
        apply()
    }

    /// Holds or releases according to the switch and the battery.
    func apply() {
        lowBattery = Self.onBatteryBelowFloor()
        let want = enabled && isSetUp && !lowBattery
        if want, !holding {
            holding = Self.switchSleep(disabled: true)
            UserDefaults.standard.set(holding, forKey: Self.holdingKey)
            if holding { startWatcher() } else { problem = L("Couldn't keep the Mac awake.") }
        } else if !want, holding {
            release()
        } else if !want, isSetUp, UserDefaults.standard.bool(forKey: Self.holdingKey) {
            // Left on by an earlier Muxy that didn't get to quit.
            if Self.switchSleep(disabled: false) {
                UserDefaults.standard.set(false, forKey: Self.holdingKey)
            }
        }
    }

    func release() {
        guard holding else { return }
        if Self.switchSleep(disabled: false) {
            holding = false
            UserDefaults.standard.set(false, forKey: Self.holdingKey)
        }
        watcher?.terminate()
        watcher = nil
    }

    // MARK: - Setup

    /// Asks for the admin password once and installs a sudoers rule that
    /// allows exactly the two pmset calls — validated before it goes live.
    func setUp() {
        problem = nil
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            problem = L("Couldn't set up: unusual user name.")
            return
        }
        let rule = "# Muxy: keep the Mac awake with the lid closed (Settings, Phone).\n"
            + "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 1, \(Self.pmset) -a disablesleep 0\n"
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("muxy-sudoers-\(UUID().uuidString)")
        do {
            try rule.write(to: staged, atomically: true, encoding: .utf8)
        } catch {
            problem = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        let script = [
            "set -e",
            "grep -qE '^#includedir /private/etc/sudoers.d|^@includedir /private/etc/sudoers.d' /etc/sudoers",
            "/usr/sbin/visudo -c -f '\(staged.path)'",
            "/usr/bin/install -m 0440 -o root -g wheel '\(staged.path)' '\(Self.sudoersPath)'",
            "/usr/sbin/visudo -c",
        ].joined(separator: " && ")
        var error: NSDictionary?
        let apple = NSAppleScript(source: "do shell script \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges")
        apple?.executeAndReturnError(&error)
        if let error {
            // -128: the password dialog was cancelled.
            problem = (error[NSAppleScript.errorNumber] as? Int) == -128
                ? nil : L("Couldn't set up: %@", (error[NSAppleScript.errorMessage] as? String) ?? "?")
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        }
        isSetUp = Self.canSwitch()
    }

    // MARK: - System

    /// The rule is in place: sudo would run pmset without asking.
    static func canSwitch() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", pmset, "-a", "disablesleep", "1"]) == 0
    }

    static func switchSleep(disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"]) == 0
    }

    static func sleepDisabledNow() -> Bool { // shown in Settings
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmset)
        process.arguments = ["-g"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("SleepDisabled") && $0.hasSuffix("1")
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// On battery and below the floor — the Mac should be allowed to sleep
    /// rather than run flat in a bag.
    static func onBatteryBelowFloor() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let percent = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            return onBattery && percent < batteryFloor
        }
        return false
    }

    /// Outlives Muxy on purpose: if Muxy dies without quitting, it lets the
    /// Mac sleep again.
    private func startWatcher() {
        watcher?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 5; done; /usr/bin/sudo -n \(Self.pmset) -a disablesleep 0",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        watcher = process
    }
}
