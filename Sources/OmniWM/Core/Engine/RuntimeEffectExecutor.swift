import Foundation

@MainActor
final class RuntimeEffectExecutor: EffectExecutor {
    func execute(
        _ result: CoordinationResult,
        on controller: WMController,
        context: RuntimeEffectContext
    ) {
        switch context {
        case .focusRequest:
            controller.applyRuntimeFocusRequestResult(result)

        case let .activationObserved(observedAXRef, managedEntry, source, confirmRequest):
            controller.axEventHandler.applyActivationCoordinationResult(
                result,
                observedAXRef: observedAXRef,
                managedEntry: managedEntry,
                source: source,
                confirmRequest: confirmRequest
            )

        case .refresh:
            controller.layoutRefreshController.applyRuntimeRefreshResult(result)
        }
    }
}
