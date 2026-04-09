import Foundation

struct RefreshRequestEvent: Equatable {
    var refresh: ScheduledRefresh
    var shouldDropWhileBusy: Bool
    var isIncrementalRefreshInProgress: Bool
    var isImmediateLayoutInProgress: Bool
    var hasActiveAnimationRefreshes: Bool
}

struct RefreshCompletionEvent: Equatable {
    var refresh: ScheduledRefresh
    var didComplete: Bool
    var didExecutePlan: Bool
}

struct ManagedFocusRequestEvent: Equatable {
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
}

enum ManagedActivationMatch: Equatable {
    case missingFocusedWindow(
        pid: pid_t,
        fallbackFullscreen: Bool
    )
    case managed(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        requiresNativeFullscreenRestoreRelayout: Bool
    )
    case unmanaged(
        pid: pid_t,
        token: WindowToken,
        appFullscreen: Bool,
        fallbackFullscreen: Bool
    )
    case ownedApplication(pid: pid_t)
}

struct ManagedActivationObservation: Equatable {
    var source: ActivationEventSource
    var origin: ActivationCallOrigin
    var match: ManagedActivationMatch
}

enum OrchestrationEvent: Equatable {
    case refreshRequested(RefreshRequestEvent)
    case refreshCompleted(RefreshCompletionEvent)
    case focusRequested(ManagedFocusRequestEvent)
    case activationObserved(ManagedActivationObservation)
}
