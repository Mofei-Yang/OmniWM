import CoreGraphics
import Foundation

enum ScheduledRefreshKind: Int, Equatable {
    case relayout
    case immediateRelayout
    case visibilityRefresh
    case windowRemoval
    case fullRescan
}

struct WindowRemovalPayload: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let layoutType: LayoutType
    let removedNodeId: NodeId?
    let niriOldFrames: [WindowToken: CGRect]
    let shouldRecoverFocus: Bool
}

struct FollowUpRefresh: Equatable {
    var kind: ScheduledRefreshKind
    var reason: RefreshReason
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
}

struct ScheduledRefresh: Equatable {
    var cycleId: RefreshCycleId
    var kind: ScheduledRefreshKind
    var reason: RefreshReason
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    var postLayoutAttachmentIds: [RefreshAttachmentId] = []
    var windowRemovalPayloads: [WindowRemovalPayload] = []
    var followUpRefresh: FollowUpRefresh?
    var needsVisibilityReconciliation: Bool = false
    var visibilityReason: RefreshReason?

    init(
        cycleId: RefreshCycleId,
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayoutAttachmentIds: [RefreshAttachmentId] = [],
        windowRemovalPayload: WindowRemovalPayload? = nil
    ) {
        self.cycleId = cycleId
        self.kind = kind
        self.reason = reason
        self.affectedWorkspaceIds = affectedWorkspaceIds
        self.postLayoutAttachmentIds = postLayoutAttachmentIds
        if let windowRemovalPayload {
            windowRemovalPayloads = [windowRemovalPayload]
        }
    }
}

enum OrchestrationDecision: Equatable {
    case refreshDropped(reason: RefreshReason)
    case refreshQueued(cycleId: RefreshCycleId, kind: ScheduledRefreshKind)
    case refreshMerged(cycleId: RefreshCycleId, kind: ScheduledRefreshKind)
    case refreshSuperseded(activeCycleId: RefreshCycleId, pendingCycleId: RefreshCycleId)
    case refreshCompleted(cycleId: RefreshCycleId, didComplete: Bool)
    case focusRequestAccepted(requestId: UInt64, token: WindowToken)
    case focusRequestSuperseded(replacedRequestId: UInt64, requestId: UInt64, token: WindowToken)
    case focusRequestContinued(requestId: UInt64, reason: ActivationRetryReason)
    case focusRequestCancelled(requestId: UInt64, token: WindowToken?)
    case focusRequestIgnored(token: WindowToken)
    case managedActivationConfirmed(token: WindowToken)
    case managedActivationDeferred(requestId: UInt64, reason: ActivationRetryReason)
    case managedActivationFallback(pid: pid_t)
}

struct OrchestrationPlan: Equatable {
    enum Action: Equatable {
        case cancelActiveRefresh(cycleId: RefreshCycleId)
        case startRefresh(ScheduledRefresh)
        case runPostLayoutAttachments([RefreshAttachmentId])
        case discardPostLayoutAttachments([RefreshAttachmentId])
        case performVisibilitySideEffects
        case requestWorkspaceBarRefresh
        case beginManagedFocusRequest(
            requestId: UInt64,
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID
        )
        case frontManagedWindow(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID
        )
        case clearManagedFocusState(
            requestId: UInt64,
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID?
        )
        case continueManagedFocusRequest(
            requestId: UInt64,
            reason: ActivationRetryReason,
            source: ActivationEventSource,
            origin: ActivationCallOrigin
        )
        case confirmManagedActivation(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID?,
            isWorkspaceActive: Bool,
            appFullscreen: Bool,
            source: ActivationEventSource
        )
        case beginNativeFullscreenRestoreActivation(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID?,
            isWorkspaceActive: Bool,
            source: ActivationEventSource
        )
        case enterNonManagedFallback(
            pid: pid_t,
            token: WindowToken?,
            appFullscreen: Bool,
            source: ActivationEventSource
        )
        case cancelActivationRetry(requestId: UInt64?)
        case enterOwnedApplicationFallback(
            pid: pid_t,
            source: ActivationEventSource
        )
    }

    var actions: [Action] = []
}

struct OrchestrationResult: Equatable {
    var snapshot: OrchestrationSnapshot
    var decision: OrchestrationDecision
    var plan: OrchestrationPlan
}
