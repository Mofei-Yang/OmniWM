import CoreGraphics
import Foundation

typealias RefreshCycleId = UInt64
typealias RefreshAttachmentId = UInt64

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

struct OrchestrationResult: Equatable {
    var snapshot: WMSnapshot
    var plan: ActionPlan

    init(
        snapshot: WMSnapshot,
        decision: ActionPlan.Decision,
        plan: ActionPlan
    ) {
        var plan = plan
        if plan.decision == nil {
            plan.decision = decision
        }
        self.snapshot = snapshot
        self.plan = plan
    }

    var decision: ActionPlan.Decision {
        guard let decision = plan.decision else {
            preconditionFailure("OrchestrationResult missing plan decision")
        }
        return decision
    }
}
