import AppKit
import ScreenCaptureKit

// MARK: - Controller


@MainActor
final class DragGhostController {
    private var ghostWindow: DragGhostWindow?
    private var captureTask: Task<Void, Never>?
    private var isActive: Bool = false
    private var swapTargetOverlay: SwapTargetOverlay?

    func beginDrag(windowId: Int, originalFrame: CGRect, cursorLocation: CGPoint) {
        isActive = true

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }

            let scaledSize = CGSize(
                width: originalFrame.width * 0.5,
                height: originalFrame.height * 0.5
            )

            if let thumbnail = await captureWindowThumbnail(windowId: windowId, targetSize: scaledSize) {
                guard isActive, !Task.isCancelled else { return }

                if ghostWindow == nil {
                    ghostWindow = DragGhostWindow()
                }

                ghostWindow?.setImage(thumbnail, size: scaledSize)
                ghostWindow?.showAt(cursorLocation: cursorLocation)
            }
        }
    }

    func updatePosition(cursorLocation: CGPoint) {
        guard isActive else { return }
        ghostWindow?.moveTo(cursorLocation: cursorLocation)
    }

    func endDrag() {
        isActive = false
        captureTask?.cancel()
        captureTask = nil
        ghostWindow?.hideGhost()
        hideSwapTarget()
    }

    func showSwapTarget(frame: CGRect) {
        guard isActive else { return }
        if swapTargetOverlay == nil {
            swapTargetOverlay = SwapTargetOverlay()
        }
        swapTargetOverlay?.show(at: frame)
    }

    func hideSwapTarget() {
        swapTargetOverlay?.hide()
    }

    private func captureWindowThumbnail(windowId: Int, targetSize: CGSize) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowId) }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(targetSize.width)
            config.height = Int(targetSize.height)
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = true

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            return nil
        }
    }
}


// MARK: - Window


@MainActor
final class DragGhostWindow: NSPanel {
    private let imageView: NSImageView

    init() {
        imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        alphaValue = 0.5

        contentView = imageView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func setImage(_ image: CGImage, size: CGSize) {
        let nsImage = NSImage(cgImage: image, size: size)
        imageView.image = nsImage
        setFrame(CGRect(origin: frame.origin, size: size), display: false)
        imageView.frame = CGRect(origin: .zero, size: size)
    }

    func moveTo(cursorLocation: CGPoint) {
        let origin = CGPoint(
            x: cursorLocation.x + 10,
            y: cursorLocation.y - frame.height - 10
        )
        setFrameOrigin(origin)
    }

    func showAt(cursorLocation: CGPoint) {
        moveTo(cursorLocation: cursorLocation)
        orderFront(nil)
    }

    func hideGhost() {
        orderOut(nil)
    }
}

