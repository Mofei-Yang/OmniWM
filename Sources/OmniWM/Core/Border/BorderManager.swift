import AppKit
import Foundation

@MainActor
final class BorderManager {
    private var borderWindow: BorderWindow?
    private var config: BorderConfig
    private var lastAppliedFrame: CGRect?
    private var lastAppliedWindowId: Int?
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init(config: BorderConfig = BorderConfig()) {
        self.config = config
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        if !enabled {
            hideBorder()
        }
    }

    func updateConfig(_ newConfig: BorderConfig) {
        let wasEnabled = config.enabled
        config = newConfig

        if !config.enabled, wasEnabled {
            hideBorder()
        } else if config.enabled {
            borderWindow?.updateConfig(config)
        }
    }

    func updateFocusedWindow(frame: CGRect, windowId: Int?) {
        guard config.enabled else { return }
        guard frame.width > 0, frame.height > 0 else {
            hideBorder()
            return
        }

        if let last = lastAppliedFrame,
           let lastWid = lastAppliedWindowId,
           lastWid == windowId,
           frame.approximatelyEqual(to: last, tolerance: 0.5) {
            return
        }

        if borderWindow == nil {
            borderWindow = BorderWindow(config: config)
        }

        guard let windowId else {
            borderWindow?.hide()
            lastAppliedFrame = nil
            lastAppliedWindowId = nil
            return
        }

        let targetWid = UInt32(windowId)
        borderWindow?.update(frame: frame, targetWid: targetWid)
        lastAppliedFrame = frame
        lastAppliedWindowId = windowId
        syncSurfaceRegistration()
    }

    func hideBorder() {
        borderWindow?.hide()
        lastAppliedFrame = nil
        lastAppliedWindowId = nil
        surfaceCoordinator.unregister(id: surfaceID)
    }

    var lastAppliedFocusedWindowIdForTests: Int? {
        lastAppliedWindowId
    }

    var lastAppliedFocusedFrameForTests: CGRect? {
        lastAppliedFrame
    }

    func cleanup() {
        hideBorder()
        borderWindow?.destroy()
        borderWindow = nil
        surfaceCoordinator.unregister(id: surfaceID)
    }

    private func syncSurfaceRegistration() {
        guard let borderWindow, let windowNumber = borderWindow.windowId.map(Int.init) else {
            surfaceCoordinator.unregister(id: surfaceID)
            return
        }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: windowNumber,
            frameProvider: { [weak self] in
                self?.lastAppliedFrame
            },
            visibilityProvider: { [weak self] in
                self?.lastAppliedFrame != nil && self?.config.enabled == true
            },
            policy: SurfacePolicy(
                kind: .border,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    private var surfaceID: String {
        "border-surface"
    }
}
