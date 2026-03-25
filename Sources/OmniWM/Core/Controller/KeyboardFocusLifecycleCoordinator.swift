import Foundation

struct KeyboardFocusTarget {
    let token: WindowToken
    let axRef: AXWindowRef
    let workspaceId: WorkspaceDescriptor.ID?
    let isManaged: Bool

    var pid: pid_t { token.pid }
    var windowId: Int { token.windowId }
}

extension KeyboardFocusTarget: Equatable {
    static func == (lhs: KeyboardFocusTarget, rhs: KeyboardFocusTarget) -> Bool {
        lhs.token == rhs.token
            && lhs.workspaceId == rhs.workspaceId
            && lhs.isManaged == rhs.isManaged
    }
}

struct ManagedFocusRequest: Equatable {
    enum Status: Equatable {
        case pending
        case confirmed
    }

    let requestId: UInt64
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}

@MainActor
final class KeyboardFocusLifecycleCoordinator {
    private(set) var focusedTarget: KeyboardFocusTarget?
    private(set) var activeManagedRequest: ManagedFocusRequest?
    private var nextRequestId: UInt64 = 1

    func beginManagedRequest(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedFocusRequest {
        if let activeManagedRequest,
           activeManagedRequest.token == token,
           activeManagedRequest.workspaceId == workspaceId
        {
            return activeManagedRequest
        }

        let request = ManagedFocusRequest(
            requestId: nextRequestId,
            token: token,
            workspaceId: workspaceId
        )
        nextRequestId += 1
        activeManagedRequest = request
        return request
    }

    func activeManagedRequest(for pid: pid_t) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.token.pid == pid else {
            return nil
        }
        return activeManagedRequest
    }

    func activeManagedRequest(for token: WindowToken) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.token == token else {
            return nil
        }
        return activeManagedRequest
    }

    func activeManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.requestId == requestId else {
            return nil
        }
        return activeManagedRequest
    }

    func recordRetry(
        for token: WindowToken,
        source: ActivationEventSource,
        retryLimit: Int
    ) -> ManagedFocusRequest? {
        guard var activeManagedRequest, activeManagedRequest.token == token else {
            return nil
        }

        let nextAttempt = activeManagedRequest.retryCount + 1
        guard nextAttempt <= retryLimit else { return nil }

        activeManagedRequest.retryCount = nextAttempt
        activeManagedRequest.lastActivationSource = source
        self.activeManagedRequest = activeManagedRequest
        return activeManagedRequest
    }

    @discardableResult
    func confirmManagedRequest(
        token: WindowToken,
        source: ActivationEventSource
    ) -> ManagedFocusRequest? {
        guard var activeManagedRequest, activeManagedRequest.token == token else {
            return nil
        }

        activeManagedRequest.lastActivationSource = source
        activeManagedRequest.status = .confirmed
        self.activeManagedRequest = nil
        return activeManagedRequest
    }

    @discardableResult
    func cancelManagedRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> ManagedFocusRequest? {
        guard let activeManagedRequest else { return nil }

        let matchesToken = token.map { activeManagedRequest.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { activeManagedRequest.workspaceId == $0 } ?? true
        guard matchesToken, matchesWorkspace else { return nil }

        self.activeManagedRequest = nil
        return activeManagedRequest
    }

    @discardableResult
    func cancelManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.requestId == requestId else {
            return nil
        }
        self.activeManagedRequest = nil
        return activeManagedRequest
    }

    func rekeyManagedRequest(from oldToken: WindowToken, to newToken: WindowToken) {
        guard var activeManagedRequest, activeManagedRequest.token == oldToken else {
            return
        }
        activeManagedRequest.token = newToken
        self.activeManagedRequest = activeManagedRequest
    }

    func setFocusedTarget(_ target: KeyboardFocusTarget?) {
        focusedTarget = target
    }

    func clearFocusedTarget(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil
    ) {
        guard let focusedTarget else { return }

        let matchesToken = token.map { focusedTarget.token == $0 } ?? true
        let matchesPid = pid.map { focusedTarget.pid == $0 } ?? true
        guard matchesToken, matchesPid else { return }

        self.focusedTarget = nil
    }

    func rekeyFocusedTarget(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let focusedTarget, focusedTarget.token == oldToken else { return }
        self.focusedTarget = KeyboardFocusTarget(
            token: newToken,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: workspaceId != nil
        )
    }

    func updateFocusedTargetWorkspace(
        matching token: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let focusedTarget, focusedTarget.token == token else { return }

        self.focusedTarget = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: workspaceId != nil
        )
    }

    func reset() {
        focusedTarget = nil
        activeManagedRequest = nil
        nextRequestId = 1
    }
}
