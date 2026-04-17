import Foundation

struct FocusPlannerResult: Equatable {
    var snapshot: WMSnapshot
    var decision: ActionPlan.Decision
    var plan: ActionPlan
}

enum FocusPlanner {
    private enum ActivationDisposition {
        case matchesActive
        case conflictsWithPending
        case unrelated
    }

    private static let activationRetryLimit = 5

    static func step(
        snapshot: WMSnapshot,
        event: WMEvent
    ) -> FocusPlannerResult {
        switch event {
        case let .focusRequested(request):
            reduceRequest(snapshot: snapshot, request: request)
        case let .activationObserved(observation):
            reduceActivation(snapshot: snapshot, observation: observation)
        default:
            preconditionFailure("FocusPlanner received non-focus event \(event)")
        }
    }

    private static func reduceRequest(
        snapshot: WMSnapshot,
        request: ManagedFocusRequestEvent
    ) -> FocusPlannerResult {
        var updatedSnapshot = snapshot
        let requestId = snapshot.nextManagedRequestId
        let nextRequest = ManagedFocusRequest(
            requestId: requestId,
            token: request.token,
            workspaceId: request.workspaceId
        )

        if let activeRequest = snapshot.activeManagedRequest {
            if activeRequest.token == request.token,
               activeRequest.workspaceId == request.workspaceId
            {
                return .init(
                    snapshot: snapshot,
                    decision: .focusRequestIgnored(token: request.token),
                    plan: .init(actions: [
                        .beginManagedFocusRequest(
                            requestId: activeRequest.requestId,
                            token: request.token,
                            workspaceId: request.workspaceId
                        ),
                        .frontManagedWindow(
                            token: request.token,
                            workspaceId: request.workspaceId
                        ),
                    ])
                )
            }

            updatedSnapshot.activeManagedRequest = nextRequest
            updatedSnapshot.pendingFocusedToken = request.token
            updatedSnapshot.pendingFocusedWorkspaceId = request.workspaceId
            updatedSnapshot.nextManagedRequestId = requestId &+ 1

            return .init(
                snapshot: updatedSnapshot,
                decision: .focusRequestSuperseded(
                    replacedRequestId: activeRequest.requestId,
                    requestId: requestId,
                    token: request.token
                ),
                plan: .init(actions: [
                    .clearManagedFocusState(
                        requestId: activeRequest.requestId,
                        token: activeRequest.token,
                        workspaceId: activeRequest.workspaceId
                    ),
                    .beginManagedFocusRequest(
                        requestId: requestId,
                        token: request.token,
                        workspaceId: request.workspaceId
                    ),
                    .frontManagedWindow(
                        token: request.token,
                        workspaceId: request.workspaceId
                    ),
                ])
            )
        }

        updatedSnapshot.activeManagedRequest = nextRequest
        updatedSnapshot.pendingFocusedToken = request.token
        updatedSnapshot.pendingFocusedWorkspaceId = request.workspaceId
        updatedSnapshot.nextManagedRequestId = requestId &+ 1

        return .init(
            snapshot: updatedSnapshot,
            decision: .focusRequestAccepted(
                requestId: requestId,
                token: request.token
            ),
            plan: .init(actions: [
                .beginManagedFocusRequest(
                    requestId: requestId,
                    token: request.token,
                    workspaceId: request.workspaceId
                ),
                .frontManagedWindow(
                    token: request.token,
                    workspaceId: request.workspaceId
                ),
            ])
        )
    }

    private static func reduceActivation(
        snapshot: WMSnapshot,
        observation: ManagedActivationObservation
    ) -> FocusPlannerResult {
        var updatedSnapshot = snapshot
        var actions: [ActionPlan.Action] = []

        switch observation.match {
        case let .missingFocusedWindow(pid, fallbackFullscreen):
            switch activationDisposition(
                focus: snapshot,
                observation: observation
            ) {
            case .matchesActive, .conflictsWithPending:
                if shouldHonorObservedFocusOverPendingRequest(observation) {
                    if let request = updatedSnapshot.activeManagedRequest {
                        actions.append(
                            .clearManagedFocusState(
                                requestId: request.requestId,
                                token: request.token,
                                workspaceId: request.workspaceId
                            )
                        )
                    }
                    clearActiveManagedRequest(&updatedSnapshot)
                    clearPendingFocus(&updatedSnapshot)
                } else {
                    return deferManagedActivation(
                        snapshot: snapshot,
                        retryReason: .missingFocusedWindow,
                        source: observation.source,
                        origin: observation.origin
                    )
                }
            case .unrelated:
                break
            }

            clearActiveManagedRequest(&updatedSnapshot)
            updatedSnapshot.isNonManagedFocusActive = true
            updatedSnapshot.isAppFullscreenActive = fallbackFullscreen
            clearPendingFocus(&updatedSnapshot)
            actions.append(
                .enterNonManagedFallback(
                    pid: pid,
                    token: nil,
                    appFullscreen: fallbackFullscreen,
                    source: observation.source
                )
            )
            return .init(
                snapshot: updatedSnapshot,
                decision: .managedActivationFallback(pid: pid),
                plan: .init(actions: actions)
            )

        case let .managed(
            token,
            workspaceId,
            monitorId,
            isWorkspaceActive,
            appFullscreen,
            requiresNativeFullscreenRestoreRelayout
        ):
            switch activationDisposition(
                focus: snapshot,
                observation: observation
            ) {
            case .matchesActive:
                break
            case .conflictsWithPending:
                if shouldHonorObservedFocusOverPendingRequest(observation) {
                    if let request = updatedSnapshot.activeManagedRequest {
                        actions.append(
                            .clearManagedFocusState(
                                requestId: request.requestId,
                                token: request.token,
                                workspaceId: request.workspaceId
                            )
                        )
                    }
                    clearActiveManagedRequest(&updatedSnapshot)
                    clearPendingFocus(&updatedSnapshot)
                } else {
                    return deferManagedActivation(
                        snapshot: snapshot,
                        retryReason: .pendingFocusMismatch,
                        source: observation.source,
                        origin: observation.origin
                    )
                }
            case .unrelated:
                if !shouldHandleManagedActivationWithoutPendingRequest(observation) {
                    return .init(
                        snapshot: snapshot,
                        decision: .focusRequestIgnored(token: token),
                        plan: .init()
                    )
                }
            }

            if requiresNativeFullscreenRestoreRelayout {
                actions.append(
                    .beginNativeFullscreenRestoreActivation(
                        token: token,
                        workspaceId: workspaceId,
                        monitorId: monitorId,
                        isWorkspaceActive: isWorkspaceActive,
                        source: observation.source
                    )
                )
                clearActiveManagedRequest(&updatedSnapshot)
                updatedSnapshot.pendingFocusedToken = token
                updatedSnapshot.pendingFocusedWorkspaceId = workspaceId
            } else {
                actions.append(
                    .confirmManagedActivation(
                        token: token,
                        workspaceId: workspaceId,
                        monitorId: monitorId,
                        isWorkspaceActive: isWorkspaceActive,
                        appFullscreen: appFullscreen,
                        source: observation.source
                    )
                )
                clearActiveManagedRequest(&updatedSnapshot)
                clearPendingFocus(&updatedSnapshot)
                updatedSnapshot.isNonManagedFocusActive = false
                updatedSnapshot.isAppFullscreenActive = appFullscreen
            }

            return .init(
                snapshot: updatedSnapshot,
                decision: .managedActivationConfirmed(token: token),
                plan: .init(actions: actions)
            )

        case let .unmanaged(pid, token, _, fallbackFullscreen):
            switch activationDisposition(
                focus: snapshot,
                observation: observation
            ) {
            case .matchesActive, .conflictsWithPending:
                if shouldHonorObservedFocusOverPendingRequest(observation) {
                    if let request = updatedSnapshot.activeManagedRequest {
                        actions.append(
                            .clearManagedFocusState(
                                requestId: request.requestId,
                                token: request.token,
                                workspaceId: request.workspaceId
                            )
                        )
                    }
                    clearActiveManagedRequest(&updatedSnapshot)
                    clearPendingFocus(&updatedSnapshot)
                } else {
                    return deferManagedActivation(
                        snapshot: snapshot,
                        retryReason: .pendingFocusUnmanagedToken,
                        source: observation.source,
                        origin: observation.origin
                    )
                }
            case .unrelated:
                break
            }

            clearActiveManagedRequest(&updatedSnapshot)
            clearPendingFocus(&updatedSnapshot)
            updatedSnapshot.isNonManagedFocusActive = true
            updatedSnapshot.isAppFullscreenActive = fallbackFullscreen
            actions.append(
                .enterNonManagedFallback(
                    pid: pid,
                    token: token,
                    appFullscreen: fallbackFullscreen,
                    source: observation.source
                )
            )
            return .init(
                snapshot: updatedSnapshot,
                decision: .managedActivationFallback(pid: pid),
                plan: .init(actions: actions)
            )

        case let .ownedApplication(pid):
            if let request = updatedSnapshot.activeManagedRequest {
                if request.token.pid == pid {
                    actions.append(
                        .clearManagedFocusState(
                            requestId: request.requestId,
                            token: request.token,
                            workspaceId: request.workspaceId
                        )
                    )
                    clearActiveManagedRequest(&updatedSnapshot)
                    clearPendingFocus(&updatedSnapshot)
                }
            } else {
                clearPendingFocus(&updatedSnapshot)
                actions.append(.cancelActivationRetry(requestId: nil))
            }

            updatedSnapshot.isNonManagedFocusActive = true
            updatedSnapshot.isAppFullscreenActive = false
            actions.append(
                .enterOwnedApplicationFallback(
                    pid: pid,
                    source: observation.source
                )
            )
            return .init(
                snapshot: updatedSnapshot,
                decision: .managedActivationFallback(pid: pid),
                plan: .init(actions: actions)
            )
        }
    }

    private static func deferManagedActivation(
        snapshot: WMSnapshot,
        retryReason: ActivationRetryReason,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> FocusPlannerResult {
        guard let request = snapshot.activeManagedRequest else {
            return .init(
                snapshot: snapshot,
                decision: .managedActivationDeferred(requestId: 0, reason: retryReason),
                plan: .init()
            )
        }

        var updatedSnapshot = snapshot
        let nextAttempt = nextRetryCount(
            request: request,
            source: source,
            retryLimit: activationRetryLimit
        )

        if nextAttempt > activationRetryLimit {
            if origin == .probe {
                return .init(
                    snapshot: snapshot,
                    decision: .managedActivationDeferred(
                        requestId: request.requestId,
                        reason: retryReason
                    ),
                    plan: .init()
                )
            }

            clearActiveManagedRequest(&updatedSnapshot)
            clearPendingFocus(&updatedSnapshot)
            return .init(
                snapshot: updatedSnapshot,
                decision: .focusRequestCancelled(
                    requestId: request.requestId,
                    token: request.token
                ),
                plan: .init(actions: [
                    .clearManagedFocusState(
                        requestId: request.requestId,
                        token: request.token,
                        workspaceId: request.workspaceId
                    ),
                ])
            )
        }

        var updatedRequest = request
        updatedRequest.retryCount = nextAttempt
        updatedRequest.lastActivationSource = source
        updatedSnapshot.activeManagedRequest = updatedRequest

        return .init(
            snapshot: updatedSnapshot,
            decision: .managedActivationDeferred(
                requestId: updatedRequest.requestId,
                reason: retryReason
            ),
            plan: .init(actions: [
                .continueManagedFocusRequest(
                    requestId: updatedRequest.requestId,
                    reason: retryReason,
                    source: source,
                    origin: origin
                ),
            ])
        )
    }

    private static func activationDisposition(
        focus: WMSnapshot,
        observation: ManagedActivationObservation
    ) -> ActivationDisposition {
        guard let request = focus.activeManagedRequest else {
            return .unrelated
        }

        if request.token.pid != observation.pid {
            return .conflictsWithPending
        }
        guard let token = observation.token else {
            return .matchesActive
        }
        return request.token == token ? .matchesActive : .conflictsWithPending
    }

    private static func shouldHonorObservedFocusOverPendingRequest(
        _ observation: ManagedActivationObservation
    ) -> Bool {
        observation.source == .focusedWindowChanged
            && observation.origin == .external
    }

    private static func shouldHandleManagedActivationWithoutPendingRequest(
        _ observation: ManagedActivationObservation
    ) -> Bool {
        guard case let .managed(_, _, _, isWorkspaceActive, _, _) = observation.match else {
            return false
        }

        if isWorkspaceActive {
            return true
        }

        switch observation.source {
        case .focusedWindowChanged:
            return true
        case .workspaceDidActivateApplication, .cgsFrontAppChanged:
            return observation.origin == .external
        }
    }

    private static func nextRetryCount(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        retryLimit: Int
    ) -> Int {
        if request.lastActivationSource == source {
            return request.retryCount >= retryLimit
                ? retryLimit + 1
                : request.retryCount + 1
        }
        return 1
    }

    private static func clearActiveManagedRequest(
        _ snapshot: inout WMSnapshot
    ) {
        snapshot.activeManagedRequest = nil
    }

    private static func clearPendingFocus(
        _ snapshot: inout WMSnapshot
    ) {
        snapshot.pendingFocusedToken = nil
        snapshot.pendingFocusedWorkspaceId = nil
    }
}

private extension ManagedActivationObservation {
    var pid: pid_t {
        switch match {
        case let .missingFocusedWindow(pid, _):
            pid
        case let .managed(token, _, _, _, _, _):
            token.pid
        case let .unmanaged(pid, _, _, _):
            pid
        case let .ownedApplication(pid):
            pid
        }
    }

    var token: WindowToken? {
        switch match {
        case .missingFocusedWindow, .ownedApplication:
            nil
        case let .managed(token, _, _, _, _, _),
             let .unmanaged(_, token, _, _):
            token
        }
    }
}
