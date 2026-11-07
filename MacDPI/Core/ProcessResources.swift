import Darwin

/// A process-wide reading. The start timestamp distinguishes reuse of a PID.
public struct ProcessResourceReading: Equatable, Sendable {
    public let identity: UInt64
    public let cpuNanoseconds: UInt64
    public let residentBytes: UInt64

    public init(identity: UInt64, cpuNanoseconds: UInt64, residentBytes: UInt64) {
        self.identity = identity
        self.cpuNanoseconds = cpuNanoseconds
        self.residentBytes = residentBytes
    }
}

public enum ProcessResourceReader {
    /// Reads only the supplied process. Permission failure, exit and unsupported
    /// information are unavailable readings, not zero resource consumption.
    public static func read(pid: Int32) -> ProcessResourceReading? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0, info.ri_proc_start_abstime != 0, info.ri_proc_exit_abstime == 0 else { return nil }
        let total = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
        guard !total.overflow else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              let nanos = nanoseconds(ticks: total.partialValue, numerator: timebase.numer, denominator: timebase.denom) else { return nil }
        return ProcessResourceReading(identity: info.ri_proc_start_abstime,
                                      cpuNanoseconds: nanos, residentBytes: info.ri_resident_size)
    }

    // XNU fill_task_rusage copies task_power_info's Mach-time CPU counters.
    // https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c
    // https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c
    // Full-width multiplication preserves a valid result when ticks*numer
    // exceeds UInt64 but the quotient fits. Check high before division to avoid
    // the standard library's overflowing-quotient precondition.
    static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        let divisor = UInt64(denominator)
        guard product.high < divisor else { return nil }
        return divisor.dividingFullWidth(product).quotient
    }
}

public struct ProcessResourceUsage: Equatable, Sendable {
    /// One fully occupied CPU core is 100%; multiple cores can exceed 100%.
    public let cpuPercent: Double
    /// Sum of the final resident-memory readings, not physical footprint.
    public let residentBytes: UInt64

    public static func between(first: [Int32: ProcessResourceReading],
                               last: [Int32: ProcessResourceReading],
                               elapsedSeconds: Double) -> ProcessResourceUsage? {
        guard !first.isEmpty, first.count == last.count,
              elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        var cpuDelta: UInt64 = 0
        var resident: UInt64 = 0
        for (pid, before) in first {
            guard pid > 0, let after = last[pid], before.identity != 0,
                  before.identity == after.identity, after.cpuNanoseconds >= before.cpuNanoseconds else { return nil }
            let addedCPU = cpuDelta.addingReportingOverflow(after.cpuNanoseconds - before.cpuNanoseconds)
            let addedMemory = resident.addingReportingOverflow(after.residentBytes)
            guard !addedCPU.overflow, !addedMemory.overflow else { return nil }
            cpuDelta = addedCPU.partialValue
            resident = addedMemory.partialValue
        }
        let percent = (Double(cpuDelta) / 1_000_000_000) / elapsedSeconds * 100
        guard percent.isFinite else { return nil }
        return ProcessResourceUsage(cpuPercent: percent, residentBytes: resident)
    }
}
