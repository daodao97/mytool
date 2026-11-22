import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import MyScreenCore
import MyToolKit

struct ActivityItem: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var displays: [DisplayInfo] = []
    @Published var windows: [WindowRecord] = []
    @Published var profiles: [LayoutProfile] = []
    @Published var isTrusted = WindowService.isTrusted
    @Published var permissionNeedsAttention = false
    @Published var isTransitioning = true
    @Published var isBusy = false
    @Published var isWaitingForLayoutStability = false
    @Published var isAutomaticCaptureProtected = false
    @Published var isSessionSuspended = false
    @Published var notice = "正在检测显示器…"
    @Published var errorMessage: String?
    @Published var activities: [ActivityItem] = []
    @Published var leaderRegistrationFailed = false
    @Published var leader = KeyChord.leader
    @Published var isRecordingLeader = false
    @Published var isWindowModeActive = false
    @Published var recordingShortcut: WindowAction?
    @Published var bindings: [ShortcutBinding] = ShortcutBinding.defaults
    @Published var autoRemember: Bool {
        didSet { defaults.set(autoRemember, forKey: "autoRemember"); resetAutomaticCapture() }
    }
    @Published var autoRestore: Bool { didSet { defaults.set(autoRestore, forKey: "autoRestore") } }
    @Published var autoArrange: Bool {
        didSet {
            defaults.set(autoArrange, forKey: "autoArrange")
            if !autoArrange { cancelArrangementDrag() }
        }
    }
    @Published var autoTileWindows: Bool {
        didSet { defaults.set(autoTileWindows, forKey: "autoTileWindows"); cancelArrangementDrag() }
    }
    @Published var linkedResize: Bool {
        didSet { defaults.set(linkedResize, forKey: "linkedResize"); cancelArrangementDrag() }
    }
    @Published var shortcutsEnabled: Bool {
        didSet { defaults.set(shortcutsEnabled, forKey: "shortcutsEnabled"); registerShortcuts() }
    }
    private let defaults = ToolStorage.defaults("MyScreen")
    private let service = WindowService()
    private let hotKeys = HotKeyManager()
    private let windowMode = WindowModeController()
    private let sessionMonitor = SessionMonitor()
    private let dragMonitor = WindowDragMonitor()
    private let arrangementPreview = ArrangementPreviewController()
    private var arrangementOperation: WindowOperationToken?
    private var arrangementPointer: CGPoint?
    private var arrangementOptionHeld = false
    private var arrangementPreviewInFlight = false
    private var arrangementPreviewPending = false
    private var arrangementSelection: ArrangementSelection?
    private var observedResizeOnly = false
    private var observedResizeFinish: DispatchWorkItem?
    private var observedResizeRequestInFlight = false
    private var observedResizePending: AXUIElement?
    private var pendingModalAction: WindowAction?
    let store: LayoutStore
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var displayTransition = DisplayTransitionTracker()
    private var protectedLayouts: [String: LayoutProfile] = [:]
    private var lastStable: LayoutProfile?
    private var captureOperation: WindowOperationToken?
    private var restoreInProgress = false
    private var sessionRecoveryPending = false
    private var generation = 0
    private var captureNotBefore = Date.distantPast
    private var lastCaptureAt: TimeInterval = -.infinity
    private static let logFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var layoutStability = LayoutStabilityTracker()
    private var lastExternalPID: pid_t?
    private var currentOperation: WindowOperationToken?
    private struct BackgroundVerification {
        let operation: WindowOperationToken
        let activity: RecoveryActivityGuard
        let startedAt: TimeInterval
    }
    private var backgroundVerification: BackgroundVerification?
    private var backgroundWork: DispatchWorkItem?
    private var started = false
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, _, _ in
        Task { @MainActor in
            if AppModel.shared.started { AppModel.shared.screenConfigurationChanged(force: true) }
        }
    }

    var currentAutomaticProfile: LayoutProfile? {
        profiles.first { $0.isAutomatic && $0.topologyKey == DisplayInfo.topologyKey(displays) }
    }
    var automaticProfiles: [LayoutProfile] { profiles.filter(\.isAutomatic).sorted { $0.updatedAt > $1.updatedAt } }
    var namedProfiles: [LayoutProfile] { profiles.filter { !$0.isAutomatic }.sorted { $0.updatedAt > $1.updatedAt } }
    var externalDisplayCount: Int { displays.filter { !$0.isBuiltIn }.count }
    var rememberedDisplayCount: Int { Set(profiles.flatMap(\.displays).filter { !$0.isBuiltIn }.map(\.id)).count }
    var canOperate: Bool { isTrusted && !isBusy && !isTransitioning && sessionMonitor.isReady && !displays.isEmpty }
    var isRecordingAnyShortcut: Bool { isRecordingLeader || recordingShortcut != nil }

    private init() {
        autoRemember = defaults.object(forKey: "autoRemember") as? Bool ?? true
        autoRestore = defaults.object(forKey: "autoRestore") as? Bool ?? true
        autoArrange = defaults.object(forKey: "autoArrange") as? Bool ?? true
        autoTileWindows = defaults.object(forKey: "autoTileWindows") as? Bool ?? false
        linkedResize = defaults.object(forKey: "linkedResize") as? Bool ?? true
        shortcutsEnabled = defaults.object(forKey: "shortcutsEnabled") as? Bool ?? true
        store = LayoutStore(url: ToolStorage.directory("MyScreen").appendingPathComponent("layouts.json"))
        do {
            try store.load(); profiles = store.archive.profiles
            errorMessage = store.recoveryMessage
        } catch { errorMessage = "无法读取布局：\(error.localizedDescription)。原文件已保留，自动写入已停用。" }
        if let data = defaults.data(forKey: "modalLeader"),
           let saved = try? JSONDecoder().decode(KeyChord.self, from: data),
           saved.modifiers & UInt32(0x100 | 0x800 | 0x1000) != 0, !WindowModeState.isReserved(saved) { leader = saved }
        if let data = defaults.data(forKey: "modalShortcuts"),
           let saved = try? JSONDecoder().decode([ShortcutBinding].self, from: data),
           saved.count == WindowAction.allCases.count,
           Set(saved.map(\.action)).count == saved.count,
           saved.allSatisfy({ !WindowModeState.isReserved($0.chord) && $0.chord != leader }),
           Set(saved.map { "\($0.keyCode):\($0.modifiers)" }).count == saved.count {
            bindings = saved
        }
        hotKeys.onLeader = { [weak self] in self?.toggleWindowMode() }
        windowMode.onAction = { [weak self] action in self?.performModalAction(action) }
        windowMode.onStateChange = { [weak self] active in
            self?.isWindowModeActive = active
            if !active { self?.pendingModalAction = nil }
        }
        windowMode.onFailure = { [weak self] message in self?.report(message) }
    }

    func start() {
        guard !started else { return }; started = true
        displays = DisplayService.connected()
        sessionMonitor.onChange = { [weak self] change in self?.sessionAvailabilityChanged(change) }
        sessionMonitor.onEvent = { [weak self] event in self?.appendActivityLog("会话事件：\(event)") }
        sessionMonitor.start()
        dragMonitor.onBegin = { [weak self] point in self?.beginArrangementDrag(at: point) }
        dragMonitor.onChange = { [weak self] point, option in self?.updateArrangementDrag(at: point, optionHeld: option) }
        dragMonitor.onEnd = { [weak self] moved, point in self?.finishArrangementDrag(moved: moved, at: point) }
        dragMonitor.onEvent = { [weak self] event in self?.appendActivityLog(event) }
        service.onWindowResized = { [weak self] element in
            MainActor.assumeIsolated { self?.observedWindowResize(element) }
        }
        service.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.appendActivityLog(event) }
        }
        dragMonitor.start()
        rememberFrontmostApp()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rememberFrontmostApp() }
            }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPermission() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenConfigurationChanged() }
            })
        // Keep both the before and after callbacks for rapid reconnects.
        CGDisplayRegisterReconfigurationCallback(Self.displayCallback, nil)
        registerShortcuts()
        let permissionTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(permissionTimer, forMode: .common)
        timer = permissionTimer
        report("MyScreen 已启动，自动恢复\(autoRestore ? "开启" : "关闭")，辅助功能\(isTrusted ? "已授权" : "未授权")")
        screenConfigurationChanged(force: true)
    }
    func stop() {
        guard started else { return }
        started = false
        debounce?.cancel(); debounce = nil
        timer?.invalidate(); timer = nil
        cancelWindowWork()
        windowMode.stop(); hotKeys.unregister()
        dragMonitor.stop(); sessionMonitor.stop()
        CGDisplayRemoveReconfigurationCallback(Self.displayCallback, nil)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }
    private func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           app.activationPolicy == .regular { lastExternalPID = app.processIdentifier }
    }
    func refreshPermission(manual: Bool = false) {
        guard !sessionMonitor.isSuspended else { return }
        let trusted = WindowService.isTrusted
        // @Published notifies even when the value is unchanged. This check runs
        // every second, so only clear an actual warning to keep idle UI quiet.
        if trusted && permissionNeedsAttention { permissionNeedsAttention = false }
        if trusted != isTrusted {
            isTrusted = trusted
            if trusted {
                dragMonitor.stop(); dragMonitor.start()
                report("辅助功能权限已启用")
                screenConfigurationChanged(force: true)
            } else {
                cancelWindowWork()
                windowMode.stop()
                resetAutomaticCapture()
                windows = []
                report("辅助功能权限已关闭，窗口操作已暂停")
            }
        } else if manual && trusted {
            capture()
            report("权限已确认，正在重新检测窗口")
        }
        if manual && !trusted {
            permissionNeedsAttention = true
            report("系统尚未认可当前应用的授权；若已开启，请重启或移除旧条目后重新添加当前应用")
        }
    }
    private func tick() {
        sessionMonitor.poll()
        guard sessionMonitor.isReady else { return }
        dragMonitor.poll()
        if let watch = backgroundVerification { _ = backgroundIsCurrent(watch) }
        refreshPermission()
        let current = DisplayService.connected()
        if current != displays { screenConfigurationChanged(); return }
        // A full AX scan wakes every application. Poll quickly only while a changed layout
        // is waiting to settle; otherwise an idle desktop is rescanned every few seconds.
        let interval: TimeInterval = isWaitingForLayoutStability ? 1 : 3
        guard ProcessInfo.processInfo.systemUptime - lastCaptureAt >= interval - 0.1 else { return }
        capture()
    }
    func screenConfigurationChanged(force: Bool = false) {
        let connected = DisplayService.connected()
        let unchanged = connected == displays
        if !force && unchanged && (restoreInProgress || backgroundVerification != nil) { return }
        if !isTransitioning {
            do { try store.checkpoint() }
            catch { errorMessage = "无法备份显示器切换前的布局：\(error.localizedDescription)" }
            report("检测到显示器配置变化，暂停自动记忆并等待连接稳定")
        }
        displayTransition.begin(requiresRecovery: force, interruptingRecovery: restoreInProgress)
        cancelWindowWork()
        windowMode.leave()
        resetAutomaticCapture()
        isTransitioning = true
        displays = connected
        debounce?.cancel()
        guard !sessionMonitor.isSuspended else { return }
        let task = DispatchWorkItem { [weak self] in self?.finishDisplayTransition() }
        debounce = task
        let delay = sessionRecoveryPending && unchanged ? 0.2 : 1.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func finishDisplayTransition() {
        guard !sessionMonitor.isSuspended else { return }
        if !sessionMonitor.isReady {
            let task = DispatchWorkItem { [weak self] in self?.finishDisplayTransition() }
            debounce = task
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, sessionMonitor.readinessDelay), execute: task)
            return
        }
        if isBusy {
            let task = DispatchWorkItem { [weak self] in self?.finishDisplayTransition() }
            debounce = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
            return
        }
        let connected = DisplayService.connected()
        guard !connected.isEmpty else {
            screenConfigurationChanged(); return
        }
        guard connected == displays else { screenConfigurationChanged(); return }
        displays = connected
        let needsRecovery = displayTransition.finish(displays: connected)
        isTransitioning = false
        isAutomaticCaptureProtected = protectedLayouts[DisplayInfo.topologyKey(connected)] != nil
        guard needsRecovery else { return }
        report("显示器连接已稳定：\(topologyName(connected))")
        appendActivityLog("显示器标识：\(connected.map(\.id).joined(separator: " + "))")
        isTrusted = WindowService.isTrusted
        guard isTrusted else { notice = "开启辅助功能权限后，即可记忆和移动窗口"; return }
        if autoRestore, let saved = protectedLayouts[DisplayInfo.topologyKey(connected)] {
            restore(saved, reason: "桌面已就绪，恢复锁屏或切换前保留的布局")
            return
        }
        if autoRestore, let recovery = LayoutRecovery.resolve(displays: connected, profiles: profiles, previous: lastStable) {
            switch recovery {
            case .remembered(let saved):
                restore(saved, reason: "显示器组合已就绪，恢复已记忆布局")
            case .adapted(let previous):
                restore(previous, reason: "首次使用此屏幕组合，已将原有窗口适配到可用屏幕")
            }
            return
        }
        if sessionRecoveryPending {
            protectedLayouts.removeValue(forKey: DisplayInfo.topologyKey(connected))
            isAutomaticCaptureProtected = false
            sessionRecoveryPending = false
        }
        captureNotBefore = Date()
        capture()
        report("已识别 \(connected.count) 块显示器，开始记忆当前布局")
    }
    private func capture() {
        guard isTrusted, sessionMonitor.isReady, !isTransitioning, !isBusy, captureOperation == nil, backgroundVerification == nil,
              arrangementOperation == nil, Date() >= captureNotBefore, !displays.isEmpty else { return }
        let operation = WindowOperationToken(); captureOperation = operation
        lastCaptureAt = ProcessInfo.processInfo.systemUptime
        let screens = displays, token = generation
        let wasInteracting = NSEvent.pressedMouseButtons != 0
        service.scan(displays: screens, token: operation) { [weak self] scan in
            guard let self else { return }
            guard self.captureOperation === operation else { return }
            self.captureOperation = nil
            guard token == self.generation, !self.isTransitioning, !self.isBusy,
                  self.sessionMonitor.isReady, screens == DisplayService.connected() else { return }
            let records = scan.windows
            // @Published fires on every assignment; skip it so an unchanged scan does not redraw the UI.
            if self.windows != records { self.windows = records }
            let snapshot = LayoutProfile(name: self.topologyName(screens), isAutomatic: true,
                                         displays: screens, windows: records.sorted { $0.id < $1.id })
            let settled = self.layoutStability.observe(snapshot, at: ProcessInfo.processInfo.systemUptime,
                isComplete: scan.isComplete, isInteracting: wasInteracting || NSEvent.pressedMouseButtons != 0)
            let waiting = scan.isComplete && !records.isEmpty && settled == nil
            if self.isWaitingForLayoutStability != waiting { self.isWaitingForLayoutStability = waiting }
            guard scan.isComplete else {
                let message = "部分应用暂未响应，本次自动记忆已跳过，原有布局已保留"
                if self.notice != message { self.notice = message }
                return
            }
            // Only a stable snapshot may replace the last known layout used during unplugging.
            if let settled, !self.isAutomaticCaptureProtected {
                self.lastStable = settled
                if self.autoRemember && self.persistAutomatic(settled) {
                    self.report("布局已自动保存，包含 \(records.count) 个窗口")
                }
            }
        }
    }
    private func cancelWindowWork() {
        cancelArrangementDrag()
        cancelBackgroundVerification()
        generation += 1
        currentOperation?.cancel(); currentOperation = nil
        captureOperation?.cancel(); captureOperation = nil
        restoreInProgress = false
        isBusy = false
    }

    private func cancelArrangementDrag() {
        observedResizeFinish?.cancel(); observedResizeFinish = nil
        observedResizeOnly = false
        observedResizeRequestInFlight = false
        observedResizePending = nil
        arrangementPreview.hide()
        arrangementPointer = nil
        arrangementSelection = nil
        arrangementPreviewPending = false
        arrangementPreviewInFlight = false
        guard let operation = arrangementOperation else { return }
        operation.cancel()
        arrangementOperation = nil
        if currentOperation === operation {
            currentOperation = nil
            isBusy = false
        }
    }

    private func observedWindowResize(_ element: AXUIElement) {
        guard linkedResize, canOperate, !isRecordingAnyShortcut, !isAutomaticCaptureProtected,
              !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) else { return }
        if observedResizeRequestInFlight { observedResizePending = element; return }
        if arrangementOperation == nil {
            cancelBackgroundVerification()
            captureOperation?.cancel(); captureOperation = nil
            arrangementOperation = WindowOperationToken()
            observedResizeOnly = true
        }
        guard let operation = arrangementOperation else { return }
        observedResizeRequestInFlight = true
        service.observedWindowResize(element, displays: displays, token: operation) { [weak self] linked in
            guard let self, self.arrangementOperation === operation, !operation.isCancelled else { return }
            self.observedResizeRequestInFlight = false
            if self.observedResizeOnly {
                if linked { self.scheduleObservedResizeFinish(operation) }
                else { self.cancelArrangementDrag() }
            }
            if let pending = self.observedResizePending {
                self.observedResizePending = nil
                self.observedWindowResize(pending)
            }
        }
    }

    private func scheduleObservedResizeFinish(_ operation: WindowOperationToken) {
        observedResizeFinish?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.arrangementOperation === operation, !operation.isCancelled else { return }
            if CGEventSource.buttonState(.combinedSessionState, button: .left) {
                self.scheduleObservedResizeFinish(operation); return
            }
            self.isBusy = true
            self.currentOperation = operation
            self.resetAutomaticCapture()
            self.service.finishObservedResize(token: operation) { [weak self] message in
                guard let self, self.arrangementOperation === operation, !operation.isCancelled else { return }
                self.observedResizeOnly = false
                self.observedResizeFinish = nil
                self.arrangementOperation = nil
                self.currentOperation = nil
                self.isBusy = false
                self.captureNotBefore = Date().addingTimeInterval(0.5)
                if let message { self.report(message) }
                self.drainPendingModalAction()
            }
        }
        observedResizeFinish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func beginArrangementDrag(at point: CGPoint) {
        cancelArrangementDrag()
        guard autoArrange || linkedResize, canOperate, !isRecordingAnyShortcut, !isAutomaticCaptureProtected else { return }
        cancelBackgroundVerification()
        captureOperation?.cancel(); captureOperation = nil
        let operation = WindowOperationToken()
        arrangementOperation = operation
        service.beginArrangementDrag(at: point, linkedResize: linkedResize, displays: displays, token: operation)
    }

    private func updateArrangementDrag(at point: CGPoint, optionHeld: Bool) {
        guard arrangementOperation != nil, !isBusy else { return }
        arrangementPointer = point
        arrangementOptionHeld = optionHeld
        if optionHeld {
            arrangementSelection = nil
            arrangementPreviewPending = false
            arrangementPreview.hide()
        } else {
            arrangementPreviewPending = true
            requestArrangementPreview()
        }
    }

    private func requestArrangementPreview() {
        guard let operation = arrangementOperation, !operation.isCancelled,
              arrangementPreviewPending, !arrangementPreviewInFlight, !arrangementOptionHeld,
              let point = arrangementPointer, canOperate else { return }
        arrangementPreviewPending = false
        arrangementPreviewInFlight = true
        let screens = displays
        service.previewArrangementDrag(at: point, arrange: autoArrange, reflow: autoTileWindows, displays: screens, token: operation) { [weak self] preview in
            guard let self, self.arrangementOperation === operation, !operation.isCancelled else { return }
            guard !self.isBusy, self.canOperate, screens == DisplayService.connected(),
                  CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                self.arrangementPreviewInFlight = false
                self.arrangementPreview.hide()
                return
            }
            if let preview, !self.arrangementOptionHeld {
                self.arrangementSelection = ArrangementSelection(preview: preview, pointer: point)
                self.arrangementPreview.show(preview)
            } else {
                self.arrangementSelection = nil
                self.arrangementPreview.hide()
            }
            // Coalesce mouse events; never queue an AX query for every pixel of motion.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, self.arrangementOperation === operation, !self.isBusy else { return }
                self.arrangementPreviewInFlight = false
                self.arrangementPreviewPending = self.arrangementPointer != nil && !self.arrangementOptionHeld
                self.requestArrangementPreview()
            }
        }
    }

    private func finishArrangementDrag(moved: Bool, at point: CGPoint?) {
        arrangementPreview.hide()
        arrangementPreviewPending = false
        guard let operation = arrangementOperation else { return }
        if observedResizeOnly {
            if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { cancelArrangementDrag() }
            else { scheduleObservedResizeFinish(operation) }
            return
        }
        guard moved, let point, autoArrange || linkedResize, canOperate, !isRecordingAnyShortcut, !isAutomaticCaptureProtected else {
            cancelArrangementDrag(); return
        }
        captureOperation?.cancel(); captureOperation = nil
        resetAutomaticCapture()
        generation += 1
        let token = generation, screens = displays
        let selection = arrangementSelection
        appendActivityLog("拖动结束：\(selection?.preview.title ?? "根据最终位置排版")")
        currentOperation = operation
        isBusy = true
        // Give the application its mouse-up before inspecting the final geometry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.currentOperation === operation, !operation.isCancelled else { return }
            guard self.sessionMonitor.isReady, screens == DisplayService.connected() else {
                self.cancelArrangementDrag(); return
            }
            self.service.finishArrangementDrag(at: point, selection: selection, arrange: self.autoArrange, reflow: self.autoTileWindows, displays: screens, token: operation) { [weak self] message in
                guard let self, token == self.generation, self.currentOperation === operation else { return }
                self.arrangementOperation = nil
                self.currentOperation = nil
                self.isBusy = false
                self.captureNotBefore = Date().addingTimeInterval(0.5)
                if let message { self.report(message) }
                self.drainPendingModalAction()
            }
        }
    }

    private func sessionAvailabilityChanged(_ change: SessionChange) {
        isSessionSuspended = change == .paused
        if change == .paused {
            do { try store.checkpoint() }
            catch { errorMessage = "无法备份锁屏或休眠前的布局：\(error.localizedDescription)" }
            let key = DisplayInfo.topologyKey(displays)
            if protectedLayouts[key] == nil, let saved = currentAutomaticProfile { protectedLayouts[key] = saved }
            isAutomaticCaptureProtected = protectedLayouts[key] != nil
            sessionRecoveryPending = true
            displayTransition.begin(requiresRecovery: true)
            cancelWindowWork()
            debounce?.cancel(); debounce = nil
            windowMode.leave()
            resetAutomaticCapture()
            isTransitioning = true
            report("已锁屏、休眠或切换用户，暂停窗口操作和自动记忆，保留原布局")
        } else {
            sessionRecoveryPending = true
            report("已解锁或唤醒，等待桌面和显示器就绪后恢复布局")
            screenConfigurationChanged(force: true)
        }
    }
    private func resetAutomaticCapture() {
        layoutStability.reset()
        if isWaitingForLayoutStability { isWaitingForLayoutStability = false }
    }
    private func persistAutomatic(_ snapshot: LayoutProfile) -> Bool {
        var next = profiles
        if let index = next.firstIndex(where: { $0.isAutomatic && $0.topologyKey == snapshot.topologyKey }) {
            if next[index].displays == snapshot.displays && next[index].windows == snapshot.windows { return false }
            var updated = snapshot; updated.id = next[index].id
            next[index] = updated
        } else { next.append(snapshot) }
        return persist(next)
    }
    @discardableResult private func persist(_ next: [LayoutProfile]) -> Bool {
        do { try store.replace(next); profiles = store.archive.profiles; return true }
        catch { errorMessage = "保存布局失败：\(error.localizedDescription)"; return false }
    }
    func saveNamedLayout(name: String) {
        guard canOperate else { requirePermissionIfNeeded(); return }
        cancelArrangementDrag()
        cancelBackgroundVerification()
        isBusy = true; generation += 1
        let token = generation, screens = displays
        service.scan(displays: screens) { [weak self] scan in
            guard let self, token == self.generation else { return }; self.isBusy = false
            defer { self.drainPendingModalAction() }
            guard token == self.generation, screens == DisplayService.connected() else {
                self.report("显示器正在变化，请稍后重新保存"); return
            }
            guard scan.isComplete else { self.report("部分应用暂未响应，已取消保存，请稍后重试"); return }
            let records = scan.windows
            guard !records.isEmpty else { self.report("没有可保存的普通窗口，请先打开其他应用的窗口"); return }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = LayoutProfile(name: clean.isEmpty ? "我的布局" : clean, isAutomatic: false,
                                        displays: screens, windows: records)
            guard self.persist(self.profiles + [profile]) else { return }
            self.windows = records
            self.report("已保存「\(profile.name)」，包含 \(records.count) 个窗口")
        }
    }
    func restore(_ profile: LayoutProfile, reason: String? = nil, monitorLateChanges: Bool = true) {
        guard canOperate else { requirePermissionIfNeeded(); return }
        cancelArrangementDrag()
        cancelBackgroundVerification()
        resetAutomaticCapture()
        isBusy = true; generation += 1
        let screens = displays, token = generation
        let operation = WindowOperationToken(); currentOperation = operation
        restoreInProgress = true
        protectedLayouts[DisplayInfo.topologyKey(screens)] = profile
        isAutomaticCaptureProtected = true
        report(reason ?? "正在恢复布局，完成后将复核窗口位置")
        appendActivityLog("恢复目标：\(profile.windows.count) 个窗口，外屏 \(profile.windows.filter { window in profile.displays.contains { $0.id == window.displayID && !$0.isBuiltIn } }.count) 个")
        restoreAttempt(profile, screens: screens, generation: token, operation: operation, attempt: 0,
                       startedAt: ProcessInfo.processInfo.systemUptime, monitorLateChanges: monitorLateChanges)
    }

    private func restoreAttempt(_ profile: LayoutProfile, screens: [DisplayInfo], generation token: Int,
                                operation: WindowOperationToken, attempt: Int, startedAt: TimeInterval, monitorLateChanges: Bool) {
        guard restoreIsCurrent(screens: screens, generation: token, operation: operation) else { return }
        service.restore(profile, displays: screens, token: operation, recordUndo: attempt == 0) { [weak self] result in
            guard let self, self.restoreIsCurrent(screens: screens, generation: token, operation: operation) else { return }
            let resolvedProfile = result.resolvedProfile ?? profile
            self.protectedLayouts[DisplayInfo.topologyKey(screens)] = resolvedProfile
            self.appendActivityLog(String(format: "恢复应用第 %d 次：移动 %d，已在位 %d，尺寸受限 %d，累计 %.3f 秒",
                attempt + 1, result.moved, result.unchanged, result.limited, ProcessInfo.processInfo.systemUptime - startedAt))
            // Do not trust immediate AX success: WindowServer may move the window again.
            let delays = [0.25, 0.75, 2.0, 4.0]
            DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
                guard let self, self.restoreIsCurrent(screens: screens, generation: token, operation: operation) else { return }
                self.service.scan(displays: screens, token: operation) { [weak self] scan in
                    guard let self, self.restoreIsCurrent(screens: screens, generation: token, operation: operation) else { return }
                    self.windows = scan.windows
                    let check = LayoutRestoreVerification(profile: resolvedProfile, displays: screens, live: scan.windows,
                                                          isComplete: scan.isComplete, constrainedFrames: result.constrainedFrames)
                    // A successful first check releases the UI immediately. Reapply only
                    // on failure; delayed WindowServer changes are checked separately.
                    if attempt < 3 && !check.canResumeAutomaticCapture {
                        self.report("布局恢复复核 \(attempt + 1)/4：匹配 \(check.matchedCount) 个，位置待恢复 \(check.misplacedCount) 个，待匹配 \(check.unresolvedCount) 个，未打开或不可访问 \(check.missingCount - check.unresolvedCount) 个")
                        self.restoreAttempt(resolvedProfile, screens: screens, generation: token, operation: operation,
                                            attempt: attempt + 1, startedAt: startedAt, monitorLateChanges: monitorLateChanges)
                        return
                    }
                    self.isBusy = false
                    self.currentOperation = nil
                    self.restoreInProgress = false
                    if check.canResumeAutomaticCapture {
                        self.protectedLayouts.removeValue(forKey: DisplayInfo.topologyKey(screens))
                        self.isAutomaticCaptureProtected = false
                        self.sessionRecoveryPending = false
                        self.captureNotBefore = Date().addingTimeInterval(0.5)
                        self.resetAutomaticCapture()
                        let limits = result.limited > 0 ? "，\(result.limited) 个窗口尺寸受应用限制" : ""
                        let unavailable = check.missingCount > 0 ? "，跳过 \(check.missingCount) 个未打开或不可访问的窗口" : ""
                        self.report("布局恢复已复核：\(check.matchedCount) 个窗口位置已确认\(limits)\(unavailable)")
                        self.appendActivityLog(String(format: "恢复前台完成：%.3f 秒", ProcessInfo.processInfo.systemUptime - startedAt))
                        if monitorLateChanges {
                            self.beginBackgroundVerification(resolvedProfile, screens: screens, generation: token,
                                                             constrainedFrames: result.constrainedFrames)
                        }
                    } else {
                        self.appendActivityLog("恢复未通过复核：匹配 \(check.matchedCount)，位置不符 \(check.misplacedCount)，缺失 \(check.missingCount)，待匹配 \(check.unresolvedCount)，扫描完整 \(check.isComplete)")
                        self.report("布局尚未恢复完成，已保护原布局并暂停自动记忆；可重新恢复，或确认后记住当前位置")
                    }
                    self.drainPendingModalAction()
                }
            }
        }
    }

    private func inputActivityCounters() -> [UInt32] {
        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
                                     .otherMouseDown, .otherMouseDragged, .keyDown, .flagsChanged, .scrollWheel]
        return events.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) }
    }

    private func cancelBackgroundVerification() {
        guard let watch = backgroundVerification else { return }
        watch.operation.cancel()
        backgroundWork?.cancel(); backgroundWork = nil
        backgroundVerification = nil
        resetAutomaticCapture()
    }

    private func backgroundIsCurrent(_ watch: BackgroundVerification) -> Bool {
        guard backgroundVerification?.operation === watch.operation else { return false }
        guard !watch.operation.isCancelled, sessionMonitor.isReady,
              watch.activity.permitsRecovery(generation: generation, counters: inputActivityCounters(),
                                             isDragging: NSEvent.pressedMouseButtons != 0) else {
            cancelBackgroundVerification()
            appendActivityLog("已开始新操作或会话已变化，停止后台位置复核")
            return false
        }
        return true
    }

    private func beginBackgroundVerification(_ profile: LayoutProfile, screens: [DisplayInfo], generation token: Int,
                                              constrainedFrames: [String: Rect]) {
        let watch = BackgroundVerification(operation: WindowOperationToken(),
            activity: RecoveryActivityGuard(generation: token, counters: inputActivityCounters()),
            startedAt: ProcessInfo.processInfo.systemUptime)
        backgroundVerification = watch
        scheduleBackgroundVerification(profile, screens: screens, watch: watch, constrainedFrames: constrainedFrames, index: 0)
    }

    private func scheduleBackgroundVerification(_ profile: LayoutProfile, screens: [DisplayInfo], watch: BackgroundVerification,
                                                 constrainedFrames: [String: Rect], index: Int) {
        let offsets: [TimeInterval] = [1, 3, 8]
        let delay = max(0, watch.startedAt + offsets[index] - ProcessInfo.processInfo.systemUptime)
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.backgroundIsCurrent(watch) else { return }
            guard screens == DisplayService.connected() else {
                self.screenConfigurationChanged(force: true); return
            }
            self.service.scan(displays: screens, token: watch.operation) { [weak self] scan in
                guard let self, self.backgroundIsCurrent(watch) else { return }
                guard screens == DisplayService.connected() else {
                    self.screenConfigurationChanged(force: true); return
                }
                let check = LayoutRestoreVerification(profile: profile, displays: screens, live: scan.windows,
                                                      isComplete: scan.isComplete, constrainedFrames: constrainedFrames)
                if !check.canResumeAutomaticCapture {
                    self.cancelBackgroundVerification()
                    self.restore(profile, reason: "系统再次调整了窗口，正在补回布局", monitorLateChanges: false)
                } else if index + 1 < offsets.count {
                    self.scheduleBackgroundVerification(profile, screens: screens, watch: watch,
                                                        constrainedFrames: constrainedFrames, index: index + 1)
                } else {
                    self.cancelBackgroundVerification()
                    self.appendActivityLog("后台位置复核完成，无需再次移动窗口")
                }
            }
        }
        backgroundWork = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func retryRecovery() {
        if let profile = protectedLayouts[DisplayInfo.topologyKey(displays)] ?? currentAutomaticProfile { restore(profile) }
    }

    private func restoreIsCurrent(screens: [DisplayInfo], generation token: Int, operation: WindowOperationToken) -> Bool {
        guard token == generation, !operation.isCancelled, sessionMonitor.isReady, screens == DisplayService.connected() else {
            // No later operation can start while busy. Release it so the pending display
            // transition (or permission refresh) can proceed; stale work never resumes capture.
            if currentOperation === operation {
                currentOperation = nil
                isBusy = false
                restoreInProgress = false
            }
            return false
        }
        return true
    }

    func rememberCurrentLayout() {
        guard canOperate else { requirePermissionIfNeeded(); return }
        cancelArrangementDrag()
        cancelBackgroundVerification()
        isBusy = true; generation += 1
        let screens = displays, token = generation
        service.scan(displays: screens) { [weak self] scan in
            guard let self, token == self.generation else { return }; self.isBusy = false
            guard token == self.generation, screens == DisplayService.connected(), scan.isComplete, !scan.windows.isEmpty else {
                self.report("窗口或显示器尚未就绪，已保留原布局"); return
            }
            let snapshot = LayoutProfile(name: self.topologyName(screens), isAutomatic: true, displays: screens, windows: scan.windows)
            // An explicit choice is the only way to replace a layout whose recovery failed.
            if self.persistAutomatic(snapshot) || self.currentAutomaticProfile?.windows == snapshot.windows {
                self.protectedLayouts.removeValue(forKey: snapshot.topologyKey)
                self.isAutomaticCaptureProtected = false
                self.sessionRecoveryPending = false
                self.lastStable = snapshot
                self.resetAutomaticCapture()
                self.report("已将当前位置记为此显示器组合的布局")
            }
        }
    }
    func perform(_ action: WindowAction, windowID: String? = nil) {
        guard !isRecordingAnyShortcut else { return }
        if action == .saveLayout {
            saveNamedLayout(name: "布局 · " + Date().formatted(date: .abbreviated, time: .shortened)); return
        }
        if action == .restoreLayout {
            if let profile = currentAutomaticProfile { restore(profile) }
            else { report("此屏幕组合还没有记忆布局，请先保存一次") }
            return
        }
        guard canOperate else { requirePermissionIfNeeded(); return }
        cancelArrangementDrag()
        cancelBackgroundVerification()
        rememberFrontmostApp()
        resetAutomaticCapture()
        isBusy = true; generation += 1
        let operation = WindowOperationToken(); currentOperation = operation
        let token = generation
        service.perform(action, pid: lastExternalPID, windowID: windowID, displays: displays, token: operation) { [weak self] message in
            guard let self, token == self.generation, self.currentOperation === operation else { return }
            self.isBusy = false; self.currentOperation = nil
            defer { self.drainPendingModalAction() }
            self.captureNotBefore = Date().addingTimeInterval(1)
            self.report(message)
        }
    }
    func tileWindows(_ layout: WindowTileLayout = .automatic, displayID: String? = nil) {
        guard canOperate, !isRecordingAnyShortcut else { requirePermissionIfNeeded(); return }
        cancelArrangementDrag()
        cancelBackgroundVerification()
        captureOperation?.cancel(); captureOperation = nil
        resetAutomaticCapture()
        rememberFrontmostApp()
        isBusy = true; generation += 1
        let operation = WindowOperationToken(); currentOperation = operation
        let token = generation
        service.tileWindows(layout, displayID: displayID, pid: lastExternalPID, displays: displays, token: operation) { [weak self] message in
            guard let self, token == self.generation, self.currentOperation === operation else { return }
            self.currentOperation = nil; self.isBusy = false
            self.captureNotBefore = Date().addingTimeInterval(0.5)
            self.report(message)
            self.drainPendingModalAction()
        }
    }
    func deleteProfile(_ profile: LayoutProfile) {
        guard persist(profiles.filter { $0.id != profile.id }) else { return }
        report("已删除「\(profile.name)」")
    }
    func renameProfile(_ profile: LayoutProfile, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var next = profiles; next[index].name = clean; persist(next)
    }
    func requestPermission() {
        WindowService.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func restartApplication() { MyScreenModule.current?.host.restart() }
    private func requirePermissionIfNeeded() {
        if !WindowService.isTrusted { requestPermission() }
        else if isTransitioning { report("正在等待显示器连接稳定，请稍候") }
        else if isBusy { report("正在处理上一次窗口操作，请稍候") }
    }
    func beginRecording(_ action: WindowAction) {
        windowMode.stop()
        isRecordingLeader = false
        recordingShortcut = action; hotKeys.unregister()
    }
    func beginRecordingLeader() {
        windowMode.stop()
        recordingShortcut = nil
        isRecordingLeader = true
        hotKeys.unregister()
    }
    func finishRecording(keyCode: UInt32?, modifiers: UInt32 = 0) {
        guard isRecordingAnyShortcut else { return }
        let action = recordingShortcut, recordingLeader = isRecordingLeader
        defer { recordingShortcut = nil; isRecordingLeader = false; registerShortcuts() }
        guard let keyCode else { return }
        let chord = KeyChord(keyCode: keyCode, modifiers: modifiers)
        guard !WindowModeState.isReserved(chord) else { report("Esc / Q 用于退出，Tab 用于查看提示，请选择其他按键"); return }
        if recordingLeader {
            guard modifiers & UInt32(0x100 | 0x800 | 0x1000) != 0 else {
                report("Leader 至少需要包含 ⌘、⌃、⌥ 其中一个修饰键"); return
            }
            guard !bindings.contains(where: { $0.chord == chord }) else { report("此组合已用于模式内操作，请选择其他 leader"); return }
            leader = chord
            if let data = try? JSONEncoder().encode(leader) { defaults.set(data, forKey: "modalLeader") }
            report("Leader 已更新为 \(leader.label)")
            return
        }
        guard let action else { return }
        guard chord != leader else { report("此组合已用于进入窗口模式，请选择其他按键"); return }
        guard !bindings.contains(where: { $0.action != action && $0.keyCode == keyCode && $0.modifiers == modifiers }) else {
            report("此快捷键已用于其他操作，请换一个组合"); return
        }
        if let index = bindings.firstIndex(where: { $0.action == action }) {
            bindings[index] = ShortcutBinding(action: action, keyCode: keyCode, modifiers: modifiers)
            saveBindings(); report("已更新「\(action.title)」的快捷键")
        }
    }
    func resetShortcuts() {
        windowMode.stop(); recordingShortcut = nil; isRecordingLeader = false
        leader = .leader; defaults.removeObject(forKey: "modalLeader")
        bindings = ShortcutBinding.defaults; saveBindings(); registerShortcuts()
    }
    private func saveBindings() { if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: "modalShortcuts") } }
    private func registerShortcuts() {
        windowMode.stop()
        leaderRegistrationFailed = !hotKeys.register(leader, enabled: shortcutsEnabled && !isRecordingAnyShortcut)
    }
    func toggleWindowMode() {
        cancelArrangementDrag()
        if isWindowModeActive { windowMode.leave(); report("已退出窗口模式"); return }
        guard shortcutsEnabled, !isRecordingAnyShortcut else { return }
        guard canOperate else { requirePermissionIfNeeded(); return }
        rememberFrontmostApp()
        if windowMode.enter(bindings: bindings, leader: leader) { report("已进入窗口模式，按功能键操作，Esc / Q 退出，Tab 查看提示") }
        else { report("无法开启窗口模式的键盘监听，请确认辅助功能权限已生效，并退出安全输入状态后重试") }
    }
    private func performModalAction(_ action: WindowAction) {
        guard isWindowModeActive else { return }
        if isBusy { pendingModalAction = action; return }
        perform(action)
    }
    private func drainPendingModalAction() {
        guard isWindowModeActive, canOperate, let action = pendingModalAction else { return }
        pendingModalAction = nil
        performModalAction(action)
    }
    func revealData() { NSWorkspace.shared.selectFile(store.url.path, inFileViewerRootedAtPath: "") }
    func report(_ message: String) {
        notice = message
        activities.insert(ActivityItem(message: message), at: 0)
        if activities.count > 8 { activities.removeLast() }
        appendActivityLog(message)
    }
    private func appendActivityLog(_ message: String) {
        let url = store.url.deletingLastPathComponent().appendingPathComponent("events.log")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 262_144 {
                let previous = url.appendingPathExtension("previous")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data("\(Self.logFormatter.string(from: Date())) \(message)\n".utf8))
        } catch {
            // Diagnostics must never prevent a window operation or layout save.
        }
    }
    private func topologyName(_ screens: [DisplayInfo]) -> String {
        screens.map { $0.isBuiltIn ? "内置显示器" : $0.name }.joined(separator: " + ")
    }
}
