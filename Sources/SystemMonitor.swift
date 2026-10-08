import Darwin
import Foundation
import Observation

/// Breakdown of CPU time over the last sampling interval.
struct CPUDetails: Equatable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
    /// Busy fraction of each logical core, in kernel order.
    var cores: [Double] = []
    /// 1, 5 and 15 minute load averages.
    var loadAverage: [Double] = [0, 0, 0]
}

/// Kernel memory pressure level (`kern.memorystatus_vm_pressure_level`).
enum MemoryPressure: Equatable {
    case normal, warning, critical
}

/// Memory figures matching Activity Monitor's Memory tab, in bytes.
struct MemoryDetails: Equatable {
    var available: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    var pressure: MemoryPressure = .normal
}

/// Samples system-wide CPU and memory once per second and keeps a rolling history.
///
/// Fractions are in `0...1`. Memory "used" is defined as `1 − kern.memorystatus_level`, i.e. the
/// inverse of the kernel's available-memory figure (free plus cheaply reclaimable memory) that also
/// drives Activity Monitor's memory pressure graph.
///
/// `cpu` and `memoryUsed` are rounded to whole percent and only written when that changes, so the
/// collapsed island (which reads nothing else) is not re-rendered while the numbers stay the same.
@Observable
final class SystemMonitor {
    /// Number of samples kept for the sparkline (one per second).
    static let historyLength = 60
    /// Rows shown in each top-processes list.
    static let topProcessCount = 5

    private(set) var cpu: Double = 0
    private(set) var memoryUsed: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var cpuDetails = CPUDetails()
    private(set) var memoryDetails = MemoryDetails()
    private(set) var topCPU: [ProcessUsage] = []
    private(set) var topMemory: [ProcessUsage] = []

    /// Installed physical memory in bytes.
    let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    /// Performance / efficiency core counts, or nil where the machine does not report them.
    let coreTypes: (performance: Int, efficiency: Int)? = {
        guard let p = SystemMonitor.sysctlInt32("hw.perflevel0.logicalcpu"),
              let e = SystemMonitor.sysctlInt32("hw.perflevel1.logicalcpu") else { return nil }
        return (Int(p), Int(e))
    }()

    /// When true, per-process usage is also sampled. Only needed while the details panel is open.
    @ObservationIgnored var samplesProcesses = false {
        didSet {
            guard samplesProcesses != oldValue else { return }
            processSampler.reset()
            if samplesProcesses {
                _ = processSampler.sample(limit: Self.topProcessCount)
            }
        }
    }

    @ObservationIgnored private let host = mach_host_self()
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private var pageSize: vm_size_t = 0
    @ObservationIgnored private var previousCoreTicks: [[UInt32]]?
    @ObservationIgnored private var timer: Timer?

    /// Creates a monitor; call `start()` to begin sampling.
    init() {
        host_page_size(host, &pageSize)
    }

    /// Takes an initial sample and schedules one sample per second on the main run loop.
    /// Does nothing if sampling is already running.
    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        // Lets the system coalesce this wakeup with other timers.
        timer.tolerance = 0.2
        // .common keeps sampling while menus are open or the user is dragging.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops sampling and drops the tick baselines, so the first sample after `start()`
    /// is not averaged over the whole pause.
    func stop() {
        timer?.invalidate()
        timer = nil
        previousCoreTicks = nil
        processSampler.reset()
    }

    private func sample() {
        if let details = readCPU() {
            cpuDetails = details
            let value = 1 - details.idle
            let rounded = Self.wholePercent(value)
            if rounded != cpu { cpu = rounded }
            append(value, to: &cpuHistory)
        }
        if let details = readMemory() {
            memoryDetails = details
            let value = 1 - details.available / totalMemory
            let rounded = Self.wholePercent(value)
            if rounded != memoryUsed { memoryUsed = rounded }
            append(value, to: &memoryHistory)
        }
        if samplesProcesses {
            (topCPU, topMemory) = processSampler.sample(limit: Self.topProcessCount)
        }
    }

    /// Rounds a fraction to whole percent, e.g. `0.4237` → `0.42`.
    private static func wholePercent(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    /// Returns CPU usage since the previous call from per-core tick counters, or nil on the first call.
    private func readCPU() -> CPUDetails? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(coreCount)).map { core in
            (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
        defer { previousCoreTicks = ticks }
        guard let previous = previousCoreTicks, previous.count == ticks.count else { return nil }

        var sums = [Double](repeating: 0, count: states)
        var cores: [Double] = []
        for (now, before) in zip(ticks, previous) {
            // Tick counters are UInt32 and can wrap; wrapping subtraction keeps the delta correct.
            let deltas = zip(now, before).map { Double($0 &- $1) }
            let total = deltas.reduce(0, +)
            cores.append(total > 0 ? 1 - deltas[Int(CPU_STATE_IDLE)] / total : 0)
            for state in 0..<states { sums[state] += deltas[state] }
        }
        let total = sums.reduce(0, +)
        guard total > 0 else { return nil }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return CPUDetails(
            user: (sums[Int(CPU_STATE_USER)] + sums[Int(CPU_STATE_NICE)]) / total,
            system: sums[Int(CPU_STATE_SYSTEM)] / total,
            idle: sums[Int(CPU_STATE_IDLE)] / total,
            cores: cores,
            loadAverage: load
        )
    }

    private func readMemory() -> MemoryDetails? {
        guard let level = Self.sysctlInt32("kern.memorystatus_level") else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(pageSize)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let pressure: MemoryPressure
        switch Self.sysctlInt32("kern.memorystatus_vm_pressure_level") {
        case 4: pressure = .critical
        case 2: pressure = .warning
        default: pressure = .normal
        }

        // Same categories as Activity Monitor's Memory tab.
        return MemoryDetails(
            available: min(max(Double(level) / 100, 0), 1) * totalMemory,
            app: (Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page,
            wired: Double(stats.wire_count) * page,
            compressed: Double(stats.compressor_page_count) * page,
            cached: (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page,
            swapUsed: Double(swap.xsu_used),
            swapTotal: Double(swap.xsu_total),
            pressure: pressure
        )
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
