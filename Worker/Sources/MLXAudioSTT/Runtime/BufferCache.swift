import Foundation
import MLX

/// Keeping MLX's buffer cache between requests, bounded at the cache limit while idle.
///
/// `Memory.cacheLimit` alone is a soft bound: MLX 0.32.2's Metal allocator admits a freed buffer to the cache while
/// the cache is still *below* the limit (`MetalAllocator::free`), so the last buffer freed can leave it above the limit
/// by up to that buffer's size, and it trims back only on its next allocation (`MetalAllocator::malloc`). An idle
/// worker would hold that excess until the next request. `bound` trims it at the request boundary instead.
public enum BufferCache {
    public enum Outcome: Equatable, Sendable {
        /// Already at or below the limit; nothing done.
        case within
        /// One small allocation ran the allocator's own trim: it released least-recently-used buffers until the
        /// cache was back at or below the limit, keeping the rest.
        case trimmed
        /// Still above the limit after the trim: the cache was cleared.
        case cleared
    }

    /// After the GPU is synchronized (every buffer of the request freed): bring the cache to at most `limit` bytes.
    /// The closures are MLX's by default; tests pass fakes.
    @discardableResult
    public static func bound(
        limit: Int,
        cached: () -> Int = { Memory.cacheMemory },
        trim: () -> Void = { eval(MLXArray(Int32(0)) + 1) },
        clear: () -> Void = { Memory.clearCache() }
    ) -> Outcome {
        guard cached() > limit else { return .within }
        trim()
        guard cached() > limit else { return .trimmed }
        clear()
        return .cleared
    }
}
