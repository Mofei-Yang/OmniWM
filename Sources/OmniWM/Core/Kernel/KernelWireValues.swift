import Foundation

/// Preserved raw values for the remaining kernel wire formats. The numeric
/// assignments stay stable so older fixtures and traces continue to decode
/// while the remaining bridge consumers are retired. Do not reassign them.
enum KernelWire {
    enum WindowMode: UInt32 {
        case tiling = 0
        case floating = 1
    }

    enum Lifecycle: UInt32 {
        case discovered = 0
        case admitted = 1
        case tiled = 2
        case floating = 3
        case hidden = 4
        case offscreen = 5
        case restoring = 6
        case replacing = 7
        case nativeFullscreen = 8
        case destroyed = 9
    }

    enum ReplacementReason: UInt32 {
        case managedReplacement = 0
        case nativeFullscreen = 1
        case manualRekey = 2
    }

    enum HiddenStateWire: UInt32 {
        case visible = 0
        case hidden = 1
        case offscreenLeft = 2
        case offscreenRight = 3
    }

    enum Note: UInt32 {
        case none = 0
        case managedReplacementMetadataChanged = 1
        case topologyChanged = 2
        case activeSpaceChanged = 3
        case focusLeaseSet = 4
        case focusLeaseCleared = 5
        case systemSleep = 6
        case systemWake = 7
    }

    enum FocusLeaseAction: UInt32 {
        case keepExisting = 0
        case clear = 1
        case setFromEvent = 2
    }

    enum EventKind: UInt32 {
        case windowAdmitted = 0
        case windowRekeyed = 1
        case windowRemoved = 2
        case workspaceAssigned = 3
        case windowModeChanged = 4
        case floatingGeometryUpdated = 5
        case hiddenStateChanged = 6
        case nativeFullscreenTransition = 7
        case managedReplacementMetadataChanged = 8
        case topologyChanged = 9
        case activeSpaceChanged = 10
        case focusLeaseChanged = 11
        case managedFocusRequested = 12
        case managedFocusConfirmed = 13
        case managedFocusCancelled = 14
        case nonManagedFocusChanged = 15
        case systemSleep = 16
        case systemWake = 17
    }
}
