import AppKit
import SwiftUI
import VellaCore

enum TableSortColumn: CaseIterable {
    case name, wer, format, speed, energy, memory
    var metric: TableMetric? {
        switch self {
        case .name: return nil
        case .wer: return .wer
        case .format: return .format
        case .speed: return .speed
        case .energy: return .energy
        case .memory: return .memory
        }
    }
}
