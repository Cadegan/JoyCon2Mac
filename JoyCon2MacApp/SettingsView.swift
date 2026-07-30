import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("sdlOnlyMode") private var sdlOnlyMode = false
    @AppStorage("deadzone") private var deadzone: Double = StickTuning.defaultDeadzone
    @AppStorage("stickSensitivity") private var stickSensitivity: Double = StickTuning.defaultSensitivity
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginNeedsApproval = false
    
    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { updateLaunchAtLogin($0) }
                    )
                )
                    .help("Automatically start JoyCon2Mac when you log in")

                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundColor(launchAtLoginNeedsApproval ? .orange : .red)

                    if launchAtLoginNeedsApproval {
                        Button("Open Login Items Settings") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                
                Text("Joy-Con reconnection is managed automatically while the daemon is running.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Daemon") {
                HStack {
                    Text("Status:")
                    Spacer()
                    Circle()
                        .fill(daemonBridge.isDaemonRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(daemonBridge.isDaemonRunning ? "Running" : "Stopped")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Button("Restart Daemon") {
                        daemonBridge.restartDaemon()
                    }
                    
                    Button("View Logs") {
                        showLogs()
                    }
                }
            }

            Section("Virtual Driver") {
                Toggle("SDL Only Mode", isOn: Binding(
                    get: { sdlOnlyMode },
                    set: { enabled in
                        sdlOnlyMode = enabled
                        daemonBridge.setSDLOnlyMode(enabled)
                        daemonBridge.restartDaemon()
                    }
                ))
                .help("Expose only the DualSense-compatible gamepad to controller clients; the virtual mouse remains available")

                SettingsActionRow(
                    icon: "puzzlepiece.extension",
                    title: "System Gamepad and Mouse",
                    subtitle: "Install and load the local DriverKit extension so macOS and games can see JoyCon2Mac as a real HID device.",
                    buttonTitle: "Install/Load",
                    role: nil,
                    action: daemonBridge.installAndLoadDriver
                )

                if !daemonBridge.driverInstallStatus.isEmpty {
                    Text(daemonBridge.driverInstallStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Telemetry") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log File")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(daemonBridge.telemetryLogPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                HStack {
                    Button("Reveal Log File") {
                        daemonBridge.revealTelemetryLog()
                    }

                    Button("Copy Visible Logs") {
                        daemonBridge.copyTelemetryToClipboard()
                    }

                    Button("Clear View") {
                        daemonBridge.clearTelemetryView()
                    }
                }
            }
            
            Section("Controller") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deadzone: \(deadzone, specifier: "%.2f")")
                    Slider(
                        value: Binding(
                            get: { deadzone },
                            set: { newValue in
                                deadzone = newValue
                                daemonBridge.setDeadzone(newValue)
                            }
                        ),
                        in: StickTuning.deadzoneRange,
                        step: 0.01
                    )
                    Text("Ignore small stick movements below this threshold")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stick Sensitivity: \(stickSensitivity, specifier: "%.2f")x")
                    Slider(
                        value: Binding(
                            get: { stickSensitivity },
                            set: { newValue in
                                stickSensitivity = newValue
                                daemonBridge.setStickSensitivity(newValue)
                            }
                        ),
                        in: StickTuning.sensitivityRange,
                        step: 0.1
                    )
                    Text("Adjust analog stick response curve")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button(daemonBridge.isCalibratingSticks ? "Calibrating..." : "Calibrate Sticks") {
                    requestStickCalibration()
                }
                .disabled(daemonBridge.isCalibratingSticks || !daemonBridge.isDaemonRunning)

                Text(daemonBridge.stickCalibrationStatus)
                    .font(.caption)
                    .foregroundColor(daemonBridge.isCalibratingSticks ? .orange : .secondary)
            }
            
            Section("Data") {
                SettingsActionRow(
                    icon: "square.and.arrow.up",
                    title: "Export Configuration",
                    subtitle: "Save current preferences as JSON.",
                    buttonTitle: "Export",
                    role: nil,
                    action: exportConfig
                )

                SettingsActionRow(
                    icon: "square.and.arrow.down",
                    title: "Import Configuration",
                    subtitle: "Load preferences from a JSON file.",
                    buttonTitle: "Import",
                    role: nil,
                    action: importConfig
                )

                SettingsActionRow(
                    icon: "arrow.counterclockwise",
                    title: "Defaults",
                    subtitle: "Restore app preferences to their initial values.",
                    buttonTitle: "Reset",
                    role: .destructive,
                    action: resetToDefaults
                )
            }
            
            Section("About") {
                HStack {
                    Text("Version:")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Build:")
                    Spacer()
                    Text(appBuild)
                        .foregroundColor(.secondary)
                }
                
                Link("GitHub Repository", destination: URL(string: "https://github.com/Cadegan/JoyCon2Mac")!)
                
                Link("Report Issue", destination: URL(string: "https://github.com/Cadegan/JoyCon2Mac/issues/new")!)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            syncLaunchAtLoginStatus()
        }
    }
    
    func showLogs() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daemon Logs"
        window.contentView = NSHostingView(rootView: LogsView().environmentObject(daemonBridge))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "joycon2mac_config.json"
        panel.allowedContentTypes = [.json]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                // Export configuration
                let config: [String: Any] = [
                    "launchAtLogin": launchAtLogin,
                    "sdlOnlyMode": sdlOnlyMode,
                    "deadzone": deadzone,
                    "stickSensitivity": stickSensitivity
                ]
                
                if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
                    try? data.write(to: url)
                }
            }
        }
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1.0"
    }

    private func syncLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginNeedsApproval = status == .requiresApproval

        switch status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginMessage = nil
        case .requiresApproval:
            launchAtLogin = false
            launchAtLoginMessage = "Allow JoyCon2Mac in System Settings > General > Login Items to finish enabling this option."
        case .notRegistered:
            launchAtLogin = false
            launchAtLoginMessage = nil
        case .notFound:
            launchAtLogin = false
            launchAtLoginMessage = "Launch at login is unavailable for this build."
        @unknown default:
            launchAtLogin = false
            launchAtLoginMessage = "Unable to determine the Login Item status."
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            syncLaunchAtLoginStatus()
        } catch {
            syncLaunchAtLoginStatus()
            launchAtLoginMessage = "Could not update Launch at Login: \(error.localizedDescription)"
            launchAtLoginNeedsApproval = false
        }
    }

    func requestStickCalibration() {
        let alert = NSAlert()
        alert.messageText = "Calibrate Both Sticks?"
        alert.informativeText = "Place both Joy-Cons on a stable surface and leave both sticks completely untouched. Calibration takes less than five seconds."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            daemonBridge.calibrateSticks()
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                // Import configuration
                if let data = try? Data(contentsOf: url),
                   let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    updateLaunchAtLogin(config["launchAtLogin"] as? Bool ?? false)
                    sdlOnlyMode = config["sdlOnlyMode"] as? Bool ?? false
                    daemonBridge.setSDLOnlyMode(sdlOnlyMode)
                    let rawDeadzone = config["deadzone"] as? Double ?? StickTuning.defaultDeadzone
                    deadzone = StickTuning.deadzone(rawDeadzone)
                    daemonBridge.setDeadzone(deadzone)
                    let rawSensitivity = config["stickSensitivity"] as? Double ?? StickTuning.defaultSensitivity
                    stickSensitivity = StickTuning.sensitivity(rawSensitivity)
                    daemonBridge.setStickSensitivity(stickSensitivity)
                }
            }
        }
    }
    
    func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset to Defaults?"
        alert.informativeText = "This will reset all settings to their default values."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            updateLaunchAtLogin(false)
            sdlOnlyMode = false
            daemonBridge.setSDLOnlyMode(false)
            deadzone = StickTuning.defaultDeadzone
            daemonBridge.setDeadzone(StickTuning.defaultDeadzone)
            stickSensitivity = StickTuning.defaultSensitivity
            daemonBridge.setStickSensitivity(StickTuning.defaultSensitivity)
        }
    }
}

struct SettingsActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let role: ButtonRole?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(role == .destructive ? .red : .accentColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((role == .destructive ? Color.red : Color.accentColor).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 16)

            Button(role: role, action: action) {
                Text(buttonTitle)
                    .frame(minWidth: 72)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LogsView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @ObservedObject private var telemetry = TelemetryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("JoyCon2Mac Telemetry")
                        .font(.headline)
                    Text(daemonBridge.telemetryLogPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Reveal") {
                    daemonBridge.revealTelemetryLog()
                }
                Button("Copy") {
                    daemonBridge.copyTelemetryToClipboard()
                }
                Button("Clear") {
                    daemonBridge.clearTelemetryView()
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(telemetry.displayedOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: telemetry.telemetryLineCount) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(DaemonBridge.shared)
}
