import SwiftUI
import NetworkExtension

/// 首次配置的 3 步(对外仍是 3 步,证书内部拆成"下载"和"安装"两屏)
enum SetupStep: Int, CaseIterable {
    case welcome = 0  // 欢迎页
    case vpn = 1      // 步骤 1:VPN 权限
    case cert = 2     // 步骤 2a:下载证书(唤起 Safari)
    case install = 3  // 步骤 2b:安装描述文件
    case trust = 4    // 步骤 3:证书信任
    case done = 5     // 完成页

    /// 进度条:welcome 和 done 不显示;.cert 和 .install 合并算步骤 2,.trust 算步骤 3。
    var progressIndex: Int? {
        switch self {
        case .welcome, .done: return nil
        case .vpn: return 1
        case .cert, .install: return 2
        case .trust: return 3
        }
    }

    var title: String {
        switch self {
        case .welcome: return ""
        case .vpn: return "Allow VPN"
        case .cert: return "Download Certificate"
        case .install: return "Install Profile"
        case .trust: return "Trust Certificate"
        case .done: return ""
        }
    }

    /// The step the Back button returns to; nil where going back makes no sense.
    var previous: SetupStep? {
        switch self {
        case .welcome, .vpn, .done: return nil
        case .cert: return .vpn
        case .install: return .cert
        case .trust: return .install
        }
    }
}

/// Numbered instructions, each read by VoiceOver as "Step N: …",
/// shared by setup and the Location Services restart guides.
struct NumberedSteps: View {
    let steps: [String]
    /// Zero-based indices to emphasise (e.g. "Wait 3 seconds").
    var emphasized: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Circle().fill(Color.accentColor))
                        .accessibilityHidden(true)
                    Text(step)
                        .fontWeight(emphasized.contains(index) ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1): \(step)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-width primary action used across onboarding and sheets.
struct PrimaryButton: View {
    let title: String
    var isBusy = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView() }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
    }
}

struct FirstSetupView: View {
    @State private var currentStep: SetupStep = .welcome
    @State private var errorMessage: String? = nil
    @State private var isProcessing: Bool = false
    @State private var showInstallConfirm: Bool = false
    @State private var showTrustConfirm: Bool = false

    private var showError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    var body: some View {
        ZStack {
            switch currentStep {
            case .welcome:
                welcomeView
                    .transition(.opacity)
            case .vpn, .cert, .install, .trust:
                progressView
                    .transition(.opacity)
            case .done:
                doneView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentStep)
        .sensoryFeedback(.success, trigger: currentStep) { _, new in new == .done }
        .alert("Something Went Wrong", isPresented: showError, presenting: errorMessage) { _ in
            Button("OK") { }
        } message: { msg in
            Text(msg)
        }
        .alert("Profile Installed?", isPresented: $showInstallConfirm) {
            Button("Yes, Continue") { currentStep = .trust }
            Button("Not Yet", role: .cancel) { }
        } message: {
            Text("Make sure the profile shows under Settings > General > VPN & Device Management before continuing.")
        }
        .alert("Certificate Trusted?", isPresented: $showTrustConfirm) {
            Button("Yes, Continue") { confirmTrust() }
            Button("Not Yet", role: .cancel) { }
        } message: {
            Text("Make sure the Location Spoofer CA switch is on in Settings > General > About > Certificate Trust Settings. Spoofing will not work without it.")
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "location.fill.viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
                .padding(.bottom, 8)

            Text("Welcome to Location Spoofer")
                .font(.largeTitle.bold())

            Text("Three quick steps, then change your location with one tap.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()

            PrimaryButton(title: "Start Setup") { currentStep = .vpn }

            Text("Setup asks for VPN permission and installs a certificate. Both stay on this device and are needed to change your location.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    // MARK: - Steps (vpn / cert / install / trust)

    private var progressView: some View {
        VStack(spacing: 24) {
            HStack {
                if let previous = currentStep.previous {
                    Button {
                        currentStep = previous
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(isProcessing)
                }
                Spacer()
            }
            .frame(minHeight: 44)

            progressIndicator

            Text(currentStep.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            ScrollView {
                stepInstruction
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            stepActionButton
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { idx in
                Circle()
                    .fill(progressColor(at: idx))
                    .frame(width: 12, height: 12)
                if idx < 3 {
                    Capsule()
                        .fill(progressColor(at: idx + 1))
                        .frame(width: 40, height: 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentStep.progressIndex ?? 0) of 3")
    }

    private func progressColor(at index: Int) -> Color {
        guard let current = currentStep.progressIndex, index <= current else {
            return Color(uiColor: .systemFill)
        }
        return .accentColor
    }

    @ViewBuilder
    private var stepInstruction: some View {
        switch currentStep {
        case .vpn:
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Location Spoofer uses an on-device VPN to adjust location lookups. Tap Allow in the system prompt and enter your passcode.")
                    .multilineTextAlignment(.center)
            }
        case .cert:
            VStack(spacing: 12) {
                Text("Tap the button below. Safari will open and ask to download a configuration profile. Tap Allow.")
                    .multilineTextAlignment(.center)
                Text("If Safari says the profile already exists, it's already downloaded. Come back here and continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .install:
            VStack(alignment: .leading, spacing: 16) {
                Text("Now install the downloaded profile:")
                NumberedSteps(steps: [
                    "Open the Settings app",
                    "Tap Profile Downloaded near the top",
                    "Tap Install and enter your passcode",
                    "Return to this app",
                ])
            }
        case .trust:
            VStack(alignment: .leading, spacing: 16) {
                Text("iOS requires you to trust the certificate manually:")
                NumberedSteps(steps: [
                    "Open the Settings app",
                    "Go to General > About",
                    "Scroll down and tap Certificate Trust Settings",
                    "Turn on Location Spoofer CA",
                    "Tap Continue, then return to this app",
                ])
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stepActionButton: some View {
        switch currentStep {
        case .vpn:
            PrimaryButton(title: isProcessing ? "Connecting…" : "Allow VPN", isBusy: isProcessing) {
                triggerVPNSetup()
            }
        case .cert:
            PrimaryButton(title: isProcessing ? "Opening Safari…" : "Download Certificate", isBusy: isProcessing) {
                triggerCertInstall()
            }
        case .install:
            PrimaryButton(title: "I've Installed the Profile") { showInstallConfirm = true }
        case .trust:
            PrimaryButton(title: "I've Trusted the Certificate") { showTrustConfirm = true }
        default:
            EmptyView()
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
                .padding(.bottom, 8)
            Text("You're All Set")
                .font(.largeTitle.bold())
            Text("Pick any place on the map to use it as your location.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
            PrimaryButton(title: "Get Started") { completeSetup() }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    // MARK: - 占位:D2/D3 实现

    private func triggerVPNSetup() {
        isProcessing = true

        if let manager = ContentView.vpnManager {
            startTunnelAndAdvance(manager: manager)
        } else {
            // 首次:vpnManager 还没就绪,当场安装配置再启动
            ContentView.installAndStartVPN { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let manager):
                        startTunnelAndAdvance(manager: manager)
                    case .failure(let error):
                        isProcessing = false
                        errorMessage = "VPN configuration installation failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// 启动 VPN tunnel,3 秒后检查连接状态,连上就推进到 .cert,否则报超时。
    private func startTunnelAndAdvance(manager: NETunnelProviderManager) {
        do {
            try manager.connection.startVPNTunnel()
            // 等待 3 秒看是否真的连上
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                isProcessing = false
                if manager.connection.status == .connected {
                    currentStep = .cert
                } else {
                    errorMessage = "VPN connection timed out. Please try again or check your network."
                }
            }
        } catch {
            isProcessing = false
            errorMessage = "Failed to start VPN: \(error.localizedDescription)"
        }
    }

    private func triggerCertInstall() {
        isProcessing = true

        CertificateInstaller.installCertificate { success, errMsg in
            DispatchQueue.main.async {
                isProcessing = false
                if success {
                    // Safari 已唤起,等用户从 Safari 回来后,先到"安装描述文件"步骤
                    UserDefaults.standard.set(true, forKey: "certDownloaded")
                    currentStep = .install
                } else {
                    errorMessage = errMsg ?? "Failed to launch certificate installation"
                }
            }
        }
    }

    private func confirmTrust() {
        // 手动确认信任(iOS 没有完美的"检测证书是否被信任"API)
        UserDefaults.standard.set(true, forKey: "certInstalled")
        UserDefaults.standard.set(true, forKey: "certTrusted")
        currentStep = .done
    }

    private func completeSetup() {
        UserDefaults.standard.set(true, forKey: "firstSetupCompleted")
        UserDefaults.standard.set(true, forKey: "certDownloaded")
        UserDefaults.standard.set(true, forKey: "certInstalled")
        UserDefaults.standard.set(true, forKey: "certTrusted")
    }
}
