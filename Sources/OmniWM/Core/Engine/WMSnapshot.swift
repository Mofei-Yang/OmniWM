import CoreGraphics
import Foundation

enum WindowLifecyclePhase: String, Codable, Equatable {
    case discovered
    case admitted
    case tiled
    case floating
    case hidden
    case offscreen
    case restoring
    case replacing
    case nativeFullscreen
    case destroyed
}

struct ObservedWindowState: Equatable {
    var frame: CGRect?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var isVisible: Bool
    var isFocused: Bool
    var hasAXReference: Bool
    var isNativeFullscreen: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        ObservedWindowState(
            frame: nil,
            workspaceId: workspaceId,
            monitorId: monitorId,
            isVisible: true,
            isFocused: false,
            hasAXReference: true,
            isNativeFullscreen: false
        )
    }
}

struct DesiredWindowState: Equatable {
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var disposition: TrackedWindowMode?
    var floatingFrame: CGRect?
    var rescueEligible: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        disposition: TrackedWindowMode
    ) -> DesiredWindowState {
        DesiredWindowState(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: disposition,
            floatingFrame: nil,
            rescueEligible: disposition == .floating
        )
    }

    var summary: String {
        var parts: [String] = []
        if let workspaceId {
            parts.append("workspace=\(workspaceId.uuidString)")
        }
        if let disposition {
            parts.append("mode=\(disposition)")
        }
        if rescueEligible {
            parts.append("rescue=true")
        }
        return parts.joined(separator: ",")
    }
}

struct DisplayFingerprint: Hashable, Equatable, Codable {
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }
}

struct TopologyProfile: Hashable, Equatable, Codable {
    let displays: [DisplayFingerprint]

    init(monitors: [Monitor]) {
        displays = Monitor.sortedByPosition(monitors).map(DisplayFingerprint.init)
    }

    init(displays: [DisplayFingerprint]) {
        self.displays = displays
    }

    static let empty = TopologyProfile(displays: [])
}

struct RestoreIntent: Equatable {
    let topologyProfile: TopologyProfile
    var workspaceId: WorkspaceDescriptor.ID
    var preferredMonitor: DisplayFingerprint?
    var floatingFrame: CGRect?
    var normalizedFloatingOrigin: CGPoint?
    var restoreToFloating: Bool
    var rescueEligible: Bool
}

struct ReplacementCorrelation: Equatable {
    enum Reason: String, Equatable {
        case managedReplacement
        case nativeFullscreen
        case manualRekey
    }

    var previousToken: WindowToken?
    var nextToken: WindowToken?
    var reason: Reason
    var recordedAt: Date
}

struct PendingManagedFocusSnapshot: Equatable {
    var token: WindowToken?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?

    static let empty = PendingManagedFocusSnapshot(
        token: nil,
        workspaceId: nil,
        monitorId: nil
    )
}

struct FocusSessionSnapshot: Equatable {
    var focusedToken: WindowToken?
    var pendingManagedFocus: PendingManagedFocusSnapshot
    var focusLease: FocusPolicyLease?
    var isNonManagedFocusActive: Bool
    var isAppFullscreenActive: Bool
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
    var nextManagedRequestId: UInt64 = 1
    var activeManagedRequest: ManagedFocusRequest? = nil

    var pendingFocusedToken: WindowToken? {
        get { pendingManagedFocus.token }
        set { pendingManagedFocus.token = newValue }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        get { pendingManagedFocus.workspaceId }
        set { pendingManagedFocus.workspaceId = newValue }
    }

    var pendingFocusedMonitorId: Monitor.ID? {
        get { pendingManagedFocus.monitorId }
        set { pendingManagedFocus.monitorId = newValue }
    }

    init(
        focusedToken: WindowToken? = nil,
        pendingManagedFocus: PendingManagedFocusSnapshot,
        focusLease: FocusPolicyLease? = nil,
        isNonManagedFocusActive: Bool,
        isAppFullscreenActive: Bool,
        interactionMonitorId: Monitor.ID? = nil,
        previousInteractionMonitorId: Monitor.ID? = nil,
        nextManagedRequestId: UInt64 = 1,
        activeManagedRequest: ManagedFocusRequest? = nil
    ) {
        self.focusedToken = focusedToken
        self.pendingManagedFocus = pendingManagedFocus
        self.focusLease = focusLease
        self.isNonManagedFocusActive = isNonManagedFocusActive
        self.isAppFullscreenActive = isAppFullscreenActive
        self.interactionMonitorId = interactionMonitorId
        self.previousInteractionMonitorId = previousInteractionMonitorId
        self.nextManagedRequestId = nextManagedRequestId
        self.activeManagedRequest = activeManagedRequest
    }

    init(
        nextManagedRequestId: UInt64,
        activeManagedRequest: ManagedFocusRequest?,
        pendingFocusedToken: WindowToken?,
        pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?,
        isNonManagedFocusActive: Bool,
        isAppFullscreenActive: Bool
    ) {
        self.init(
            pendingManagedFocus: .init(
                token: pendingFocusedToken,
                workspaceId: pendingFocusedWorkspaceId,
                monitorId: nil
            ),
            isNonManagedFocusActive: isNonManagedFocusActive,
            isAppFullscreenActive: isAppFullscreenActive,
            nextManagedRequestId: nextManagedRequestId,
            activeManagedRequest: activeManagedRequest
        )
    }
}

struct WindowSnapshot: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let mode: TrackedWindowMode
    let lifecyclePhase: WindowLifecyclePhase
    let observedState: ObservedWindowState
    let desiredState: DesiredWindowState
    let restoreIntent: RestoreIntent?
    let replacementCorrelation: ReplacementCorrelation?
}

struct RefreshSnapshot: Equatable {
    var activeRefresh: ScheduledRefresh?
    var pendingRefresh: ScheduledRefresh?
}

struct WMSnapshot: Equatable {
    let topologyProfile: TopologyProfile
    var focusSession: FocusSessionSnapshot
    let windows: [WindowSnapshot]
    var refresh: RefreshSnapshot = .init()

    init(
        topologyProfile: TopologyProfile,
        focusSession: FocusSessionSnapshot,
        windows: [WindowSnapshot],
        refresh: RefreshSnapshot = .init()
    ) {
        self.topologyProfile = topologyProfile
        self.focusSession = focusSession
        self.windows = windows
        self.refresh = refresh
    }

    init(
        refresh: RefreshSnapshot,
        focus: FocusSessionSnapshot,
        topologyProfile: TopologyProfile = .empty,
        windows: [WindowSnapshot] = []
    ) {
        self.init(
            topologyProfile: topologyProfile,
            focusSession: focus,
            windows: windows,
            refresh: refresh
        )
    }

    var focus: FocusSessionSnapshot {
        get { focusSession }
        set { focusSession = newValue }
    }

    var nextManagedRequestId: UInt64 {
        get { focusSession.nextManagedRequestId }
        set { focusSession.nextManagedRequestId = newValue }
    }

    var activeManagedRequest: ManagedFocusRequest? {
        get { focusSession.activeManagedRequest }
        set { focusSession.activeManagedRequest = newValue }
    }

    var pendingFocusedToken: WindowToken? {
        get { focusSession.pendingFocusedToken }
        set { focusSession.pendingFocusedToken = newValue }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        get { focusSession.pendingFocusedWorkspaceId }
        set { focusSession.pendingFocusedWorkspaceId = newValue }
    }

    var isNonManagedFocusActive: Bool {
        get { focusSession.isNonManagedFocusActive }
        set { focusSession.isNonManagedFocusActive = newValue }
    }

    var isAppFullscreenActive: Bool {
        get { focusSession.isAppFullscreenActive }
        set { focusSession.isAppFullscreenActive = newValue }
    }

    var activeRefresh: ScheduledRefresh? {
        get { refresh.activeRefresh }
        set { refresh.activeRefresh = newValue }
    }

    var pendingRefresh: ScheduledRefresh? {
        get { refresh.pendingRefresh }
        set { refresh.pendingRefresh = newValue }
    }

    var focusedToken: WindowToken? { focusSession.focusedToken }
    var interactionMonitorId: Monitor.ID? { focusSession.interactionMonitorId }
    var previousInteractionMonitorId: Monitor.ID? { focusSession.previousInteractionMonitorId }
}

typealias ReconcileWindowSnapshot = WindowSnapshot
