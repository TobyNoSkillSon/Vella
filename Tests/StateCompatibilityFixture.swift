// Standalone compiler regression: no package dependencies or macro plugin required.
// xcrun swiftc -typecheck -target arm64-apple-macosx14.0 Tests/StateCompatibilityFixture.swift
import SwiftUI

private enum FixturePhase { case idle, recording }

private struct StateCompatibilityFixture: View {
    // Kept identical to the production alias by state_compatibility_test.py.
    private typealias VellaState<Value> = SwiftUI.State<Value>

    @VellaState private var ascending = true
    @VellaState private var generation = 0
    @VellaState private var entered = Date()
    @VellaState private var finished: Date?
    @VellaState private var phase = FixturePhase.idle
    @VellaState private var level = 0.45

    // Require the actual SwiftUI DynamicProperty type and its Binding projection.
    private func requireState<T>(_ state: SwiftUI.State<T>) {}

    var body: some View {
        VStack {
            Toggle("Ascending", isOn: $ascending)
            Text("\(generation): \(level)")
            Button("Update") {
                requireState(_ascending)
                requireState(_generation)
                requireState(_entered)
                requireState(_finished)
                requireState(_phase)
                requireState(_level)
                ascending.toggle()
                generation += 1
                entered = Date()
                finished = entered
                phase = .recording
                level = 0.8
            }
        }
    }
}
