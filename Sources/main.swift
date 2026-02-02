import Cocoa
import Darwin

// MARK: - Logger

class Logger {
    static let shared = Logger()

    private var debugEnabled = false
    private var logFile: FileHandle?
    private let logPath = NSHomeDirectory() + "/Library/Logs/AWDLToggle.log"

    var isDebugEnabled: Bool {
        get { debugEnabled }
        set {
            debugEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: "debugEnabled")
            if newValue {
                openLogFile()
                log("Debug logging enabled")
            } else {
                log("Debug logging disabled")
                closeLogFile()
            }
        }
    }

    init() {
        debugEnabled = UserDefaults.standard.bool(forKey: "debugEnabled")
        if debugEnabled {
            openLogFile()
        }
    }

    private func openLogFile() {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        logFile = FileHandle(forWritingAtPath: logPath)
        logFile?.seekToEndOfFile()
    }

    private func closeLogFile() {
        logFile?.closeFile()
        logFile = nil
    }

    func log(_ message: String) {
        guard debugEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        if let data = line.data(using: .utf8) {
            logFile?.write(data)
        }
        print(line, terminator: "")
    }

    func getLogPath() -> String {
        return logPath
    }
}

func log(_ message: String) {
    Logger.shared.log(message)
}

// MARK: - AWDL Monitor

class AWDLMonitor {
    private let targetInterface = "awdl0"
    private var routeSocket: Int32 = -1
    private var interfaceIndex: UInt32 = 0
    private var monitorThread: Thread?
    private var isRunning = false

    var onStateChange: ((Bool) -> Void)?

    func start() -> Bool {
        interfaceIndex = if_nametoindex(targetInterface)
        guard interfaceIndex != 0 else {
            log("Error: Could not get interface index for \(targetInterface)")
            return false
        }

        routeSocket = socket(AF_ROUTE, SOCK_RAW, 0)
        guard routeSocket >= 0 else {
            log("Error: Could not create AF_ROUTE socket")
            return false
        }

        let flags = fcntl(routeSocket, F_GETFL, 0)
        _ = fcntl(routeSocket, F_SETFL, flags | O_NONBLOCK)

        isRunning = true

        monitorThread = Thread { [weak self] in
            self?.monitorLoop()
        }
        monitorThread?.name = "AWDLMonitor"
        monitorThread?.start()

        log("Monitor started, interface index: \(interfaceIndex)")
        return true
    }

    func stop() {
        isRunning = false
        if routeSocket >= 0 {
            close(routeSocket)
            routeSocket = -1
        }
        log("Monitor stopped")
    }

    func checkAWDLStatus() -> Bool {
        let task = Process()
        task.launchPath = "/sbin/ifconfig"
        task.arguments = [targetInterface]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let isUp = output.contains("<UP,") || output.contains(",UP,") || output.contains(",UP>")
                return isUp
            }
        } catch {}

        return false
    }

    private func monitorLoop() {
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        var pollfd = Darwin.pollfd(fd: routeSocket, events: Int16(POLLIN), revents: 0)

        while isRunning {
            let result = poll(&pollfd, 1, 100)

            if result < 0 {
                if errno == EINTR { continue }
                break
            }

            if result == 0 { continue }

            var gotRelevantMessage = false

            while true {
                let len = read(routeSocket, &buffer, bufferSize)
                if len < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { break }
                    break
                }

                if len < MemoryLayout<rt_msghdr>.size { continue }

                buffer.withUnsafeBytes { ptr in
                    guard ptr.count >= MemoryLayout<rt_msghdr>.size else { return }

                    let rtmsg = ptr.load(as: rt_msghdr.self)
                    guard rtmsg.rtm_type == RTM_IFINFO else { return }

                    guard ptr.count >= MemoryLayout<if_msghdr>.size else { return }
                    let ifmsg = ptr.load(as: if_msghdr.self)

                    guard ifmsg.ifm_index == UInt16(interfaceIndex) else { return }

                    gotRelevantMessage = true
                }
            }

            if gotRelevantMessage {
                let isUp = checkAWDLStatus()
                log("AWDL state change detected: \(isUp ? "UP" : "DOWN")")

                DispatchQueue.main.async { [weak self] in
                    self?.onStateChange?(isUp)
                }
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var blockingEnabled = false
    private var awdlIsUp = false
    private var monitor: AWDLMonitor?
    private var pollingTimer: Timer?
    private var didLogDisableSuccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("=== AWDLToggle started ===")
        log("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        monitor = AWDLMonitor()

        monitor?.onStateChange = { [weak self] isUp in
            guard let self = self else { return }

            let wasUp = self.awdlIsUp
            self.awdlIsUp = isUp
            self.updateUI()

            if isUp && !wasUp {
                self.didLogDisableSuccess = false  // Reset - new fight begins
                if self.blockingEnabled {
                    log("AWDL came up while blocking enabled!")
                    self.disableAWDL(reason: "AWDL revived while blocking enabled")
                }
            }
        }

        awdlIsUp = monitor?.checkAWDLStatus() ?? false
        blockingEnabled = UserDefaults.standard.bool(forKey: "blockingEnabled")

        log("Initial state - AWDL: \(awdlIsUp ? "UP" : "DOWN"), Blocking: \(blockingEnabled ? "ON" : "OFF")")

        // Log helper status
        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/awdl-helper"
        if FileManager.default.fileExists(atPath: helperPath) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: helperPath) {
                let permissions = attrs[.posixPermissions] as? Int ?? 0
                let owner = attrs[.ownerAccountName] as? String ?? "unknown"
                let hasSetuid = (permissions & 0o4000) != 0
                log("Helper: owner=\(owner), perms=\(String(permissions, radix: 8)), setuid=\(hasSetuid ? "YES" : "NO")")
                if !hasSetuid || owner != "root" {
                    log("WARNING: Helper may not work properly! Need: owner=root, setuid=YES")
                }
            }
        } else {
            log("ERROR: Helper not found at \(helperPath)")
        }

        if monitor?.start() == true {
            if blockingEnabled && awdlIsUp {
                disableAWDL(reason: "blocking enabled on startup")
            }
        } else {
            log("WARNING: Failed to start AWDL monitor")
        }

        // Backup polling every 10 sec when debug is enabled
        if Logger.shared.isDebugEnabled {
            startPolling()
        }

        updateUI()
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let actualState = self.monitor?.checkAWDLStatus() ?? false

            if actualState != self.awdlIsUp {
                log("Polling detected state mismatch! Cached: \(self.awdlIsUp ? "UP" : "DOWN"), Actual: \(actualState ? "UP" : "DOWN")")
                self.awdlIsUp = actualState
                self.updateUI()
            }

            if actualState && self.blockingEnabled {
                log("Polling: AWDL is UP while blocking enabled, killing...")
                self.disableAWDL(reason: "polling detected AWDL up")
            }
        }
    }

    private func runHelper(_ action: String) {
        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/awdl-helper"

        log("Running helper: \(action)")

        // Check if helper exists
        if !FileManager.default.fileExists(atPath: helperPath) {
            log("ERROR: Helper not found at \(helperPath)")
            return
        }

        let task = Process()
        task.launchPath = helperPath
        task.arguments = [action]

        let stderrPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = stderrPipe

        do {
            try task.run()
            task.waitUntilExit()

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            if task.terminationStatus == 0 {
                log("Helper '\(action)' completed (exit 0)")
            } else {
                log("ERROR: Helper '\(action)' failed (exit \(task.terminationStatus))")
                if !stderr.isEmpty {
                    log("ERROR: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        } catch {
            log("ERROR: Failed to launch helper: \(error.localizedDescription)")
        }
    }

    private func disableAWDL(reason: String = "user request", isRetry: Bool = false) {
        if !isRetry {
            log("Disabling AWDL (reason: \(reason))")
        }

        runHelper("down")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            let newState = self.monitor?.checkAWDLStatus() ?? false
            self.awdlIsUp = newState
            self.updateUI()

            if !newState {
                if !self.didLogDisableSuccess {
                    log("AWDL disabled successfully")
                    self.didLogDisableSuccess = true
                }
            } else if self.blockingEnabled {
                log("AWDL still alive! Retrying...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if self.blockingEnabled && self.awdlIsUp {
                        self.disableAWDL(reason: reason, isRetry: true)
                    }
                }
            }
        }
    }

    private func enableAWDL(reason: String = "user request") {
        log("Enabling AWDL (reason: \(reason))")
        let wasDown = !awdlIsUp
        runHelper("up")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let newState = self?.monitor?.checkAWDLStatus() ?? false
            self?.awdlIsUp = newState

            if wasDown && newState {
                log("AWDL enabled successfully")
            } else if !newState {
                log("WARNING: AWDL still DOWN after enable attempt!")
            }
            self?.updateUI()
        }
    }

    private func updateUI() {
        guard let button = statusItem.button else { return }

        if awdlIsUp {
            button.title = blockingEnabled ? "AWDL ↑ ⚠️" : "AWDL ↑"
        } else {
            button.title = "AWDL ↓"
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        let blockingStatus = blockingEnabled ? "Blocked" : "Allowed"
        let runningStatus = awdlIsUp ? "Running" : "Stopped"
        let statusMenuItem = NSMenuItem(title: "AWDL: \(blockingStatus), \(runningStatus)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if blockingEnabled && awdlIsUp {
            menu.addItem(NSMenuItem.separator())
            let warningItem = NSMenuItem(title: "⚠️ AWDL came up, disabling...", action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            menu.addItem(warningItem)
        }

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: blockingEnabled ? "Allow AWDL" : "Block AWDL",
            action: #selector(toggleBlocking),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Debug menu
        let debugItem = NSMenuItem(
            title: Logger.shared.isDebugEnabled ? "✓ Debug Logging" : "Debug Logging",
            action: #selector(toggleDebug),
            keyEquivalent: ""
        )
        debugItem.target = self
        menu.addItem(debugItem)

        if Logger.shared.isDebugEnabled {
            let showLogItem = NSMenuItem(title: "Show Log File", action: #selector(showLogFile), keyEquivalent: "")
            showLogItem.target = self
            menu.addItem(showLogItem)
        }

        menu.addItem(NSMenuItem.separator())

        let creditItem = NSMenuItem(title: "Made by @kryuchenko", action: #selector(openMyGitHub), keyEquivalent: "")
        creditItem.target = self
        menu.addItem(creditItem)

        let inspiredItem = NSMenuItem(title: "Inspired by awdlkiller by @jamestut", action: #selector(openJamestutGitHub), keyEquivalent: "")
        inspiredItem.target = self
        menu.addItem(inspiredItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleBlocking() {
        blockingEnabled.toggle()
        UserDefaults.standard.set(blockingEnabled, forKey: "blockingEnabled")

        log("User toggled blocking: \(blockingEnabled ? "ON" : "OFF")")

        if blockingEnabled {
            if awdlIsUp {
                disableAWDL(reason: "user enabled blocking")
            } else {
                log("Blocking enabled, AWDL already down")
            }
        } else {
            enableAWDL(reason: "user disabled blocking")
        }

        updateUI()
    }

    @objc private func toggleDebug() {
        Logger.shared.isDebugEnabled.toggle()
        updateUI()
    }

    @objc private func showLogFile() {
        NSWorkspace.shared.selectFile(Logger.shared.getLogPath(), inFileViewerRootedAtPath: "")
    }

    @objc private func openMyGitHub() {
        if let url = URL(string: "https://github.com/kryuchenko/AWDLToggle") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openJamestutGitHub() {
        if let url = URL(string: "https://github.com/jamestut/awdlkiller") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        log("=== AWDLToggle quit ===")

        let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/com.local.awdltoggle.plist"
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", launchAgentPath]
        try? task.run()
        task.waitUntilExit()

        monitor?.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let runningApps = NSWorkspace.shared.runningApplications
let myBundleId = Bundle.main.bundleIdentifier ?? "com.local.awdltoggle"
let alreadyRunning = runningApps.filter { $0.bundleIdentifier == myBundleId }.count > 1

if alreadyRunning {
    print("AWDL Toggle is already running")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
