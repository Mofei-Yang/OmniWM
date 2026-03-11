import AppKit
import Foundation
import QuartzCore

@MainActor final class LayoutRefreshController: NSObject {
    typealias PostLayoutAction = @MainActor () -> Void

    enum RefreshRoute: Equatable {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
    }

    enum ScheduledRefreshKind: Int {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
        case fullRescan
    }

    struct WindowRemovalPayload {
        let workspaceId: WorkspaceDescriptor.ID
        let layoutType: LayoutType
        let removedNodeId: NodeId?
        let niriOldFrames: [WindowHandle: CGRect]
        let shouldRecoverFocus: Bool
    }

    struct FollowUpRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
    }

    struct ScheduledRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var postLayoutActions: [PostLayoutAction] = []
        var windowRemovalPayloads: [WindowRemovalPayload] = []
        var followUpRefresh: FollowUpRefresh?

        init(
            kind: ScheduledRefreshKind,
            reason: RefreshReason,
            postLayout: PostLayoutAction? = nil,
            windowRemovalPayload: WindowRemovalPayload? = nil
        ) {
            self.kind = kind
            self.reason = reason
            if let postLayout {
                postLayoutActions = [postLayout]
            }
            if let windowRemovalPayload {
                windowRemovalPayloads = [windowRemovalPayload]
            }
        }
    }

    struct RefreshDebugCounters {
        var fullRescanExecutions: Int = 0
        var relayoutExecutions: Int = 0
        var immediateRelayoutExecutions: Int = 0
        var visibilityExecutions: Int = 0
        var windowRemovalExecutions: Int = 0
        var requestedByReason: [RefreshReason: Int] = [:]
        var executedByReason: [RefreshReason: Int] = [:]
    }

    struct RefreshDebugHooks {
        var onFullRescan: ((RefreshReason) async throws -> Bool)?
        var onRelayout: ((RefreshReason, RefreshRoute) async -> Bool)?
        var onVisibilityRefresh: ((RefreshReason) async -> Bool)?
        var onWindowRemoval: ((RefreshReason, [WindowRemovalPayload]) -> Bool)?
    }

    weak var controller: WMController?
    static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0

    enum HideReason {
        case workspaceInactive
        case layoutTransient
    }

    struct LayoutState {
        struct ClosingAnimation {
            let windowId: Int
            let axRef: AXWindowRef
            let fromFrame: CGRect
            let displacement: CGPoint
            let animation: SpringAnimation

            func progress(at time: TimeInterval) -> Double {
                animation.value(at: time)
            }

            func isComplete(at time: TimeInterval) -> Bool {
                animation.isComplete(at: time)
            }

            func currentFrame(at time: TimeInterval) -> CGRect {
                let clamped = min(max(progress(at: time), 0), 1)
                let offset = CGPoint(
                    x: displacement.x * CGFloat(clamped),
                    y: displacement.y * CGFloat(clamped)
                )
                return fromFrame.offsetBy(dx: offset.x, dy: offset.y)
            }
        }

        var activeRefreshTask: Task<Void, Never>?
        var activeRefresh: ScheduledRefresh?
        var pendingRefresh: ScheduledRefresh?
        var isInLightSession: Bool = false
        var isImmediateLayoutInProgress: Bool = false
        var isIncrementalRefreshInProgress: Bool = false
        var isFullEnumerationInProgress: Bool = false
        var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
        var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
        var closingAnimationsByDisplay: [CGDirectDisplayID: [Int: ClosingAnimation]] = [:]
        var screenChangeObserver: NSObjectProtocol?
        var hasCompletedInitialRefresh: Bool = false
    }

    var layoutState = LayoutState()
    var debugCounters = RefreshDebugCounters()
    var debugHooks = RefreshDebugHooks()

    private(set) lazy var niriHandler = NiriLayoutHandler(controller: controller)
    private(set) lazy var dwindleHandler = DwindleLayoutHandler(controller: controller)

    var isDiscoveryInProgress: Bool { layoutState.isFullEnumerationInProgress }

    init(controller: WMController) {
        self.controller = controller
        super.init()
    }

    func setup() {
        detectRefreshRates()
        layoutState.screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func getOrCreateDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        if let existing = layoutState.displayLinksByDisplay[displayId] {
            return existing
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        layoutState.displayLinksByDisplay[displayId] = link
        return link
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()
    }

    func cleanupForMonitorDisconnect(displayId: CGDirectDisplayID, migrateAnimations: Bool) {
        if let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) {
            link.invalidate()
        }

        layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)

        if migrateAnimations {
            if let wsId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: wsId)
            }
        } else {
            niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        }
        dwindleHandler.dwindleAnimationByDisplay.removeValue(forKey: displayId)
    }

    private func detectRefreshRates() {
        layoutState.refreshRateByDisplay.removeAll()
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            if let mode = CGDisplayCopyDisplayMode(displayId) {
                let rate = mode.refreshRate > 0 ? mode.refreshRate : 60.0
                layoutState.refreshRateByDisplay[displayId] = rate
            } else {
                layoutState.refreshRateByDisplay[displayId] = 60.0
            }
        }
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        guard let displayId = layoutState.displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return }

        niriHandler.tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
        dwindleHandler.tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
        tickClosingAnimations(targetTime: displayLink.targetTimestamp, displayId: displayId)
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        let targetDisplayId: CGDirectDisplayID
        if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            targetDisplayId = monitor.displayId
        } else if let mainDisplayId = NSScreen.main?.displayId {
            targetDisplayId = mainDisplayId
        } else {
            return
        }

        guard niriHandler.registerScrollAnimation(workspaceId, on: targetDisplayId) else { return }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = Array(niriHandler.scrollAnimationByDisplay.keys)
        niriHandler.scrollAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        let targetDisplayId = monitor.displayId

        guard dwindleHandler.registerDwindleAnimation(workspaceId, monitor: monitor, on: targetDisplayId) else { return }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func startWindowCloseAnimation(entry: WindowModel.Entry, monitor: Monitor) {
        guard controller != nil else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }

        let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
        let closeOffset = 12.0 * reduceMotionScale
        let displacement = CGPoint(x: 0, y: -closeOffset)

        let now = CACurrentMediaTime()
        let refreshRate = layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
        let animation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: now,
            config: .balanced.with(epsilon: 0.01, velocityEpsilon: 0.1),
            displayRefreshRate: refreshRate
        )

        var animations = layoutState.closingAnimationsByDisplay[monitor.displayId] ?? [:]
        guard animations[entry.windowId] == nil else { return }
        animations[entry.windowId] = LayoutState.ClosingAnimation(
            windowId: entry.windowId,
            axRef: entry.axRef,
            fromFrame: frame,
            displacement: displacement,
            animation: animation
        )
        layoutState.closingAnimationsByDisplay[monitor.displayId] = animations

        if let displayLink = getOrCreateDisplayLink(for: monitor.displayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopDwindleAnimation(for displayId: CGDirectDisplayID) {
        dwindleHandler.dwindleAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let displayIds = Array(dwindleHandler.dwindleAnimationByDisplay.keys)
        dwindleHandler.dwindleAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleHandler.hasDwindleAnimationRunning(in: workspaceId)
    }

    private func stopDisplayLinkIfIdle(for displayId: CGDirectDisplayID) {
        if niriHandler.scrollAnimationByDisplay[displayId] == nil,
           dwindleHandler.dwindleAnimationByDisplay[displayId] == nil,
           layoutState.closingAnimationsByDisplay[displayId].map({ $0.isEmpty }) ?? true
        {
            layoutState.displayLinksByDisplay[displayId]?.remove(from: .main, forMode: .common)
        }
    }

    private func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let animations = layoutState.closingAnimationsByDisplay[displayId], !animations.isEmpty else {
            return
        }

        var remaining: [Int: LayoutState.ClosingAnimation] = [:]

        for (windowId, animation) in animations {
            if animation.isComplete(at: targetTime) {
                continue
            }

            let frame = animation.currentFrame(at: targetTime)
            if (try? AXWindowService.setFrame(animation.axRef, frame: frame)) == nil {
                continue
            }
            remaining[windowId] = animation
        }

        if remaining.isEmpty {
            layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = remaining
        }
    }

    func applyLayoutForWorkspaces(_ workspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id
            guard workspaceIds.contains(wsId) else { continue }

            let layoutType = controller.settings.layoutType(for: workspace.name)

            switch layoutType {
            case .niri, .defaultLayout:
                guard let engine = controller.niriEngine else { continue }
                let state = controller.workspaceManager.niriViewportState(for: wsId)

                niriHandler.applyFramesOnDemand(
                    wsId: wsId,
                    state: state,
                    engine: engine,
                    monitor: monitor,
                    animationTime: nil
                )

            case .dwindle:
                guard let engine = controller.dwindleEngine else { continue }
                let insetFrame = controller.insetWorkingFrame(for: monitor)
                let frames = engine.calculateLayout(for: wsId, screen: insetFrame)

                var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
                for (handle, frame) in frames {
                    if let entry = controller.workspaceManager.entry(for: handle) {
                        frameUpdates.append((handle.pid, entry.windowId, frame))
                    }
                }
                controller.axManager.applyFramesParallel(frameUpdates)
            }
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for ws in controller.workspaceManager.workspaces where workspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            let isActive = controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == ws.id
            if !isActive {
                let preferredSide = preferredSides[monitor.id] ?? .right
                hideWorkspace(ws.id, monitor: monitor, preferredSide: preferredSide)
            }
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        niriHandler.cancelActiveAnimations(for: workspaceId)
    }

    func resetDebugState() {
        debugCounters = RefreshDebugCounters()
        debugHooks = RefreshDebugHooks()
    }

    func refreshDebugSnapshot() -> RefreshDebugCounters {
        debugCounters
    }

    func requestFullRescan(reason: RefreshReason) {
        scheduleFullRescan(reason: reason)
    }

    func requestRelayout(reason: RefreshReason) {
        scheduleRefreshSession(reason.relayoutSchedulingPolicy, reason: reason)
    }

    func requestImmediateRelayout(
        reason: RefreshReason,
        postLayout: PostLayoutAction? = nil
    ) {
        guard !layoutState.isInLightSession else { return }
        enqueueRefresh(.init(kind: .immediateRelayout, reason: reason, postLayout: postLayout))
    }

    func requestVisibilityRefresh(
        reason: RefreshReason,
        postLayout: PostLayoutAction? = nil
    ) {
        guard !layoutState.isInLightSession else { return }
        enqueueRefresh(.init(kind: .visibilityRefresh, reason: reason, postLayout: postLayout))
    }

    func requestWindowRemoval(
        workspaceId: WorkspaceDescriptor.ID,
        layoutType: LayoutType,
        removedNodeId: NodeId?,
        niriOldFrames: [WindowHandle: CGRect],
        shouldRecoverFocus: Bool,
        postLayout: PostLayoutAction? = nil
    ) {
        guard !layoutState.isInLightSession else { return }
        enqueueRefresh(
            .init(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                postLayout: postLayout,
                windowRemovalPayload: .init(
                    workspaceId: workspaceId,
                    layoutType: layoutType,
                    removedNodeId: removedNodeId,
                    niriOldFrames: niriOldFrames,
                    shouldRecoverFocus: shouldRecoverFocus
                )
            )
        )
    }

    func commitWorkspaceTransition(
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        reason: RefreshReason = .workspaceTransition,
        postLayout: PostLayoutAction? = nil
    ) {
        if !affectedWorkspaces.isEmpty {
            applyLayoutForWorkspaces(affectedWorkspaces)
        }
        hideInactiveWorkspacesSync()
        requestImmediateRelayout(reason: reason, postLayout: postLayout)
    }

    private func scheduleFullRescan(reason: RefreshReason) {
        guard !layoutState.isInLightSession else { return }
        enqueueRefresh(.init(kind: .fullRescan, reason: reason))
    }

    private func scheduleRefreshSession(_ policy: RelayoutSchedulingPolicy, reason: RefreshReason) {
        guard !layoutState.isInLightSession else { return }
        if policy.shouldDropWhileBusy {
            if layoutState.isIncrementalRefreshInProgress || layoutState.isImmediateLayoutInProgress {
                return
            }
            if !niriHandler.scrollAnimationByDisplay.isEmpty
                || !dwindleHandler.dwindleAnimationByDisplay.isEmpty {
                return
            }
        }
        enqueueRefresh(.init(kind: .relayout, reason: reason))
    }

    private func executeScheduledRelayout(reason: RefreshReason) async -> Bool {
        guard !layoutState.isIncrementalRefreshInProgress else { return false }
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isIncrementalRefreshInProgress = true
        defer { layoutState.isIncrementalRefreshInProgress = false }
        return await executeRelayout(
            reason: reason,
            route: .relayout,
            useScrollAnimationPath: false,
            recoverFocus: true
        )
    }

    private func executeRelayout(
        reason: RefreshReason,
        route: RefreshRoute,
        useScrollAnimationPath: Bool,
        recoverFocus: Bool
    ) async -> Bool {
        recordRefreshExecution(route, reason: reason)
        if await debugHooks.onRelayout?(reason, route) == true {
            return true
        }

        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        let activeWorkspaceIds = currentActiveWorkspaceIds()

        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)

        if !niriWorkspaces.isEmpty {
            await niriHandler.layoutWithNiriEngine(
                activeWorkspaces: niriWorkspaces,
                useScrollAnimationPath: useScrollAnimationPath
            )
        }
        guard !Task.isCancelled else { return false }
        if !dwindleWorkspaces.isEmpty {
            await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }
        guard !Task.isCancelled else { return false }

        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
        guard !Task.isCancelled else { return false }

        if recoverFocus, let focusedWorkspaceId = controller.activeWorkspace()?.id {
            controller.ensureFocusedHandleValid(in: focusedWorkspaceId)
        }

        return true
    }

    private func executeVisibilityRefresh(reason: RefreshReason) async -> Bool {
        recordRefreshExecution(.visibilityRefresh, reason: reason)
        if await debugHooks.onVisibilityRefresh?(reason) == true {
            return true
        }

        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        controller.updateWorkspaceBar()
        controller.niriLayoutHandler.updateTabbedColumnOverlays()
        refreshFocusedBorderForVisibilityState(on: controller)

        return true
    }

    func runLightSession(_ body: () -> Void) {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.isInLightSession = true

        if let controller {
            for monitor in controller.workspaceManager.monitors {
                if let ws = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                    let handles = controller.workspaceManager.entries(in: ws.id).map(\.handle)
                    let layoutType = controller.settings.layoutType(for: ws.name)
                    let focused = controller.workspaceManager.preferredFocusHandle(in: ws.id)

                    switch layoutType {
                    case .dwindle:
                        if let dwindleEngine = controller.dwindleEngine {
                            _ = dwindleEngine.syncWindows(handles, in: ws.id, focusedHandle: focused)
                        }
                    case .niri, .defaultLayout:
                        if let niriEngine = controller.niriEngine {
                            let selection = controller.workspaceManager.niriViewportState(for: ws.id).selectedNodeId
                            _ = niriEngine.syncWindows(handles, in: ws.id, selectedNodeId: selection, focusedHandle: focused)
                        }
                    }
                }
            }
        }

        body()
        layoutState.isInLightSession = false
        requestImmediateRelayout(reason: .lightSessionCommit)
    }

    func hideInactiveWorkspacesSync() {
        guard let controller else { return }
        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
    }

    private func executeImmediateRelayout(reason: RefreshReason) async -> Bool {
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isImmediateLayoutInProgress = true
        defer { layoutState.isImmediateLayoutInProgress = false }
        return await executeRelayout(
            reason: reason,
            route: .immediateRelayout,
            useScrollAnimationPath: !niriHandler.scrollAnimationByDisplay.isEmpty,
            recoverFocus: false
        )
    }

    private func executeWindowRemoval(
        reason: RefreshReason,
        payloads: [WindowRemovalPayload]
    ) async -> Bool {
        recordRefreshExecution(.windowRemoval, reason: reason)
        if debugHooks.onWindowRemoval?(reason, payloads) == true {
            return true
        }

        guard let controller else { return false }
        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var focusedWorkspacesToRecover: Set<WorkspaceDescriptor.ID> = []

        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(payload.workspaceId)
            case .niri, .defaultLayout:
                await niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: [payload.workspaceId],
                    useScrollAnimationPath: true,
                    removedNodeId: payload.removedNodeId
                )
                guard !Task.isCancelled else { return false }

                if let engine = controller.niriEngine {
                    let newFrames = engine.captureWindowFrames(in: payload.workspaceId)
                    let animationsTriggered = engine.triggerMoveAnimations(
                        in: payload.workspaceId,
                        oldFrames: payload.niriOldFrames,
                        newFrames: newFrames
                    )
                    let hasWindowAnimations = engine.hasAnyWindowAnimationsRunning(in: payload.workspaceId)
                    let hasColumnAnimations = engine.hasAnyColumnAnimationsRunning(in: payload.workspaceId)

                    if animationsTriggered || hasWindowAnimations || hasColumnAnimations {
                        startScrollAnimation(for: payload.workspaceId)
                    }
                }
            }

            if payload.shouldRecoverFocus {
                focusedWorkspacesToRecover.insert(payload.workspaceId)
            }
        }

        if !dwindleWorkspaces.isEmpty {
            await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
            guard !Task.isCancelled else { return false }
        }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
        guard !Task.isCancelled else { return false }

        for workspaceId in focusedWorkspacesToRecover where activeWorkspaceIds.contains(workspaceId) {
            controller.ensureFocusedHandleValid(in: workspaceId)
        }

        if let focusedHandle = controller.workspaceManager.focusedHandle,
           let entry = controller.workspaceManager.entry(for: focusedHandle),
           let frame = try? AXWindowService.frame(entry.axRef)
        {
            controller.borderCoordinator.updateBorderIfAllowed(
                handle: focusedHandle,
                frame: frame,
                windowId: entry.windowId
            )
        } else {
            controller.borderManager.hideBorder()
        }

        return true
    }

    private func refreshFocusedBorderForVisibilityState(on controller: WMController) {
        guard let focusedHandle = controller.workspaceManager.focusedHandle,
              let entry = controller.workspaceManager.entry(for: focusedHandle)
        else {
            controller.borderManager.hideBorder()
            return
        }

        if controller.hiddenAppPIDs.contains(entry.handle.pid)
            || controller.workspaceManager.layoutReason(for: entry.handle) != .standard
            || controller.workspaceManager.isHiddenInCorner(entry.handle)
        {
            controller.borderManager.hideBorder()
            return
        }

        guard let frame = try? AXWindowService.frame(entry.axRef) else {
            controller.borderManager.hideBorder()
            return
        }

        controller.borderCoordinator.updateBorderIfAllowed(
            handle: focusedHandle,
            frame: frame,
            windowId: entry.windowId
        )
    }

    func waitForRefreshWorkForTests() async {
        while let task = layoutState.activeRefreshTask {
            await task.value
        }
    }

    func resetState() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.isInLightSession = false

        for (_, link) in layoutState.displayLinksByDisplay {
            link.invalidate()
        }
        layoutState.displayLinksByDisplay.removeAll()
        niriHandler.scrollAnimationByDisplay.removeAll()
        dwindleHandler.dwindleAnimationByDisplay.removeAll()
        layoutState.closingAnimationsByDisplay.removeAll()

        controller?.axManager.clearInactiveWorkspaceWindows()

        if let observer = layoutState.screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutState.screenChangeObserver = nil
        }
    }

    private func executeFullRefresh(reason: RefreshReason) async throws -> Bool {
        debugCounters.fullRescanExecutions += 1
        debugCounters.executedByReason[reason, default: 0] += 1
        if try await debugHooks.onFullRescan?(reason) == true {
            return true
        }
        layoutState.isFullEnumerationInProgress = true
        defer { layoutState.isFullEnumerationInProgress = false }

        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        let windows = await controller.axManager.currentWindowsAsync()
        try Task.checkCancellation()
        var seenKeys: Set<WindowModel.WindowKey> = []
        let focusedWorkspaceId = controller.activeWorkspace()?.id

        for (ax, pid, winId) in windows {
            if let bundleId = controller.appInfoCache.bundleId(for: pid) {
                if bundleId == LockScreenObserver.lockScreenAppBundleId {
                    continue
                }
                if controller.appRulesByBundleId[bundleId]?.alwaysFloat == true {
                    continue
                }
            }

            let defaultWorkspace = controller.resolveWorkspaceForNewWindow(
                axRef: ax,
                pid: pid,
                fallbackWorkspaceId: focusedWorkspaceId
            )
            let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
            let wsForWindow = existingAssignment ?? defaultWorkspace

            _ = controller.workspaceManager.addWindow(ax, pid: pid, windowId: winId, to: wsForWindow)
            seenKeys.insert(.init(pid: pid, windowId: winId))
        }
        controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 2)
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)

        try Task.checkCancellation()

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }

        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(activeWorkspaceIds)

        if !niriWorkspaces.isEmpty {
            await niriHandler.layoutWithNiriEngine(activeWorkspaces: niriWorkspaces, useScrollAnimationPath: false)
        }
        try Task.checkCancellation()
        if !dwindleWorkspaces.isEmpty {
            await dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
        }
        try Task.checkCancellation()
        // Rebuild workspace-level frame suppression (executeFullRefresh has its own hide loop)
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for ws in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: ws.id) {
                allEntries.append((ws.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds
        )
        try Task.checkCancellation()

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            let preferredSide = preferredSides[monitor.id] ?? .right
            hideWorkspace(ws.id, monitor: monitor, preferredSide: preferredSide)
        }
        try Task.checkCancellation()
        controller.updateWorkspaceBar()
        try Task.checkCancellation()

        if let focusedWorkspaceId {
            controller.ensureFocusedHandleValid(in: focusedWorkspaceId)
        }

        layoutState.hasCompletedInitialRefresh = true
        await controller.axEventHandler.drainDeferredCreatedWindows()
        try Task.checkCancellation()
        controller.axEventHandler.subscribeToManagedWindows()
        return true
    }

    func updateTabbedColumnOverlays() {
        niriHandler.updateTabbedColumnOverlays()
    }

    func selectTabInNiri(workspaceId: WorkspaceDescriptor.ID, columnId: NodeId, index: Int) {
        niriHandler.selectTabInNiri(workspaceId: workspaceId, columnId: columnId, index: index)
    }

    private func partitionWorkspacesByLayoutType(
        _ workspaces: Set<WorkspaceDescriptor.ID>
    ) -> (niri: Set<WorkspaceDescriptor.ID>, dwindle: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return ([], []) }

        var niriWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for wsId in workspaces {
            guard let ws = controller.workspaceManager.descriptor(for: wsId) else {
                niriWorkspaces.insert(wsId)
                continue
            }
            let layoutType = controller.settings.layoutType(for: ws.name)
            switch layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(wsId)
            case .niri, .defaultLayout:
                niriWorkspaces.insert(wsId)
            }
        }

        return (niriWorkspaces, dwindleWorkspaces)
    }

    private func currentActiveWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        guard let controller else { return [] }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        return activeWorkspaceIds
    }

    private func enqueueRefresh(_ refresh: ScheduledRefresh) {
        recordRefreshRequest(refresh.reason)
        if let activeRefresh = layoutState.activeRefresh {
            handleRefresh(refresh, whileActive: activeRefresh)
            return
        }

        mergePendingRefresh(refresh)
        startNextRefreshIfNeeded()
    }

    private func handleRefresh(_ refresh: ScheduledRefresh, whileActive activeRefresh: ScheduledRefresh) {
        switch (activeRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            mergePendingRefresh(refresh)
        case (.fullRescan, _):
            absorbIntoActiveFullRescan(refresh)
        case (.visibilityRefresh, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.windowRemoval, .fullRescan):
            mergePendingRefresh(refresh)
        case (.windowRemoval, _):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .fullRescan):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.immediateRelayout, .immediateRelayout):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.immediateRelayout, .relayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .relayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        }
    }

    private func absorbIntoActiveFullRescan(_ refresh: ScheduledRefresh) {
        guard !refresh.postLayoutActions.isEmpty else { return }
        guard var activeRefresh = layoutState.activeRefresh else { return }
        activeRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        layoutState.activeRefresh = activeRefresh
    }

    private func mergePendingRefresh(_ refresh: ScheduledRefresh) {
        guard var pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }

        switch (pendingRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.fullRescan, _):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            pendingRefresh = upgradedRefresh
        case (.visibilityRefresh, .visibilityRefresh):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.windowRemoval, .fullRescan),
             (.immediateRelayout, .fullRescan),
             (.relayout, .fullRescan):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            pendingRefresh = upgradedRefresh
        case (.windowRemoval, .windowRemoval):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                pendingRefresh.windowRemovalPayloads,
                with: refresh.windowRemovalPayloads
            )
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.windowRemoval, .immediateRelayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(into: &pendingRefresh, kind: .immediateRelayout, reason: refresh.reason)
        case (.windowRemoval, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(into: &pendingRefresh, kind: .relayout, reason: refresh.reason)
        case (.windowRemoval, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.immediateRelayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = pendingRefresh.followUpRefresh
            mergeFollowUp(into: &upgradedRefresh, kind: .immediateRelayout, reason: pendingRefresh.reason)
            pendingRefresh = upgradedRefresh
        case (.relayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeFollowUp(into: &upgradedRefresh, kind: .relayout, reason: pendingRefresh.reason)
            pendingRefresh = upgradedRefresh
        case (.immediateRelayout, .visibilityRefresh),
             (.relayout, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.immediateRelayout, .immediateRelayout),
             (.relayout, .relayout):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
        case (.immediateRelayout, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(into: &pendingRefresh, kind: .relayout, reason: refresh.reason)
        case (.relayout, .immediateRelayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeFollowUp(into: &upgradedRefresh, kind: .relayout, reason: pendingRefresh.reason)
            pendingRefresh = upgradedRefresh
        }

        layoutState.pendingRefresh = pendingRefresh
    }

    private func startNextRefreshIfNeeded() {
        guard layoutState.activeRefreshTask == nil, let refresh = layoutState.pendingRefresh else { return }

        layoutState.pendingRefresh = nil
        layoutState.activeRefresh = refresh
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await self.execute(refresh)
            self.finishRefresh(refresh, didComplete: didComplete)
        }
    }

    private func execute(_ refresh: ScheduledRefresh) async -> Bool {
        do {
            switch refresh.kind {
            case .fullRescan:
                return try await executeFullRefresh(reason: refresh.reason)
            case .relayout:
                let policy = refresh.reason.relayoutSchedulingPolicy
                if policy.debounceInterval > 0 {
                    try await Task.sleep(nanoseconds: policy.debounceInterval)
                }
                try Task.checkCancellation()
                return await executeScheduledRelayout(reason: refresh.reason)
            case .immediateRelayout:
                return await executeImmediateRelayout(reason: refresh.reason)
            case .visibilityRefresh:
                return await executeVisibilityRefresh(reason: refresh.reason)
            case .windowRemoval:
                return await executeWindowRemoval(
                    reason: refresh.reason,
                    payloads: refresh.windowRemovalPayloads
                )
            }
        } catch {
            return false
        }
    }

    private func finishRefresh(_ refresh: ScheduledRefresh, didComplete: Bool) {
        let completedRefresh = layoutState.activeRefresh ?? refresh

        if !didComplete {
            preserveCancelledRefreshState(completedRefresh)
        }

        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil

        if didComplete {
            for postLayoutAction in completedRefresh.postLayoutActions {
                postLayoutAction()
            }

            if let followUpRefresh = completedRefresh.followUpRefresh {
                enqueueRefresh(
                    .init(kind: followUpRefresh.kind, reason: followUpRefresh.reason)
                )
            }
        }

        startNextRefreshIfNeeded()
    }

    private func recordRefreshExecution(_ route: RefreshRoute, reason: RefreshReason) {
        debugCounters.executedByReason[reason, default: 0] += 1
        switch route {
        case .relayout:
            debugCounters.relayoutExecutions += 1
        case .immediateRelayout:
            debugCounters.immediateRelayoutExecutions += 1
        case .visibilityRefresh:
            debugCounters.visibilityExecutions += 1
        case .windowRemoval:
            debugCounters.windowRemovalExecutions += 1
        }
    }

    private func recordRefreshRequest(_ reason: RefreshReason) {
        debugCounters.requestedByReason[reason, default: 0] += 1
    }

    private func mergeWindowRemovalPayloads(
        _ existingPayloads: [WindowRemovalPayload],
        with incomingPayloads: [WindowRemovalPayload]
    ) -> [WindowRemovalPayload] {
        var mergedByWorkspace: [WorkspaceDescriptor.ID: WindowRemovalPayload] = [:]
        var order: [WorkspaceDescriptor.ID] = []

        for payload in existingPayloads + incomingPayloads {
            if var existing = mergedByWorkspace[payload.workspaceId] {
                let oldFrames = existing.niriOldFrames.isEmpty ? payload.niriOldFrames : existing.niriOldFrames
                existing = WindowRemovalPayload(
                    workspaceId: payload.workspaceId,
                    layoutType: payload.layoutType,
                    removedNodeId: payload.removedNodeId ?? existing.removedNodeId,
                    niriOldFrames: oldFrames,
                    shouldRecoverFocus: existing.shouldRecoverFocus || payload.shouldRecoverFocus
                )
                mergedByWorkspace[payload.workspaceId] = existing
            } else {
                mergedByWorkspace[payload.workspaceId] = payload
                order.append(payload.workspaceId)
            }
        }

        return order.compactMap { mergedByWorkspace[$0] }
    }

    private func mergeFollowUp(into refresh: inout ScheduledRefresh, kind: ScheduledRefreshKind, reason: RefreshReason) {
        refresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: .init(kind: kind, reason: reason)
        )
    }

    private func mergeFollowUpRefresh(
        _ existing: FollowUpRefresh?,
        with incoming: FollowUpRefresh?
    ) -> FollowUpRefresh? {
        switch (existing, incoming) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (existing?, incoming?):
            if existing.kind == .immediateRelayout || incoming.kind == .immediateRelayout {
                return incoming.kind == .immediateRelayout ? incoming : existing
            }
            return incoming
        }
    }

    private func preserveCancelledRefreshState(_ refresh: ScheduledRefresh) {
        guard var pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }

        if !refresh.postLayoutActions.isEmpty {
            pendingRefresh.postLayoutActions.insert(contentsOf: refresh.postLayoutActions, at: 0)
        }

        if refresh.kind == .windowRemoval, !refresh.windowRemovalPayloads.isEmpty {
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                refresh.windowRemovalPayloads,
                with: pendingRefresh.windowRemovalPayloads
            )
            if pendingRefresh.kind != .fullRescan, pendingRefresh.kind != .windowRemoval {
                pendingRefresh.kind = .windowRemoval
                pendingRefresh.reason = refresh.reason
            }
        }

        pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: pendingRefresh.followUpRefresh
        )

        layoutState.pendingRefresh = pendingRefresh
    }

    func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    func hideInactiveWorkspaces(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }

        // Rebuild the workspace-level frame suppression set (live check in applyFramesParallel)
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for ws in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: ws.id) {
                allEntries.append((ws.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds
        )

        // Bulk cancel in-flight frame jobs for all inactive workspace windows upfront,
        // before the per-window hide loop, to prevent AX batch races with SkyLight moves.
        var inactiveWindowJobs: [(pid: pid_t, windowId: Int)] = []
        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            for entry in controller.workspaceManager.entries(in: ws.id) {
                inactiveWindowJobs.append((entry.handle.pid, entry.windowId))
            }
        }
        if !inactiveWindowJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(inactiveWindowJobs)
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for ws in controller.workspaceManager.workspaces where !activeWorkspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            let preferredSide = preferredSides[monitor.id] ?? .right
            hideWorkspace(ws.id, monitor: monitor, preferredSide: preferredSide)
        }
    }

    func unhideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        let entries = controller.workspaceManager.entries(in: workspaceId)
        for entry in entries {
            controller.axManager.markWindowActive(entry.windowId)
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor, preferredSide: HideSide) {
        guard let controller else { return }
        for entry in controller.workspaceManager.entries(in: workspaceId) {
            controller.axManager.markWindowInactive(entry.windowId)
            hideWindow(entry, monitor: monitor, side: preferredSide, targetY: nil, reason: .workspaceInactive)
        }
    }

    func hideWindow(_ entry: WindowModel.Entry, monitor: Monitor, side: HideSide, targetY: CGFloat?, reason: HideReason) {
        guard let controller else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }
        let frameEntry = (pid: entry.handle.pid, windowId: entry.windowId)
        if !controller.workspaceManager.isHiddenInCorner(entry.handle) {
            let center = frame.center
            let referenceMonitor = center.monitorApproximation(in: controller.workspaceManager.monitors) ?? monitor
            let referenceFrame = referenceMonitor.frame
            let proportional = proportionalPosition(topLeft: frame.topLeftCorner, in: referenceFrame)
            let hiddenState = WindowModel.HiddenState(
                proportionalPosition: proportional,
                referenceMonitorId: referenceMonitor.id,
                workspaceInactive: reason == .workspaceInactive
            )
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.handle)
        } else if reason == .workspaceInactive,
                  let existingState = controller.workspaceManager.hiddenState(for: entry.handle),
                  !existingState.workspaceInactive {
            let upgradedState = WindowModel.HiddenState(
                proportionalPosition: existingState.proportionalPosition,
                referenceMonitorId: existingState.referenceMonitorId,
                workspaceInactive: true
            )
            controller.workspaceManager.setHiddenState(upgradedState, for: entry.handle)
        }
        controller.axManager.suppressFrameWrites([frameEntry])
        controller.axManager.cancelPendingFrameJobs([frameEntry])
        let yPos = targetY ?? frame.origin.y
        let scale = backingScale(for: monitor)
        let origin = hiddenOrigin(
            for: frame.size,
            edgeFrame: monitor.visibleFrame,
            scale: scale,
            side: side,
            pid: entry.handle.pid,
            targetY: yPos,
            monitor: monitor,
            monitors: controller.workspaceManager.monitors
        )
        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - origin.x) < moveEpsilon,
           abs(frame.origin.y - origin.y) < moveEpsilon {
            return
        }
        controller.axManager.applyPositionsViaSkyLight([(entry.windowId, origin)], allowInactive: true)

        let verifyEpsilon: CGFloat = 1.0
        let observedOrigin = observedWindowOrigin(entry)

        if let observedOrigin,
           abs(observedOrigin.x - origin.x) > verifyEpsilon
            || abs(observedOrigin.y - origin.y) > verifyEpsilon
        {
            let fallbackFrame = CGRect(origin: origin, size: frame.size)
            try? AXWindowService.setFrame(entry.axRef, frame: fallbackFrame)
        }
    }

    func unhideWindow(_ entry: WindowModel.Entry, monitor: Monitor) {
        guard let controller else { return }
        if let hiddenState = controller.workspaceManager.hiddenState(for: entry.handle),
           hiddenState.workspaceInactive {
            restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState)
        }
        controller.workspaceManager.setHiddenState(nil, for: entry.handle)
        controller.axManager.unsuppressFrameWrites([(entry.handle.pid, entry.windowId)])
    }

    func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    func hiddenOrigin(
        for size: CGSize,
        edgeFrame: CGRect,
        scale: CGFloat,
        side: HideSide,
        pid: pid_t,
        targetY: CGFloat,
        monitor: Monitor,
        monitors: [Monitor]
    ) -> CGPoint {
        let edgeReveal = Self.hiddenEdgeReveal(isZoomApp: isZoomApp(pid))
        _ = scale

        func origin(for side: HideSide) -> CGPoint {
            switch side {
            case .left:
                return CGPoint(x: edgeFrame.minX - size.width + edgeReveal, y: targetY)
            case .right:
                return CGPoint(x: edgeFrame.maxX - edgeReveal, y: targetY)
            }
        }

        func overlapArea(for origin: CGPoint) -> CGFloat {
            let rect = CGRect(origin: origin, size: size)
            var area: CGFloat = 0
            for other in monitors where other.id != monitor.id {
                let intersection = rect.intersection(other.frame)
                if intersection.isNull { continue }
                area += intersection.width * intersection.height
            }
            return area
        }

        let primaryOrigin = origin(for: side)
        let primaryOverlap = overlapArea(for: primaryOrigin)
        if primaryOverlap == 0 {
            return primaryOrigin
        }

        let alternateSide: HideSide = side == .left ? .right : .left
        let alternateOrigin = origin(for: alternateSide)
        let alternateOverlap = overlapArea(for: alternateOrigin)
        if alternateOverlap < primaryOverlap {
            return alternateOrigin
        }

        return primaryOrigin
    }

    private func preferredHideSides(for monitors: [Monitor]) -> [Monitor.ID: HideSide] {
        let important = 10
        var preferredSides: [Monitor.ID: HideSide] = [:]

        for monitor in monitors {
            let monitorFrame = monitor.frame
            let xOff = monitorFrame.width * 0.1
            let yOff = monitorFrame.height * 0.1

            let bottomRight = CGPoint(x: monitorFrame.maxX, y: monitorFrame.minY)
            let bottomLeft = CGPoint(x: monitorFrame.minX, y: monitorFrame.minY)

            let rightPoints = [
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y - yOff),
                CGPoint(x: bottomRight.x - xOff, y: bottomRight.y + 2),
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y + 2)
            ]

            let leftPoints = [
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y - yOff),
                CGPoint(x: bottomLeft.x + xOff, y: bottomLeft.y + 2),
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y + 2)
            ]

            func sideScore(_ points: [CGPoint]) -> Int {
                monitors.reduce(0) { partial, other in
                    let c1 = other.frame.contains(points[0]) ? 1 : 0
                    let c2 = other.frame.contains(points[1]) ? 1 : 0
                    let c3 = other.frame.contains(points[2]) ? 1 : 0
                    return partial + c1 + c2 + important * c3
                }
            }

            let leftScore = sideScore(leftPoints)
            let rightScore = sideScore(rightPoints)
            preferredSides[monitor.id] = leftScore < rightScore ? .left : .right
        }

        return preferredSides
    }

    private func restoreWindowFromHiddenState(
        _ entry: WindowModel.Entry,
        monitor: Monitor,
        hiddenState: WindowModel.HiddenState
    ) {
        guard let controller else { return }
        guard let frame = AXWindowService.framePreferFast(entry.axRef) else { return }

        let fallbackMonitor = hiddenState.referenceMonitorId
            .flatMap { controller.workspaceManager.monitor(byId: $0) }
        let restoreFrame: CGRect
        if monitor.frame.width > 1, monitor.frame.height > 1 {
            restoreFrame = monitor.frame
        } else {
            restoreFrame = fallbackMonitor?.frame ?? monitor.frame
        }

        let topLeft = topLeftPoint(from: hiddenState.proportionalPosition, in: restoreFrame)
        let restoredOrigin = clampedOrigin(forTopLeft: topLeft, windowSize: frame.size, in: restoreFrame)
        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - restoredOrigin.x) < moveEpsilon,
           abs(frame.origin.y - restoredOrigin.y) < moveEpsilon {
            return
        }

        controller.axManager.applyPositionsViaSkyLight([(entry.windowId, restoredOrigin)], allowInactive: true)

        let verifyEpsilon: CGFloat = 1.0
        if let observedOrigin = observedWindowOrigin(entry),
           abs(observedOrigin.x - restoredOrigin.x) > verifyEpsilon
            || abs(observedOrigin.y - restoredOrigin.y) > verifyEpsilon
        {
            let fallbackFrame = CGRect(origin: restoredOrigin, size: frame.size)
            try? AXWindowService.setFrame(entry.axRef, frame: fallbackFrame)
        }
    }

    private func topLeftPoint(from proportionalPosition: CGPoint, in frame: CGRect) -> CGPoint {
        let xRatio = min(max(proportionalPosition.x, 0), 1)
        let yRatio = min(max(proportionalPosition.y, 0), 1)
        return CGPoint(
            x: frame.minX + frame.width * xRatio,
            y: frame.maxY - frame.height * yRatio
        )
    }

    private func clampedOrigin(forTopLeft topLeft: CGPoint, windowSize: CGSize, in frame: CGRect) -> CGPoint {
        let minX = frame.minX
        let maxX = frame.maxX - windowSize.width
        let clampedX: CGFloat
        if maxX >= minX {
            clampedX = min(max(topLeft.x, minX), maxX)
        } else {
            clampedX = minX
        }

        let minTopLeftY = frame.minY + windowSize.height
        let maxTopLeftY = frame.maxY
        let clampedTopLeftY: CGFloat
        if maxTopLeftY >= minTopLeftY {
            clampedTopLeftY = min(max(topLeft.y, minTopLeftY), maxTopLeftY)
        } else {
            clampedTopLeftY = maxTopLeftY
        }

        return CGPoint(x: clampedX, y: clampedTopLeftY - windowSize.height)
    }

    private func observedWindowOrigin(_ entry: WindowModel.Entry) -> CGPoint? {
        if let wsRect = SkyLight.shared.getWindowBounds(UInt32(entry.windowId)) {
            let appKitRect = ScreenCoordinateSpace.toAppKit(rect: wsRect)
            return appKitRect.origin
        }
        return AXWindowService.framePreferFast(entry.axRef)?.origin
    }

    static func hiddenEdgeReveal(isZoomApp: Bool) -> CGFloat {
        isZoomApp ? 0 : hiddenWindowEdgeRevealEpsilon
    }

    func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func updateWindowConstraints(
        in wsId: WorkspaceDescriptor.ID,
        updateEngine: (WindowHandle, WindowSizeConstraints) -> Void
    ) {
        guard let controller else { return }
        for entry in controller.workspaceManager.entries(in: wsId) {
            let currentSize = (AXWindowService.framePreferFast(entry.axRef))?.size
            var constraints: WindowSizeConstraints
            if let cached = controller.workspaceManager.cachedConstraints(for: entry.handle) {
                constraints = cached
            } else {
                constraints = AXWindowService.sizeConstraints(entry.axRef, currentSize: currentSize)
                controller.workspaceManager.setCachedConstraints(constraints, for: entry.handle)
            }

            if let bundleId = controller.appInfoCache.bundleId(for: entry.handle.pid),
               let rule = controller.appRulesByBundleId[bundleId]
            {
                if let minW = rule.minWidth {
                    constraints.minSize.width = max(constraints.minSize.width, minW)
                }
                if let minH = rule.minHeight {
                    constraints.minSize.height = max(constraints.minSize.height, minH)
                }
            }

            updateEngine(entry.handle, constraints)
        }
    }
}
