import Foundation
import os

/// Machine-relevant diagnostic events, logfmt-style (`event key=value`) —
/// same convention as the desktop app's `app/logging_setup.py` (see its
/// module docstring). Exists specifically to answer Phase 0's go/no-go
/// latency/memory questions the moment a physical device is available: run
/// one PTT turn, then `xcrun simctl spawn booted log show` (or Console.app
/// on a real device) and grep for `event=`. Never logs transcript text or
/// child speech — same "audio never leaves the device" boundary the
/// desktop app's telemetry docstring describes.
enum Diagnostics {
    private static let logger = Logger(subsystem: "cz.macek.nova", category: "diagnostics")

    static func log(_ event: String, _ fields: [String: String]) {
        let pairs = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.log("event=\(event, privacy: .public) \(pairs, privacy: .public)")
    }

    /// Elapsed wall-clock time in milliseconds, rounded to the nearest ms —
    /// `DispatchTime` rather than `Date()`, since it's monotonic and immune
    /// to clock adjustments mid-measurement.
    static func measureMs<T>(_ body: () throws -> T) rethrows -> (T, Int) {
        let start = DispatchTime.now()
        let result = try body()
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return (result, Int(elapsedNs / 1_000_000))
    }

    /// The app's current physical memory footprint in MB — `phys_footprint`
    /// via `task_info`, the same metric Xcode's own memory gauge and Instruments
    /// report (closer to what iOS's jetsam killer watches than `resident_size`).
    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }
}
