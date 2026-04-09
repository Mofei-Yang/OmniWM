import Foundation
import Testing

@testable import OmniWM

private func makeOrchestrationRefresh(
    cycleId: RefreshCycleId,
    kind: ScheduledRefreshKind,
    reason: RefreshReason,
    affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
    postLayoutAttachmentIds: [RefreshAttachmentId] = [],
    windowRemovalPayload: WindowRemovalPayload? = nil
) -> ScheduledRefresh {
    ScheduledRefresh(
        cycleId: cycleId,
        kind: kind,
        reason: reason,
        affectedWorkspaceIds: affectedWorkspaceIds,
        postLayoutAttachmentIds: postLayoutAttachmentIds,
        windowRemovalPayload: windowRemovalPayload
    )
}

private func makeOrchestrationSnapshot(
    activeRefresh: ScheduledRefresh? = nil,
    pendingRefresh: ScheduledRefresh? = nil,
    nextManagedRequestId: UInt64 = 1,
    activeManagedRequest: ManagedFocusRequest? = nil,
    pendingFocusedToken: WindowToken? = nil,
    pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? = nil
) -> OrchestrationSnapshot {
    OrchestrationSnapshot(
        refresh: .init(
            activeRefresh: activeRefresh,
            pendingRefresh: pendingRefresh
        ),
        focus: .init(
            nextManagedRequestId: nextManagedRequestId,
            activeManagedRequest: activeManagedRequest,
            focusedTarget: nil,
            pendingFocusedToken: pendingFocusedToken,
            pendingFocusedWorkspaceId: pendingFocusedWorkspaceId,
            isNonManagedFocusActive: false,
            isAppFullscreenActive: false
        )
    )
}

@Test func fullRescanAbsorbsVisibilityRefreshIntoActiveCycle() {
    let workspaceId = WorkspaceDescriptor.ID()
    let activeRefresh = makeOrchestrationRefresh(
        cycleId: 10,
        kind: .fullRescan,
        reason: .startup
    )
    let incomingRefresh = makeOrchestrationRefresh(
        cycleId: 11,
        kind: .visibilityRefresh,
        reason: .appHidden,
        affectedWorkspaceIds: [workspaceId],
        postLayoutAttachmentIds: [99]
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(activeRefresh: activeRefresh),
        event: .refreshRequested(
            .init(
                refresh: incomingRefresh,
                shouldDropWhileBusy: false,
                isIncrementalRefreshInProgress: false,
                isImmediateLayoutInProgress: false,
                hasActiveAnimationRefreshes: false
            )
        )
    )

    #expect(result.decision == .refreshMerged(cycleId: 10, kind: .fullRescan))
    #expect(result.snapshot.refresh.activeRefresh?.cycleId == 10)
    #expect(result.snapshot.refresh.activeRefresh?.postLayoutAttachmentIds == [99])
    #expect(result.snapshot.refresh.activeRefresh?.needsVisibilityReconciliation == true)
    #expect(result.plan.actions.isEmpty)
}

@Test func cancelledWindowRemovalPreservesRemovalPayloadBeforeRestart() {
    let workspaceId = WorkspaceDescriptor.ID()
    let cancelledRefresh = makeOrchestrationRefresh(
        cycleId: 21,
        kind: .windowRemoval,
        reason: .windowDestroyed,
        postLayoutAttachmentIds: [5],
        windowRemovalPayload: .init(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: nil,
            niriOldFrames: [:],
            shouldRecoverFocus: true
        )
    )
    let queuedRefresh = makeOrchestrationRefresh(
        cycleId: 22,
        kind: .relayout,
        reason: .workspaceTransition
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            activeRefresh: cancelledRefresh,
            pendingRefresh: queuedRefresh
        ),
        event: .refreshCompleted(
            .init(
                refresh: cancelledRefresh,
                didComplete: false,
                didExecutePlan: false
            )
        )
    )

    guard let restartedRefresh = result.snapshot.refresh.activeRefresh else {
        Issue.record("expected a restarted refresh")
        return
    }

    #expect(result.decision == .refreshCompleted(cycleId: 21, didComplete: false))
    #expect(restartedRefresh.kind == .windowRemoval)
    #expect(restartedRefresh.windowRemovalPayloads.count == 1)
    #expect(restartedRefresh.postLayoutAttachmentIds == [5])
    #expect(result.plan.actions.contains(.startRefresh(restartedRefresh)))
}

@Test func focusRequestSupersedesExistingManagedRequest() {
    let firstWorkspace = WorkspaceDescriptor.ID()
    let secondWorkspace = WorkspaceDescriptor.ID()
    let oldToken = WindowToken(pid: 77, windowId: 1)
    let newToken = WindowToken(pid: 77, windowId: 2)
    let activeRequest = ManagedFocusRequest(
        requestId: 4,
        token: oldToken,
        workspaceId: firstWorkspace
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 9,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: oldToken,
            pendingFocusedWorkspaceId: firstWorkspace
        ),
        event: .focusRequested(
            .init(
                token: newToken,
                workspaceId: secondWorkspace
            )
        )
    )

    #expect(
        result.decision == .focusRequestSuperseded(
            replacedRequestId: 4,
            requestId: 9,
            token: newToken
        )
    )
    #expect(result.snapshot.focus.activeManagedRequest?.requestId == 9)
    #expect(result.snapshot.focus.pendingFocusedToken == newToken)
    #expect(
        result.plan.actions == [
            .clearManagedFocusState(
                token: oldToken,
                workspaceId: firstWorkspace
            ),
            .beginManagedFocusRequest(
                requestId: 9,
                token: newToken,
                workspaceId: secondWorkspace
            ),
            .frontManagedWindow(
                token: newToken,
                workspaceId: secondWorkspace
            )
        ]
    )
}

@Test func unmanagedActivationConflictDefersPendingFocusRequest() {
    let workspaceId = WorkspaceDescriptor.ID()
    let requestedToken = WindowToken(pid: 88, windowId: 3)
    let observedToken = WindowToken(pid: 88, windowId: 4)
    let activeRequest = ManagedFocusRequest(
        requestId: 7,
        token: requestedToken,
        workspaceId: workspaceId
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 8,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .workspaceDidActivateApplication,
                origin: .external,
                disposition: .conflictsWithPendingRequest(activeRequest),
                match: .unmanaged(
                    pid: observedToken.pid,
                    token: observedToken,
                    appFullscreen: false,
                    fallbackFullscreen: false
                ),
                shouldHonorObservedFocusOverPendingRequest: false,
                shouldHandleManagedActivationWithoutPendingRequest: false
            )
        )
    )

    #expect(
        result.decision == .managedActivationDeferred(
            requestId: 7,
            reason: .pendingFocusUnmanagedToken
        )
    )
    #expect(
        result.plan.actions == [
            .continueManagedFocusRequest(
                requestId: 7,
                reason: .pendingFocusUnmanagedToken,
                source: .workspaceDidActivateApplication,
                origin: .external
            )
        ]
    )
}

@Test func managedActivationUsesDedicatedNativeFullscreenRestoreAction() {
    let workspaceId = WorkspaceDescriptor.ID()
    let token = WindowToken(pid: 90, windowId: 5)
    let activeRequest = ManagedFocusRequest(
        requestId: 12,
        token: token,
        workspaceId: workspaceId
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 13,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: token,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .focusedWindowChanged,
                origin: .external,
                disposition: .matchesActiveRequest(activeRequest),
                match: .managed(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: nil,
                    isWorkspaceActive: true,
                    appFullscreen: false,
                    requiresNativeFullscreenRestoreRelayout: true
                ),
                shouldHonorObservedFocusOverPendingRequest: false,
                shouldHandleManagedActivationWithoutPendingRequest: false
            )
        )
    )

    #expect(result.decision == .managedActivationConfirmed(token: token))
    #expect(
        result.plan.actions == [
            .beginNativeFullscreenRestoreActivation(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                isWorkspaceActive: true,
                source: .focusedWindowChanged
            )
        ]
    )
}
