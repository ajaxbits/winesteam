import Cocoa
import Foundation

// WineSteam — Native macOS launcher with first-run setup UI.
// Checks for Wine, downloads it if missing (with progress window),
// then launches Steam via launch-steam.sh.
// Build: swiftc -O -o WineSteamLauncher WineSteamLauncher.swift

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var statusLabel: NSTextField!
    var progressBar: NSProgressIndicator!
    var cancelButton: NSButton!
    var setupProcess: Process?

    let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WineSteam")
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WineSteam")

    var resourcesDir: String {
        return Bundle.main.resourcePath ?? ""
    }

    var wineDir: URL {
        return supportDir.appendingPathComponent("wine")
    }

    var wineExists: Bool {
        return FileManager.default.isExecutableFile(
            atPath: wineDir.appendingPathComponent("bin/wine").path)
    }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if wineExists {
            launchSteam()
        } else {
            checkRosetta {
                self.showSetupWindow()
                self.runSetup()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Rosetta Check

    func checkRosetta(then completion: @escaping () -> Void) {
        #if arch(arm64)
        // Check if Rosetta is installed by looking for oahd
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-q", "oahd"]
        check.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                // Rosetta not installed — trigger install
                let install = Process()
                install.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
                install.arguments = ["--install-rosetta", "--agree-to-license"]
                install.terminationHandler = { _ in
                    DispatchQueue.main.async { completion() }
                }
                try? install.run()
            } else {
                DispatchQueue.main.async { completion() }
            }
        }
        try? check.run()
        #else
        completion()
        #endif
    }

    // MARK: - Setup Window

    func showSetupWindow() {
        NSApplication.shared.setActivationPolicy(.regular)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        w.title = "WineSteam Setup"
        w.center()
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        // Icon
        if let icon = NSImage(named: NSImage.applicationIconName) {
            let iconView = NSImageView(frame: NSRect(x: 20, y: 60, width: 64, height: 64))
            iconView.image = icon
            content.addSubview(iconView)
        }

        // Status label
        statusLabel = NSTextField(labelWithString: "Preparing to download Wine Staging...")
        statusLabel.frame = NSRect(x: 100, y: 110, width: 300, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        content.addSubview(statusLabel)

        // Detail label
        let detail = NSTextField(labelWithString: "This only happens once. Wine is ~190 MB.")
        detail.frame = NSRect(x: 100, y: 88, width: 300, height: 16)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        content.addSubview(detail)

        // Progress bar
        progressBar = NSProgressIndicator(frame: NSRect(x: 100, y: 60, width: 300, height: 20))
        progressBar.isIndeterminate = true
        progressBar.style = .bar
        progressBar.startAnimation(nil)
        content.addSubview(progressBar)

        // Cancel button
        cancelButton = NSButton(frame: NSRect(x: 310, y: 16, width: 90, height: 32))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSetup)
        content.addSubview(cancelButton)

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func cancelSetup() {
        setupProcess?.terminate()
        NSApplication.shared.terminate(nil)
    }

    func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = text
        }
    }

    // MARK: - Setup

    func runSetup() {
        let setupScript = (resourcesDir as NSString).appendingPathComponent("setup.sh")

        guard FileManager.default.isExecutableFile(atPath: setupScript) else {
            showError("setup.sh not found in app bundle.",
                      detail: "The app may be damaged. Please re-download WineSteam.")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [setupScript, "--target-dir", wineDir.path, "--quiet"]
        proc.currentDirectoryURL = URL(fileURLWithPath: resourcesDir)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        // Read progress lines on background queue
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            let data = handle.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") {
                    if line.hasPrefix("PROGRESS:") {
                        let status = String(line.dropFirst("PROGRESS:".count))
                        switch status {
                        case "downloading":
                            self.updateStatus("Downloading Wine Staging...")
                        case "verifying":
                            self.updateStatus("Verifying download integrity...")
                        case "extracting":
                            self.updateStatus("Extracting Wine (this takes a moment)...")
                        case "done":
                            self.updateStatus("Done!")
                        default:
                            self.updateStatus(status)
                        }
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setupProcess = nil

                if process.terminationStatus == 0 {
                    self.window?.close()
                    self.window = nil
                    NSApplication.shared.setActivationPolicy(.accessory)
                    self.launchSteam()
                } else {
                    self.showError("Wine setup failed (exit code \(process.terminationStatus)).",
                                   detail: "Check your internet connection and try again.\nLogs: ~/Library/Logs/WineSteam/")
                }
            }
        }

        do {
            setupProcess = proc
            try proc.run()
        } catch {
            showError("Failed to start setup.", detail: error.localizedDescription)
        }
    }

    // MARK: - Launch Steam

    func launchSteam() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let launchScript = (resourcesDir as NSString).appendingPathComponent("launch-steam.sh")

        guard FileManager.default.isExecutableFile(atPath: launchScript) else {
            showError("launch-steam.sh not found in app bundle.",
                      detail: "The app may be damaged. Please re-download WineSteam.")
            return
        }

        // Create log file
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let logFile = logDir.appendingPathComponent(
            "winesteam-\(formatter.string(from: Date())).log")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", """
            exec > "$1" 2>&1
            echo "=== WineSteam started at $(date) ==="
            exec "$2"
            """, "--", logFile.path, launchScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: resourcesDir)
        proc.standardInput = FileHandle.nullDevice

        proc.terminationHandler = { _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        do {
            try proc.run()
        } catch {
            showError("Failed to launch Steam.", detail: error.localizedDescription)
        }
    }

    // MARK: - Error Handling

    func showError(_ message: String, detail: String) {
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = message
            alert.informativeText = detail
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
