import AppKit
import Combine
import ServiceManagement

@MainActor
final class HostPreferences: ObservableObject {
    private let defaults: UserDefaults
    private var appearanceUpdatePending = false
    @Published var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            scheduleAppearanceUpdate()
        }
    }
    @Published var showDockIcon: Bool {
        didSet {
            guard showDockIcon != oldValue else { return }
            defaults.set(showDockIcon, forKey: "showDockIcon")
            scheduleAppearanceUpdate()
        }
    }
    @Published private(set) var loginEnabled = false
    @Published var error: String?
    var applyAppearance: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? true
        refreshLogin()
    }

    private func scheduleAppearanceUpdate() {
        guard !appearanceUpdatePending else { return }
        appearanceUpdatePending = true
        // Changing activation policy can run a nested AppKit event loop. Wait until
        // the SwiftUI binding setter and the switch's tracking have returned.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appearanceUpdatePending = false
                self.applyAppearance?()
            }
        }
    }

    func refreshLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = "设置登录启动失败：\(error.localizedDescription)" }
        refreshLogin()
    }
}
