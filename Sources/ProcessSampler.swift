import Darwin
import Foundation

/// One row in a top-processes list.
struct ProcessUsage: Identifiable, Equatable {
    let id: pid_t
    let name: String
    /// CPU time as a fraction of one core; like Activity Monitor it can exceed 1 for multi-threaded work.
    let cpu: Double
    /// Physical footprint in bytes, the same value as Activity Monitor's "Memory" column.
    let memory: Double
}

/// Measures per-process CPU and memory with `proc_pid_rusage`.
///
/// Processes owned by other users (root daemons, WindowServer) cannot be read without root
/// privileges and are skipped.
final class ProcessSampler {
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Forgets the CPU baseline so stale deltas are not reported after a pause.
    func reset() {
        previousCPUTime = [:]
        previousSampleTime = 0
    }

    /// Returns the top `limit` processes by CPU and by memory.
    ///
    /// CPU values are only meaningful from the second call after `reset()`; the first call primes the baseline.
    func sample(limit: Int) -> (byCPU: [ProcessUsage], byMemory: [ProcessUsage]) {
        let now = mach_absolute_time()
        let elapsed = previousSampleTime == 0 ? 0 : Double(nanoseconds(now - previousSampleTime))

        var cpuTimes: [pid_t: UInt64] = [:]
        var rows: [(pid: pid_t, cpu: Double, memory: Double)] = []
        for pid in allPIDs() {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }

            // ri_user_time / ri_system_time are in mach time units (not ns) on Apple Silicon.
            let cpuTime = nanoseconds(info.ri_user_time + info.ri_system_time)
            cpuTimes[pid] = cpuTime
            var cpu = 0.0
            if elapsed > 0, let previous = previousCPUTime[pid], cpuTime >= previous {
                cpu = Double(cpuTime - previous) / elapsed
            }
            rows.append((pid, cpu, Double(info.ri_phys_footprint)))
        }
        previousCPUTime = cpuTimes
        previousSampleTime = now

        let byCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let byMemory = rows.sorted { $0.memory > $1.memory }.prefix(limit)
        let usage = { (row: (pid: pid_t, cpu: Double, memory: Double)) in
            ProcessUsage(id: row.pid, name: self.name(of: row.pid), cpu: row.cpu, memory: row.memory)
        }
        return (byCPU.map(usage), byMemory.map(usage))
    }

    private func nanoseconds(_ machTime: UInt64) -> UInt64 {
        machTime * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "PID \(pid)" : name
    }
}
