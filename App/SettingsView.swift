import SwiftUI
import NetworkExtension

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirm = false
    @State private var showCopiedToast = false
    @ObservedObject private var diagLog = DiagLog.shared

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
                }

                Section {
                    diagnosticRow(label: "VPN", value: vpnStatusText)
                    diagnosticRow(label: "Certificate", value: certificateStatusText)
                    diagnosticRow(label: "Spoofed Location", value: currentLocationText)
                    diagnosticRow(label: "Coordinates", value: currentCoordinatesText)
                    diagnosticRow(label: "Initial Setup", value: setupCompletedText)

                    Button { copyDiagnostic() } label: {
                        Label(showCopiedToast ? "Copied" : "Copy Diagnostics",
                              systemImage: showCopiedToast ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.success, trigger: showCopiedToast) { _, new in new }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Copies the status above and the flow logs below. Include this when reporting a problem.")
                }

                Section {
                    Button { queryGoLogsViaIPC() } label: {
                        Label("Fetch Proxy Logs", systemImage: "arrow.down.doc")
                    }
                    if diagLog.entries.isEmpty {
                        Text("No logs yet. Use a location once, then come back.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(diagLog.entries.reversed()) { entry in
                            Text(entry.formatted)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    HStack {
                        Text("Flow Logs (\(diagLog.entries.count))")
                        Spacer()
                        Button("Clear", role: .destructive) { diagLog.clear() }
                            .font(.footnote)
                            .textCase(nil)
                            .disabled(diagLog.entries.isEmpty)
                    }
                }

                Section {
                    Button(role: .destructive) { showResetConfirm = true } label: {
                        Label("Reset App", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Clears all settings, favorites and certificate state. You'll need to run setup again.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Reset Location Spoofer?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) { resetApp() }
            } message: {
                Text("This clears all settings, favorites and certificate state. You'll need to run setup again.")
            }
        }
    }

    // MARK: - 诊断信息收集

    private func diagnosticRow(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.callout.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private var vpnStatusText: String {
        guard let manager = ContentView.vpnManager else {
            return "Not initialized"
        }
        switch manager.connection.status {
        case .invalid:        return "Invalid"
        case .disconnected:   return "Disconnected"
        case .connecting:     return "Connecting"
        case .connected:      return "Connected"
        case .reasserting:    return "Reasserting"
        case .disconnecting:  return "Disconnecting"
        @unknown default:     return "Unknown"
        }
    }

    private var certificateStatusText: String {
        let downloaded = UserDefaults.standard.bool(forKey: "certDownloaded")
        let installed = UserDefaults.standard.bool(forKey: "certInstalled")
        let trusted = UserDefaults.standard.bool(forKey: "certTrusted")
        if trusted { return "Trusted" }
        if installed { return "Installed, not trusted" }
        if downloaded { return "Downloaded, not installed" }
        return "Not configured"
    }

    private var currentLocationText: String {
        UserDefaults.standard.string(forKey: "currentLocationName") ?? "None"
    }

    private var currentCoordinatesText: String {
        guard let coords = LocationConfiguration.shared.currentCoordinates else {
            return "None"
        }
        return String(format: "%.6f, %.6f", coords.latitude, coords.longitude)
    }

    private var setupCompletedText: String {
        UserDefaults.standard.bool(forKey: "firstSetupCompleted") ? "Completed" : "Not completed"
    }

    private func copyDiagnostic() {
        let logBlock = diagLog.entries.isEmpty
            ? "(no logs)"
            : diagLog.entries.map { $0.formatted }.joined(separator: "\n")

        let info = """
        Location Spoofer Diagnostics
        ─────────────
        App version: \(appVersion)
        Build: \(buildNumber)
        VPN status: \(vpnStatusText)
        Certificate status: \(certificateStatusText)
        Current spoofed location: \(currentLocationText)
        Current coordinates: \(currentCoordinatesText)
        Initial setup: \(setupCompletedText)

        ─── Flow Logs ───
        \(logBlock)
        """
        UIPasteboard.general.string = info
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showCopiedToast = false
        }
    }

    /// 通过 IPC 从 Tunnel 拉取 Go 端日志缓冲(handleLocationRequest 的逐次追踪)。
    /// 收到的字符串按行拆开,逐行 DiagLog.add 前缀 [Go] 写进流程日志显示。
    private func queryGoLogsViaIPC() {
        guard let manager = ContentView.vpnManager,
              let session = manager.connection as? NETunnelProviderSession else {
            DiagLog.add("[Go Logs] session unavailable (manager nil or connection is not NETunnelProviderSession)")
            return
        }
        let request = Data("getLogs".utf8)
        do {
            try session.sendProviderMessage(request) { response in
                DispatchQueue.main.async {
                    guard let data = response, !data.isEmpty else {
                        DiagLog.add("[Go Logs] fetch returned empty (no new Go logs or tunnel not ready)")
                        return
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        DiagLog.add("[Go Logs] decode failed: \(data.count) bytes not UTF-8")
                        return
                    }
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                    DiagLog.add("[Go Logs] fetched \(lines.count) entries")
                    for line in lines {
                        DiagLog.add("[Go] \(line)")
                    }
                }
            }
        } catch {
            DiagLog.add("[Go Logs] sendProviderMessage error: \(error.localizedDescription)")
        }
    }

    // MARK: - 重置 App

    private func resetApp() {
        // 断开 VPN
        ContentView.vpnManager?.connection.stopVPNTunnel()
        // 清坐标
        LocationConfiguration.shared.clearCoordinates()
        // 清所有 UserDefaults key
        let keys = [
            "firstSetupCompleted",
            "certDownloaded", "certInstalled", "certTrusted",
            "currentLocationName", "savedLocations", "recentLocations"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // 清诊断日志
        DiagLog.shared.clear()
        dismiss()
    }
}
