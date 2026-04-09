import Foundation

typealias RefreshCycleId = UInt64
typealias RefreshAttachmentId = UInt64

struct RefreshOrchestrationSnapshot: Equatable {
    var activeRefresh: ScheduledRefresh?
    var pendingRefresh: ScheduledRefresh?
}

struct FocusOrchestrationSnapshot: Equatable {
    var nextManagedRequestId: UInt64
    var activeManagedRequest: ManagedFocusRequest?
    var focusedTarget: KeyboardFocusTarget?
    var pendingFocusedToken: WindowToken?
    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    var isNonManagedFocusActive: Bool
    var isAppFullscreenActive: Bool
}

struct OrchestrationSnapshot: Equatable {
    var refresh: RefreshOrchestrationSnapshot
    var focus: FocusOrchestrationSnapshot
}
