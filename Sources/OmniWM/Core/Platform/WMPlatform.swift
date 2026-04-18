import AppKit
import ApplicationServices
import Foundation

@MainActor
struct WMPlatform {
    let activateApplication: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let raiseWindow: (AXUIElement) -> Void
    let closeWindow: (AXUIElement) -> Void
    let orderWindowAbove: (UInt32) -> Void
    let orderWindowRelative: (UInt32, UInt32, SkyLightWindowOrder) -> Void
    let visibleWindowInfo: () -> [WindowServerInfo]
    let windowInfo: (UInt32) -> WindowServerInfo?
    let cornerRadius: (Int) -> CGFloat?
    let axWindowRef: (UInt32, pid_t) -> AXWindowRef?
    let visibleOwnedWindows: () -> [NSWindow]
    let frontOwnedWindow: (NSWindow) -> Void
    let performMenuAction: (AXUIElement) -> Void

    static let shared = WMPlatform(
        activateApplication: { pid in
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: [])
            }
        },
        focusSpecificWindow: { pid, windowId, element in
            focusWindow(pid: pid, windowId: windowId, windowRef: element)
        },
        raiseWindow: { element in
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        },
        closeWindow: { element in
            var closeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
               let closeButton,
               CFGetTypeID(closeButton) == AXUIElementGetTypeID()
            {
                let closeElement = unsafeDowncast(closeButton, to: AXUIElement.self)
                AXUIElementPerformAction(closeElement, kAXPressAction as CFString)
            }
        },
        orderWindowAbove: { windowId in
            SkyLight.shared.orderWindow(windowId, relativeTo: 0, order: .above)
        },
        orderWindowRelative: { windowId, relativeTo, order in
            SkyLight.shared.orderWindow(windowId, relativeTo: relativeTo, order: order)
        },
        visibleWindowInfo: {
            SkyLight.shared.queryAllVisibleWindows()
        },
        windowInfo: { windowId in
            SkyLight.shared.queryWindowInfo(windowId)
        },
        cornerRadius: { windowId in
            SkyLight.shared.cornerRadius(forWindowId: windowId)
        },
        axWindowRef: { windowId, pid in
            AXWindowService.axWindowRef(for: windowId, pid: pid)
        },
        visibleOwnedWindows: {
            OwnedWindowRegistry.shared.visibleWindows(kind: .utility)
        },
        frontOwnedWindow: { window in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        },
        performMenuAction: { element in
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    )

    func windowTitle(_ windowId: UInt32) -> String? {
        SkyLight.shared.getWindowTitle(windowId)
    }

    func windowBounds(_ windowId: UInt32) -> CGRect? {
        SkyLight.shared.getWindowBounds(windowId)
    }

    func batchMoveWindows(_ positions: [(windowId: UInt32, origin: CGPoint)]) {
        SkyLight.shared.batchMoveWindows(positions)
    }

    func createBorderWindow(_ frame: CGRect) -> UInt32 {
        SkyLight.shared.createBorderWindow(frame: frame)
    }

    func releaseBorderWindow(_ windowId: UInt32) {
        SkyLight.shared.releaseBorderWindow(windowId)
    }

    func configureBorderWindow(_ windowId: UInt32, _ resolution: Float, _ opaque: Bool) {
        SkyLight.shared.configureWindow(windowId, resolution: resolution, opaque: opaque)
    }

    func setWindowTags(_ windowId: UInt32, _ tags: UInt64) {
        SkyLight.shared.setWindowTags(windowId, tags: tags)
    }

    func createWindowContext(_ windowId: UInt32) -> CGContext? {
        SkyLight.shared.createWindowContext(for: windowId)
    }

    func setWindowShape(_ windowId: UInt32, _ frame: CGRect) {
        SkyLight.shared.setWindowShape(windowId, frame: frame)
    }

    func flushWindow(_ windowId: UInt32) {
        SkyLight.shared.flushWindow(windowId)
    }

    func transactionMove(_ windowId: UInt32, _ origin: CGPoint) {
        SkyLight.shared.transactionMove(windowId, origin: origin)
    }

    func transactionMoveAndOrder(
        _ windowId: UInt32,
        _ origin: CGPoint,
        _ level: Int32,
        _ relativeTo: UInt32,
        _ order: SkyLightWindowOrder
    ) {
        SkyLight.shared.transactionMoveAndOrder(
            windowId,
            origin: origin,
            level: level,
            relativeTo: relativeTo,
            order: order
        )
    }

    func transactionHide(_ windowId: UInt32) {
        SkyLight.shared.transactionHide(windowId)
    }

    var windowFocusOperations: WindowFocusOperations {
        WindowFocusOperations(
            activateApp: activateApplication,
            focusSpecificWindow: focusSpecificWindow,
            raiseWindow: raiseWindow
        )
    }
}
