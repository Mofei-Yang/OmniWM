import Foundation

enum OrchestrationCore {
    static func step(
        snapshot: OrchestrationSnapshot,
        event: OrchestrationEvent
    ) -> OrchestrationResult {
        switch event {
        case let .refreshRequested(request):
            reduceRefreshRequest(snapshot: snapshot, request: request)
        case let .refreshCompleted(completion):
            reduceRefreshCompletion(snapshot: snapshot, completion: completion)
        case let .focusRequested(request):
            reduceFocusRequest(snapshot: snapshot, request: request)
        case let .activationObserved(observation):
            reduceActivation(snapshot: snapshot, observation: observation)
        }
    }

    private static func reduceRefreshRequest(
        snapshot: OrchestrationSnapshot,
        request: RefreshRequestEvent
    ) -> OrchestrationResult {
        var snapshot = snapshot
        var plan = OrchestrationPlan()

        if request.shouldDropWhileBusy,
           request.isIncrementalRefreshInProgress || request.isImmediateLayoutInProgress || request.hasActiveAnimationRefreshes
        {
            return OrchestrationResult(
                snapshot: snapshot,
                decision: .refreshDropped(reason: request.refresh.reason),
                plan: plan
            )
        }

        if let activeRefresh = snapshot.refresh.activeRefresh {
            let handling = handleRefresh(
                request.refresh,
                activeRefresh: activeRefresh,
                pendingRefresh: snapshot.refresh.pendingRefresh
            )
            snapshot.refresh.activeRefresh = handling.activeRefresh
            snapshot.refresh.pendingRefresh = handling.pendingRefresh
            plan.actions.append(contentsOf: handling.actions)
            return OrchestrationResult(
                snapshot: snapshot,
                decision: handling.decision,
                plan: plan
            )
        }

        let mergedPending = mergePendingRefresh(snapshot.refresh.pendingRefresh, with: request.refresh)
        snapshot.refresh.pendingRefresh = nil
        snapshot.refresh.activeRefresh = mergedPending.refresh
        plan.actions.append(contentsOf: mergedPending.actions)
        plan.actions.append(.startRefresh(mergedPending.refresh))
        let decision: OrchestrationDecision = snapshot.refresh.activeRefresh == request.refresh
            ? .refreshQueued(cycleId: request.refresh.cycleId, kind: request.refresh.kind)
            : .refreshMerged(cycleId: mergedPending.refresh.cycleId, kind: mergedPending.refresh.kind)
        return OrchestrationResult(snapshot: snapshot, decision: decision, plan: plan)
    }

    private static func reduceRefreshCompletion(
        snapshot: OrchestrationSnapshot,
        completion: RefreshCompletionEvent
    ) -> OrchestrationResult {
        var snapshot = snapshot
        var plan = OrchestrationPlan()
        let completedRefresh = snapshot.refresh.activeRefresh ?? completion.refresh
        snapshot.refresh.activeRefresh = nil

        if completion.didComplete {
            if completion.didExecutePlan {
                if !completedRefresh.postLayoutAttachmentIds.isEmpty {
                    plan.actions.append(.discardPostLayoutAttachments(completedRefresh.postLayoutAttachmentIds))
                }
            } else {
                if completedRefresh.kind != .visibilityRefresh, completedRefresh.needsVisibilityReconciliation {
                    plan.actions.append(.performVisibilitySideEffects)
                    plan.actions.append(.requestWorkspaceBarRefresh)
                }
                if !completedRefresh.postLayoutAttachmentIds.isEmpty {
                    plan.actions.append(.runPostLayoutAttachments(completedRefresh.postLayoutAttachmentIds))
                }
            }

            if let followUpRefresh = completedRefresh.followUpRefresh {
                let followUp = ScheduledRefresh(
                    cycleId: completedRefresh.cycleId &+ 1,
                    kind: followUpRefresh.kind,
                    reason: followUpRefresh.reason,
                    affectedWorkspaceIds: followUpRefresh.affectedWorkspaceIds
                )
                snapshot.refresh.pendingRefresh = mergePendingRefresh(snapshot.refresh.pendingRefresh, with: followUp).refresh
            }
        } else {
            snapshot.refresh.pendingRefresh = preserveCancelledRefreshState(
                cancelledRefresh: completedRefresh,
                pendingRefresh: snapshot.refresh.pendingRefresh
            )
        }

        if let nextRefresh = snapshot.refresh.pendingRefresh {
            snapshot.refresh.pendingRefresh = nil
            snapshot.refresh.activeRefresh = nextRefresh
            plan.actions.append(.startRefresh(nextRefresh))
        }

        return OrchestrationResult(
            snapshot: snapshot,
            decision: .refreshCompleted(cycleId: completedRefresh.cycleId, didComplete: completion.didComplete),
            plan: plan
        )
    }

    private static func reduceFocusRequest(
        snapshot: OrchestrationSnapshot,
        request: ManagedFocusRequestEvent
    ) -> OrchestrationResult {
        var snapshot = snapshot
        var plan = OrchestrationPlan()
        let requestId = snapshot.focus.nextManagedRequestId
        let nextRequest = ManagedFocusRequest(
            requestId: requestId,
            token: request.token,
            workspaceId: request.workspaceId
        )

        if let activeRequest = snapshot.focus.activeManagedRequest {
            if activeRequest.token == request.token, activeRequest.workspaceId == request.workspaceId {
                plan.actions.append(
                    .beginManagedFocusRequest(
                        requestId: activeRequest.requestId,
                        token: request.token,
                        workspaceId: request.workspaceId
                    )
                )
                plan.actions.append(
                    .frontManagedWindow(
                        token: request.token,
                        workspaceId: request.workspaceId
                    )
                )
                return OrchestrationResult(
                    snapshot: snapshot,
                    decision: .focusRequestIgnored(token: request.token),
                    plan: plan
                )
            }

            plan.actions.append(
                .clearManagedFocusState(
                    token: activeRequest.token,
                    workspaceId: activeRequest.workspaceId
                )
            )
            plan.actions.append(
                .beginManagedFocusRequest(
                    requestId: requestId,
                    token: request.token,
                    workspaceId: request.workspaceId
                )
            )
            plan.actions.append(
                .frontManagedWindow(
                    token: request.token,
                    workspaceId: request.workspaceId
                )
            )
            snapshot.focus.activeManagedRequest = nextRequest
            snapshot.focus.pendingFocusedToken = request.token
            snapshot.focus.pendingFocusedWorkspaceId = request.workspaceId
            snapshot.focus.nextManagedRequestId = requestId &+ 1
            return OrchestrationResult(
                snapshot: snapshot,
                decision: .focusRequestSuperseded(
                    replacedRequestId: activeRequest.requestId,
                    requestId: requestId,
                    token: request.token
                ),
                plan: plan
            )
        }

        plan.actions.append(
            .beginManagedFocusRequest(
                requestId: requestId,
                token: request.token,
                workspaceId: request.workspaceId
            )
        )
        plan.actions.append(
            .frontManagedWindow(
                token: request.token,
                workspaceId: request.workspaceId
            )
        )
        snapshot.focus.activeManagedRequest = nextRequest
        snapshot.focus.pendingFocusedToken = request.token
        snapshot.focus.pendingFocusedWorkspaceId = request.workspaceId
        snapshot.focus.nextManagedRequestId = requestId &+ 1
        return OrchestrationResult(
            snapshot: snapshot,
            decision: .focusRequestAccepted(requestId: requestId, token: request.token),
            plan: plan
        )
    }

    private static func reduceActivation(
        snapshot: OrchestrationSnapshot,
        observation: ManagedActivationObservation
    ) -> OrchestrationResult {
        var snapshot = snapshot
        var plan = OrchestrationPlan()

        switch observation.match {
        case let .missingFocusedWindow(pid, fallbackFullscreen):
            switch observation.disposition {
            case let .matchesActiveRequest(request), let .conflictsWithPendingRequest(request):
                if observation.shouldHonorObservedFocusOverPendingRequest {
                    plan.actions.append(
                        .clearManagedFocusState(
                            token: request.token,
                            workspaceId: request.workspaceId
                        )
                    )
                    snapshot.focus.activeManagedRequest = nil
                    snapshot.focus.pendingFocusedToken = nil
                    snapshot.focus.pendingFocusedWorkspaceId = nil
                } else {
                    plan.actions.append(
                        .continueManagedFocusRequest(
                            requestId: request.requestId,
                            reason: .missingFocusedWindow,
                            source: observation.source,
                            origin: observation.origin
                        )
                    )
                    return OrchestrationResult(
                        snapshot: snapshot,
                        decision: .managedActivationDeferred(
                            requestId: request.requestId,
                            reason: .missingFocusedWindow
                        ),
                        plan: plan
                    )
                }
            case .unrelatedNoRequest:
                break
            }

            snapshot.focus.activeManagedRequest = nil
            snapshot.focus.focusedTarget = nil
            snapshot.focus.isNonManagedFocusActive = true
            snapshot.focus.isAppFullscreenActive = fallbackFullscreen
            snapshot.focus.pendingFocusedToken = nil
            snapshot.focus.pendingFocusedWorkspaceId = nil
            plan.actions.append(
                .enterNonManagedFallback(
                    pid: pid,
                    token: nil,
                    appFullscreen: fallbackFullscreen,
                    source: observation.source
                )
            )
            return OrchestrationResult(
                snapshot: snapshot,
                decision: .managedActivationFallback(pid: pid),
                plan: plan
            )

        case let .managed(token, workspaceId, monitorId, isWorkspaceActive, appFullscreen, requiresNativeFullscreenRestoreRelayout):
            switch observation.disposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                if observation.shouldHonorObservedFocusOverPendingRequest {
                    plan.actions.append(
                        .clearManagedFocusState(
                            token: request.token,
                            workspaceId: request.workspaceId
                        )
                    )
                    snapshot.focus.activeManagedRequest = nil
                    snapshot.focus.pendingFocusedToken = nil
                    snapshot.focus.pendingFocusedWorkspaceId = nil
                } else {
                    plan.actions.append(
                        .continueManagedFocusRequest(
                            requestId: request.requestId,
                            reason: .pendingFocusMismatch,
                            source: observation.source,
                            origin: observation.origin
                        )
                    )
                    return OrchestrationResult(
                        snapshot: snapshot,
                        decision: .managedActivationDeferred(
                            requestId: request.requestId,
                            reason: .pendingFocusMismatch
                        ),
                        plan: plan
                    )
                }
            case .unrelatedNoRequest:
                guard observation.shouldHandleManagedActivationWithoutPendingRequest else {
                    return OrchestrationResult(
                        snapshot: snapshot,
                        decision: .focusRequestIgnored(token: token),
                        plan: plan
                    )
                }
            }

            if requiresNativeFullscreenRestoreRelayout {
                plan.actions.append(
                    .beginNativeFullscreenRestoreActivation(
                        token: token,
                        workspaceId: workspaceId,
                        monitorId: monitorId,
                        isWorkspaceActive: isWorkspaceActive,
                        source: observation.source
                    )
                )
            } else {
                plan.actions.append(
                    .confirmManagedActivation(
                        token: token,
                        workspaceId: workspaceId,
                        monitorId: monitorId,
                        isWorkspaceActive: isWorkspaceActive,
                        appFullscreen: appFullscreen,
                        source: observation.source
                    )
                )
            }

            snapshot.focus.activeManagedRequest = nil
            snapshot.focus.pendingFocusedToken = nil
            snapshot.focus.pendingFocusedWorkspaceId = nil
            snapshot.focus.isNonManagedFocusActive = false
            snapshot.focus.isAppFullscreenActive = appFullscreen
            return OrchestrationResult(
                snapshot: snapshot,
                decision: .managedActivationConfirmed(token: token),
                plan: plan
            )

        case let .unmanaged(pid, token, _, fallbackFullscreen):
            switch observation.disposition {
            case let .matchesActiveRequest(request), let .conflictsWithPendingRequest(request):
                if observation.shouldHonorObservedFocusOverPendingRequest {
                    plan.actions.append(
                        .clearManagedFocusState(
                            token: request.token,
                            workspaceId: request.workspaceId
                        )
                    )
                    snapshot.focus.activeManagedRequest = nil
                    snapshot.focus.pendingFocusedToken = nil
                    snapshot.focus.pendingFocusedWorkspaceId = nil
                } else {
                    plan.actions.append(
                        .continueManagedFocusRequest(
                            requestId: request.requestId,
                            reason: .pendingFocusUnmanagedToken,
                            source: observation.source,
                            origin: observation.origin
                        )
                    )
                    return OrchestrationResult(
                        snapshot: snapshot,
                        decision: .managedActivationDeferred(
                            requestId: request.requestId,
                            reason: .pendingFocusUnmanagedToken
                        ),
                        plan: plan
                    )
                }
            case .unrelatedNoRequest:
                break
            }

            snapshot.focus.activeManagedRequest = nil
            snapshot.focus.pendingFocusedToken = nil
            snapshot.focus.pendingFocusedWorkspaceId = nil
            snapshot.focus.isNonManagedFocusActive = true
            snapshot.focus.isAppFullscreenActive = fallbackFullscreen
            plan.actions.append(
                .enterNonManagedFallback(
                    pid: pid,
                    token: token,
                    appFullscreen: fallbackFullscreen,
                    source: observation.source
                )
            )
            return OrchestrationResult(
                snapshot: snapshot,
                decision: .managedActivationFallback(pid: pid),
                plan: plan
            )
        }
    }

    private static func handleRefresh(
        _ refresh: ScheduledRefresh,
        activeRefresh: ScheduledRefresh,
        pendingRefresh: ScheduledRefresh?
    ) -> (
        activeRefresh: ScheduledRefresh,
        pendingRefresh: ScheduledRefresh?,
        actions: [OrchestrationPlan.Action],
        decision: OrchestrationDecision
    ) {
        var activeRefresh = activeRefresh
        var pendingRefresh = pendingRefresh
        var actions: [OrchestrationPlan.Action] = []

        switch (activeRefresh.kind, refresh.kind) {
        case (.fullRescan, .visibilityRefresh):
            activeRefresh = absorbIntoActiveFullRescan(activeRefresh, refresh: refresh)
            return (
                activeRefresh,
                pendingRefresh,
                actions,
                .refreshMerged(cycleId: activeRefresh.cycleId, kind: activeRefresh.kind)
            )
        case (.fullRescan, .fullRescan),
             (.fullRescan, .windowRemoval),
             (.fullRescan, .immediateRelayout),
             (.fullRescan, .relayout),
             (.visibilityRefresh, .visibilityRefresh),
             (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout),
             (.windowRemoval, .fullRescan),
             (.windowRemoval, .windowRemoval),
             (.windowRemoval, .immediateRelayout),
             (.windowRemoval, .relayout),
             (.windowRemoval, .visibilityRefresh),
             (.immediateRelayout, .relayout),
             (.immediateRelayout, .visibilityRefresh),
             (.relayout, .visibilityRefresh):
            pendingRefresh = mergePendingRefresh(pendingRefresh, with: refresh).refresh
        case (.immediateRelayout, .fullRescan),
             (.immediateRelayout, .immediateRelayout),
             (.immediateRelayout, .windowRemoval),
             (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .relayout),
             (.relayout, .windowRemoval):
            pendingRefresh = mergePendingRefresh(pendingRefresh, with: refresh).refresh
            actions.append(.cancelActiveRefresh(cycleId: activeRefresh.cycleId))
            return (
                activeRefresh,
                pendingRefresh,
                actions,
                .refreshSuperseded(
                    activeCycleId: activeRefresh.cycleId,
                    pendingCycleId: pendingRefresh?.cycleId ?? refresh.cycleId
                )
            )
        }

        return (
            activeRefresh,
            pendingRefresh,
            actions,
            .refreshMerged(
                cycleId: pendingRefresh?.cycleId ?? activeRefresh.cycleId,
                kind: pendingRefresh?.kind ?? activeRefresh.kind
            )
        )
    }

    private static func absorbIntoActiveFullRescan(
        _ activeRefresh: ScheduledRefresh,
        refresh: ScheduledRefresh
    ) -> ScheduledRefresh {
        var activeRefresh = activeRefresh
        activeRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
        mergeAbsorbedVisibility(into: &activeRefresh, from: refresh)
        return activeRefresh
    }

    private static func mergePendingRefresh(
        _ pendingRefresh: ScheduledRefresh?,
        with refresh: ScheduledRefresh
    ) -> (refresh: ScheduledRefresh, actions: [OrchestrationPlan.Action]) {
        guard var pendingRefresh else {
            return (refresh, [])
        }

        let existingAffectedWorkspaceIds = pendingRefresh.affectedWorkspaceIds

        switch (pendingRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.fullRescan, _):
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            var upgradedRefresh = refresh
            upgradedRefresh.cycleId = pendingRefresh.cycleId
            upgradedRefresh.postLayoutAttachmentIds.append(contentsOf: pendingRefresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.visibilityRefresh, .visibilityRefresh):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
        case (.windowRemoval, .fullRescan),
             (.immediateRelayout, .fullRescan),
             (.relayout, .fullRescan):
            var upgradedRefresh = refresh
            upgradedRefresh.cycleId = pendingRefresh.cycleId
            upgradedRefresh.postLayoutAttachmentIds.append(contentsOf: pendingRefresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.windowRemoval, .windowRemoval):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.windowRemovalPayloads += refresh.windowRemovalPayloads
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .immediateRelayout):
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .immediateRelayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .relayout):
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .visibilityRefresh):
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.cycleId = pendingRefresh.cycleId
            upgradedRefresh.postLayoutAttachmentIds.append(contentsOf: pendingRefresh.postLayoutAttachmentIds)
            upgradedRefresh.followUpRefresh = pendingRefresh.followUpRefresh
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .immediateRelayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.relayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.cycleId = pendingRefresh.cycleId
            upgradedRefresh.postLayoutAttachmentIds.append(contentsOf: pendingRefresh.postLayoutAttachmentIds)
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.immediateRelayout, .visibilityRefresh),
             (.relayout, .visibilityRefresh):
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .immediateRelayout),
             (.relayout, .relayout):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .relayout):
            pendingRefresh.postLayoutAttachmentIds.append(contentsOf: refresh.postLayoutAttachmentIds)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.relayout, .immediateRelayout):
            var upgradedRefresh = refresh
            upgradedRefresh.cycleId = pendingRefresh.cycleId
            upgradedRefresh.postLayoutAttachmentIds.append(contentsOf: pendingRefresh.postLayoutAttachmentIds)
            upgradedRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        }

        pendingRefresh.affectedWorkspaceIds.formUnion(existingAffectedWorkspaceIds)
        pendingRefresh.affectedWorkspaceIds.formUnion(refresh.affectedWorkspaceIds)

        return (pendingRefresh, [])
    }

    private static func preserveCancelledRefreshState(
        cancelledRefresh: ScheduledRefresh,
        pendingRefresh: ScheduledRefresh?
    ) -> ScheduledRefresh {
        guard var pendingRefresh else {
            return cancelledRefresh
        }

        if !cancelledRefresh.postLayoutAttachmentIds.isEmpty {
            pendingRefresh.postLayoutAttachmentIds.insert(
                contentsOf: cancelledRefresh.postLayoutAttachmentIds,
                at: 0
            )
        }

        pendingRefresh.affectedWorkspaceIds.formUnion(cancelledRefresh.affectedWorkspaceIds)

        if cancelledRefresh.kind == .windowRemoval, !cancelledRefresh.windowRemovalPayloads.isEmpty {
            pendingRefresh.windowRemovalPayloads = cancelledRefresh.windowRemovalPayloads + pendingRefresh.windowRemovalPayloads
            if pendingRefresh.kind != .fullRescan, pendingRefresh.kind != .windowRemoval {
                pendingRefresh.kind = .windowRemoval
                pendingRefresh.reason = cancelledRefresh.reason
            }
        }

        mergeAbsorbedVisibility(into: &pendingRefresh, from: cancelledRefresh)
        pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
            cancelledRefresh.followUpRefresh,
            with: pendingRefresh.followUpRefresh
        )

        return pendingRefresh
    }

    private static func mergeFollowUp(
        into refresh: inout ScheduledRefresh,
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        refresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: .init(kind: kind, reason: reason, affectedWorkspaceIds: affectedWorkspaceIds)
        )
    }

    private static func mergeAbsorbedVisibility(
        into refresh: inout ScheduledRefresh,
        from incoming: ScheduledRefresh
    ) {
        switch incoming.kind {
        case .visibilityRefresh:
            refresh.needsVisibilityReconciliation = true
            refresh.visibilityReason = incoming.reason
        case .fullRescan, .windowRemoval, .immediateRelayout, .relayout:
            guard incoming.needsVisibilityReconciliation else { return }
            refresh.needsVisibilityReconciliation = true
            refresh.visibilityReason = incoming.visibilityReason ?? refresh.visibilityReason
        }
    }

    private static func mergeFollowUpRefresh(
        _ existing: FollowUpRefresh?,
        with incoming: FollowUpRefresh?
    ) -> FollowUpRefresh? {
        switch (existing, incoming) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (existing?, incoming?):
            var merged = incoming
            merged.affectedWorkspaceIds.formUnion(existing.affectedWorkspaceIds)
            if existing.kind == .immediateRelayout || incoming.kind == .immediateRelayout {
                if incoming.kind == .immediateRelayout {
                    return merged
                }
                var kept = existing
                kept.affectedWorkspaceIds.formUnion(incoming.affectedWorkspaceIds)
                return kept
            }
            return merged
        }
    }
}
