import AppKit
import Foundation

@MainActor
final class AXEventHandler: CGSEventDelegate {
    weak var controller: WMController?
    private var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
    var axWindowRefProvider: ((UInt32, pid_t) -> AXWindowRef?)?
    var windowSubscriptionHandler: (([UInt32]) -> Void)?
    var focusedWindowValueProvider: ((pid_t) -> CFTypeRef?)?
    var windowTypeProvider: ((AXWindowRef, pid_t) -> AXWindowType)?

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        CGSEventObserver.shared.delegate = self
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        CGSEventObserver.shared.delegate = nil
        CGSEventObserver.shared.stop()
    }

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, _):
            handleCGSWindowCreated(windowId: windowId)

        case let .destroyed(windowId, _):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            handleCGSWindowDestroyed(windowId: windowId)

        case let .moved(windowId):
            handleWindowMoveOrResize(windowId: windowId)
            if !isWindowHidden(windowId: windowId) {
                controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
            }

        case let .resized(windowId):
            handleWindowMoveOrResize(windowId: windowId)
            if !isWindowHidden(windowId: windowId) {
                controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged)
            }

        case let .frontAppChanged(pid):
            handleAppActivation(pid: pid)

        case .titleChanged:
            controller.updateWorkspaceBar()
        }
    }

    private func isWindowHidden(windowId: UInt32) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(forWindowId: Int(windowId)) else {
            return false
        }
        return controller.workspaceManager.isHiddenInCorner(entry.handle)
    }

    private func handleCGSWindowCreated(windowId: UInt32) {
        guard let controller else { return }

        if controller.isDiscoveryInProgress {
            deferCreatedWindow(windowId)
            return
        }

        if controller.workspaceManager.entry(forWindowId: Int(windowId)) != nil {
            return
        }

        guard let windowInfo = resolveWindowInfo(windowId) else {
            return
        }

        let pid = windowInfo.pid
        subscribeToWindows([windowId])

        if let axRef = resolveAXWindowRef(windowId: windowId, pid: pid) {
            handleCreated(ref: axRef, pid: pid, winId: Int(windowId))
        }
    }

    private func handleWindowMoveOrResize(windowId: UInt32) {
        guard let controller else { return }
        guard let focusedHandle = controller.workspaceManager.focusedHandle,
              let entry = controller.workspaceManager.entry(for: focusedHandle),
              entry.windowId == Int(windowId)
        else { return }

        if let frame = try? AXWindowService.frame(entry.axRef) {
            controller.borderCoordinator.updateBorderIfAllowed(handle: focusedHandle, frame: frame, windowId: Int(windowId))
        }
    }

    private func handleCGSWindowDestroyed(windowId: UInt32) {
        guard let controller else { return }
        removeDeferredCreatedWindow(windowId)
        guard let entry = controller.workspaceManager.entry(
            forWindowId: Int(windowId),
            inVisibleWorkspaces: true
        ) else {
            return
        }

        handleRemoved(pid: entry.handle.pid, winId: Int(windowId))
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        subscribeToWindows(windowIds)
    }

    func drainDeferredCreatedWindows() async {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        deferredCreatedWindowOrder.removeAll()
        deferredCreatedWindowIds.removeAll()

        for windowId in deferredWindowIds {
            guard let controller else { return }
            if controller.workspaceManager.entry(forWindowId: Int(windowId)) != nil {
                continue
            }
            guard let windowInfo = resolveWindowInfo(windowId) else {
                continue
            }
            let pid = windowInfo.pid
            guard let axRef = resolveAXWindowRef(windowId: windowId, pid: pid) else {
                continue
            }
            handleCreated(ref: axRef, pid: pid, winId: Int(windowId))
        }
    }

    private func handleCreated(ref: AXWindowRef, pid: pid_t, winId: Int) {
        guard let controller else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let appPolicy = app?.activationPolicy
        let windowType = windowTypeProvider?(ref, pid)
            ?? AXWindowService.windowType(ref, appPolicy: appPolicy, bundleId: bundleId)
        guard windowType == .tiling else { return }

        if let bundleId, controller.appRulesByBundleId[bundleId]?.alwaysFloat == true {
            return
        }

        let workspaceId = controller.resolveWorkspaceForNewWindow(
            axRef: ref,
            pid: pid,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )

        if workspaceId != controller.activeWorkspace()?.id {
            if let monitor = controller.workspaceManager.monitor(for: workspaceId),
               controller.workspaceManager.workspaces(on: monitor.id)
               .contains(where: { $0.id == workspaceId })
            {
                _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
            }
        }

        _ = controller.workspaceManager.addWindow(ref, pid: pid, windowId: winId, to: workspaceId)
        subscribeToWindows([UInt32(winId)])
        controller.updateWorkspaceBar()

        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            if let app = NSRunningApplication(processIdentifier: pid) {
                _ = await controller.axManager.windowsForApp(app)
            }
        }

        controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
    }

    func handleRemoved(pid: pid_t, winId: Int) {
        guard let controller else { return }
        let entry = controller.workspaceManager.entry(forPid: pid, windowId: winId)
        let affectedWorkspaceId = entry?.workspaceId
        let removedHandle = entry?.handle
        let shouldRecoverFocus = removedHandle?.id == controller.workspaceManager.focusedHandle?.id
        let layoutType = affectedWorkspaceId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout

        if let entry,
           let wsId = affectedWorkspaceId,
           let monitor = controller.workspaceManager.monitor(for: wsId),
           controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId,
           layoutType != .dwindle
        {
            let shouldAnimate = if let engine = controller.niriEngine,
                                    let windowNode = engine.findNode(for: entry.handle)
            {
                !windowNode.isHiddenInTabbedMode
            } else {
                true
            }
            if shouldAnimate {
                controller.layoutRefreshController.startWindowCloseAnimation(
                    entry: entry,
                    monitor: monitor
                )
            }
        }

        if let removed = removedHandle {
            controller.focusCoordinator.discardPendingFocus(removed)
        }

        var oldFrames: [WindowHandle: CGRect] = [:]
        var removedNodeId: NodeId?
        if let wsId = affectedWorkspaceId, layoutType != .dwindle, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: wsId)
            if let handle = removedHandle {
                removedNodeId = engine.findNode(for: handle)?.id
            }
        }

        _ = controller.workspaceManager.removeWindow(pid: pid, windowId: winId)

        if let wsId = affectedWorkspaceId {
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: wsId,
                layoutType: layoutType,
                removedNodeId: removedNodeId,
                niriOldFrames: oldFrames,
                shouldRecoverFocus: shouldRecoverFocus
            )
        }
    }

    func handleAppActivation(pid: pid_t) {
        guard let controller else { return }
        guard controller.hasStartedServices else { return }
        let focusedWindow = resolveFocusedWindowValue(pid: pid)

        guard let windowElement = focusedWindow else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }

        guard CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }

        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        guard let axRef = try? AXWindowRef(element: axElement) else {
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)
            controller.borderManager.hideBorder()
            return
        }
        let winId = axRef.windowId

        let appFullscreen = AXWindowService.isFullscreen(axRef)

        if let entry = controller.workspaceManager.entry(forPid: pid, windowId: winId) {
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen
            )
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: appFullscreen)
        controller.borderManager.hideBorder()
    }

    func handleManagedAppActivation(
        entry: WindowModel.Entry,
        isWorkspaceActive: Bool,
        appFullscreen: Bool
    ) {
        guard let controller else { return }
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow

        _ = controller.workspaceManager.confirmManagedFocus(
            entry.handle,
            in: wsId,
            onMonitor: monitorId,
            appFullscreen: appFullscreen,
            activateWorkspaceOnMonitor: shouldActivateWorkspace
        )

        if let engine = controller.niriEngine,
           let node = engine.findNode(for: entry.handle),
           let _ = controller.workspaceManager.monitor(for: wsId)
        {
            controller.workspaceManager.withNiriViewportState(for: wsId) { state in
                controller.niriLayoutHandler.activateNode(
                    node, in: wsId, state: &state,
                    options: .init(layoutRefresh: isWorkspaceActive, axFocus: false)
                )
            }

            if let frame = node.frame {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            } else if let frame = try? AXWindowService.frame(entry.axRef) {
                controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
            }
        } else if let frame = try? AXWindowService.frame(entry.axRef) {
            controller.borderCoordinator.updateBorderIfAllowed(handle: entry.handle, frame: frame, windowId: entry.windowId)
        }
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        if shouldActivateWorkspace {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
    }

    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.handle)
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.handle) == .macosHiddenApp {
                _ = controller.workspaceManager.restoreFromNativeState(for: entry.handle)
            }
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
    }

    private func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    private func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }

    private func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider?(windowId) ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    private func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        axWindowRefProvider?(windowId, pid) ?? AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    private func subscribeToWindows(_ windowIds: [UInt32]) {
        if let windowSubscriptionHandler {
            windowSubscriptionHandler(windowIds)
            return
        }
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        if let focusedWindowValueProvider {
            return focusedWindowValueProvider(pid)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }
        return focusedWindow
    }
}
