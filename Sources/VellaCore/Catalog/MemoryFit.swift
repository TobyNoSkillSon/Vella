import Foundation

// Which precisions this Mac's memory can hold (the Models table, the runtime and the API ask the same rule through
// `SelectionRules`). Admission (Residency.swift) asks whether a load fits in the memory free right now; this asks
// whether the Mac could ever run the precision without crowding out macOS and the apps beside it.
//
//     floor = the smallest Apple silicon memory size (GB, as sold) with  peak + 16 GB ≤ it
//
// 16 GB stays with macOS and the apps beside the model. `peak` is the catalog's `peakMemoryMB` (peak process memory
// while transcribing); a precision without one has no floor (every model under 10 GB). Nemotron 3.5 Transcribe:
// int4 24.1 GB → 48 GB, int8 37.5 GB → 64 GB, bf16 65.3 GB → 96 GB (catalog peaks).

/// Memory sizes Apple silicon Macs ship with, in GB (binary gigabytes, as `physicalMemory` reports them).
public let appleSiliconMemorySizesGB = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]
/// Memory left to macOS and other apps beside one model's peak, in GB (binary).
public let systemMemoryReserveGB = 16.0
private let gibibyte = 1_073_741_824.0

/// The memory floor for a peak in MB (1e6 bytes); nil when even the largest size is too small.
public func minimumMemoryGB(peakMB: Double) -> Int? {
    appleSiliconMemorySizesGB.first { peakMB * 1e6 + systemMemoryReserveGB * gibibyte <= Double($0) * gibibyte }
}

/// The physical memory a precision needs, in GB (Int.max: more than any Mac); nil = no floor.
public func minimumMemoryGB(_ family: ModelFamily, _ label: String) -> Int? {
    family.variants[label]?.peakMemoryMB.map { minimumMemoryGB(peakMB: $0) ?? Int.max }
}

/// Whether a Mac with `physicalBytes` of memory can run a precision.
public func fitsMemory(_ family: ModelFamily, _ label: String, physicalBytes: UInt64) -> Bool {
    guard let floor = minimumMemoryGB(family, label) else { return true }
    return floor != Int.max && Double(physicalBytes) >= Double(floor) * gibibyte
}

/// The greyed cell's and the refused control's reason.
public func memoryFloorHelp(_ gigabytes: Int) -> String {
    gigabytes == Int.max ? "Needs more memory than any Mac has" : "Needs \(gigabytes) GB of memory"
}
