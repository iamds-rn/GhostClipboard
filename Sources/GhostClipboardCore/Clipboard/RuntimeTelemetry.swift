import Foundation
import Darwin

// MARK: - Bounded NSCache for Classification Results

private final class ClassificationResultBox: NSObject {
    let result: ClassificationResult
    init(_ result: ClassificationResult) {
        self.result = result
    }
}

public final class BoundedContentCache: @unchecked Sendable {
    public static let shared = BoundedContentCache()

    private let classificationCache = NSCache<NSString, ClassificationResultBox>()
    private let lock = NSLock()
    private var hits: Int = 0
    private var misses: Int = 0

    public init(countLimit: Int = 64, totalCostLimit: Int = 512 * 1024) {
        classificationCache.countLimit = countLimit
        classificationCache.totalCostLimit = totalCostLimit
    }

    public func cachedClassification(forKey key: String) -> ClassificationResult? {
        if let box = classificationCache.object(forKey: key as NSString) {
            lock.lock()
            hits += 1
            lock.unlock()
            return box.result
        }
        lock.lock()
        misses += 1
        lock.unlock()
        return nil
    }

    public func storeClassification(_ result: ClassificationResult, forKey key: String, cost: Int) {
        classificationCache.setObject(ClassificationResultBox(result), forKey: key as NSString, cost: max(1, cost))
    }

    public func evictAll() {
        classificationCache.removeAllObjects()
    }

    public var stats: (hits: Int, misses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses)
    }
}

// MARK: - Live Process Memory & Efficiency Telemetry

public struct RuntimeEfficiencySnapshot: Equatable, Sendable {
    public let residentMemoryBytes: UInt64
    public let databaseSizeBytes: Int64
    public let isEphemeralTimerActive: Bool
    public let ephemeralClipCount: Int
    public let isPasteboardPollingPaused: Bool
    public let isBackgroundCoalesced: Bool
    public let regexCacheHits: Int
    public let regexCacheMisses: Int
    public let cachedRegexCount: Int
    public let classificationCacheHits: Int

    public var residentMemoryMB: Double {
        Double(residentMemoryBytes) / (1024.0 * 1024.0)
    }

    public var formattedResidentMemory: String {
        String(format: "%.1f MB", residentMemoryMB)
    }

    public var ephemeralTimerStateText: String {
        if isEphemeralTimerActive {
            return "Counting down (1 Hz • \(ephemeralClipCount) active)"
        }
        return "Idle (0 Hz — Zero Wake)"
    }

    public var pasteboardTimerStateText: String {
        if isPasteboardPollingPaused {
            return "Paused (0 Hz)"
        }
        return isBackgroundCoalesced ? "Coalesced Low-Power (400ms leeway)" : "Active Coalesced (150ms leeway)"
    }
}

public enum RuntimeMemoryMonitor {
    /// Queries the kernel via `task_info(mach_task_self_, MACH_TASK_BASIC_INFO, ...)` for live resident memory (RSS).
    public static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else {
            return 0
        }
        return UInt64(info.resident_size)
    }
}
