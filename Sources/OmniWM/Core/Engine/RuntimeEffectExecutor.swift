import Foundation

@MainActor
final class RuntimeEffectExecutor: EffectExecutor {
    func execute(
        _ result: OrchestrationResult,
        on controller: WMController,
        context: RuntimeEffectContext
    ) {
        switch context {
        case .focusRequest:
            controller.applyRuntimeFocusRequestResult(result)

        case let .activationObserved(observedAXRef, managedEntry, source, confirmRequest):
            controller.axEventHandler.applyActivationOrchestrationResult(
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
