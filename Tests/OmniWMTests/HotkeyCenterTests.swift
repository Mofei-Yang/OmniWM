import Testing

@testable import OmniWM

@Suite struct HotkeyCenterTests {
    @Test func duplicateBindingsAcrossCommandsFailClosed() {
        let shared = KeyBinding(keyCode: 1, modifiers: 2)
        let unique = KeyBinding(keyCode: 3, modifiers: 4)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "move.left", command: .move(.left), bindings: [shared]),
                HotkeyBinding(id: "move.right", command: .move(.right), bindings: [shared]),
                HotkeyBinding(id: "focus.left", command: .focus(.left), bindings: [unique]),
            ]
        )

        #expect(plan.failures == [.move(.left), .move(.right)])
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: unique, command: .focus(.left))
        ])
    }

    @Test func duplicateBindingsWithinActionCollapseWithoutConflict() {
        let first = KeyBinding(keyCode: 10, modifiers: 20)
        let second = KeyBinding(keyCode: 11, modifiers: 21)
        var binding = HotkeyBinding(id: "move.left", command: .move(.left), bindings: [first])
        binding.bindings = [first, first, second]

        let plan = HotkeyCenter.registrationPlan(for: [binding])

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: first, command: .move(.left)),
            HotkeyPlannedRegistration(binding: second, command: .move(.left)),
        ])
    }

    @Test func commandKeepsUniqueBindingWhenOnlyOneBindingConflicts() {
        let shared = KeyBinding(keyCode: 30, modifiers: 40)
        let unique = KeyBinding(keyCode: 31, modifiers: 41)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "move.left", command: .move(.left), bindings: [shared, unique]),
                HotkeyBinding(id: "move.right", command: .move(.right), bindings: [shared]),
            ]
        )

        #expect(plan.failures == [.move(.left), .move(.right)])
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: unique, command: .move(.left))
        ])
    }
}
