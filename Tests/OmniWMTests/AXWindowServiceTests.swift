import CoreGraphics
import Testing

@testable import OmniWM

@Suite struct AXWindowServiceTests {
    @Test func firefoxPictureInPictureForcesFloatingClassification() {
        #expect(
            AXWindowService.shouldForceFloatForBrowserPiP(
                bundleId: "org.mozilla.firefox",
                title: "Picture-in-Picture"
            )
        )
    }

    @Test func zenPictureInPictureForcesFloatingClassification() {
        #expect(
            AXWindowService.shouldForceFloatForBrowserPiP(
                bundleId: "app.zen-browser.zen",
                title: "Picture-in-Picture"
            )
        )
    }

    @Test func nonPictureInPictureFirefoxWindowDoesNotForceFloating() {
        #expect(
            !AXWindowService.shouldForceFloatForBrowserPiP(
                bundleId: "org.mozilla.firefox",
                title: "YouTube"
            )
        )
    }

    @Test func nonBrowserPictureInPictureWindowDoesNotForceFloating() {
        #expect(
            !AXWindowService.shouldForceFloatForBrowserPiP(
                bundleId: "com.apple.Safari",
                title: "Picture-in-Picture"
            )
        )
    }

    @Test func browserPictureInPictureMatchIsCaseSensitive() {
        #expect(
            !AXWindowService.shouldForceFloatForBrowserPiP(
                bundleId: "org.mozilla.firefox",
                title: "picture-in-picture"
            )
        )
    }

    @Test func browserPictureInPictureRequiresATitle() {
        #expect(
            !AXWindowService.shouldForceFloatForBrowserPiP(
                bundleId: "app.zen-browser.zen",
                title: nil
            )
        )
    }

    @Test func fullscreenEntryFromRightColumnUsesPositionThenSize() {
        let current = CGRect(x: 1276, y: 0, width: 1276, height: 1410)
        let target = CGRect(x: 0, y: 0, width: 2560, height: 1410)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .positionThenSize
        )
    }

    @Test func fullscreenEntryFromLeftColumnUsesPositionThenSize() {
        let current = CGRect(x: 8, y: 0, width: 1276, height: 1410)
        let target = CGRect(x: 0, y: 0, width: 2560, height: 1410)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .positionThenSize
        )
    }

    @Test func fullscreenEntryFromHalfHeightTileUsesPositionThenSize() {
        let current = CGRect(x: 8, y: 709, width: 1276, height: 701)
        let target = CGRect(x: 0, y: 0, width: 2560, height: 1410)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .positionThenSize
        )
    }

    @Test func fullscreenExitBackToTileUsesSizeThenPosition() {
        let current = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        let target = CGRect(x: 1276, y: 709, width: 1276, height: 701)

        #expect(
            AXWindowService.frameWriteOrder(currentFrame: current, targetFrame: target) == .sizeThenPosition
        )
    }
}
