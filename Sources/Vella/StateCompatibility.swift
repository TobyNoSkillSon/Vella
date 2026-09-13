import SwiftUI

// SDK 27's @State selects a macro whose plugin is absent from Command Line Tools.
// A distinct attribute name selects the original SwiftUI property wrapper instead.
// This is a typealias, not a replacement: SwiftUI still owns storage and bindings.
typealias VellaState<Value> = SwiftUI.State<Value>
