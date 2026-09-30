import AppKit
import SwiftUI
import QuartzCore
import ServiceManagement
import VellaCore

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
