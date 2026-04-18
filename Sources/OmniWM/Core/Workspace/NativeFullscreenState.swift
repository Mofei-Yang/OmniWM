import Foundation

enum NativeFullscreenState {
    enum Transition: Equatable {
        case enterRequested
        case suspended
        case exitRequested
        case restoring
    }

    enum Availability: Equatable {
        case present
        case temporarilyUnavailable
    }

    struct Record {
        struct RestoreSnapshot: Equatable {
            let frame: CGRect
            let topologyProfile: TopologyProfile
            let niriState: ManagedWindowRestoreSnapshot.NiriState?
            let replacementMetadata: ManagedReplacementMetadata?

            init(
                frame: CGRect,
                topologyProfile: TopologyProfile,
                niriState: ManagedWindowRestoreSnapshot.NiriState? = nil,
                replacementMetadata: ManagedReplacementMetadata? = nil
            ) {
                self.frame = frame
                self.topologyProfile = topologyProfile
                self.niriState = niriState
                self.replacementMetadata = replacementMetadata
            }
        }

        struct RestoreFailure: Equatable {
            let path: String
            let detail: String
        }

        let originalToken: WindowToken
        var currentToken: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        var restoreSnapshot: RestoreSnapshot?
        var restoreFailure: RestoreFailure?
        var exitRequestedByCommand: Bool
        var transition: Transition
        var availability: Availability
        var unavailableSince: Date?
    }
}
