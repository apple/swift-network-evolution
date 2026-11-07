import Darwin

/// CPU cycles and retired instructions consumed by this whole process (all threads),
/// from the kernel's per-process performance counters (`proc_pid_rusage`). Available
/// to unprivileged processes on Apple silicon. Sampling costs one syscall, so it is
/// done only at the start and end of a run.
public struct CPUCost: Sendable {
    public var cycles: UInt64
    public var instructions: UInt64

    public static let zero = CPUCost(cycles: 0, instructions: 0)

    public init(cycles: UInt64, instructions: UInt64) {
        self.cycles = cycles
        self.instructions = instructions
    }

    public static func now() -> CPUCost {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        precondition(status == 0, "proc_pid_rusage failed")
        return CPUCost(cycles: info.ri_cycles, instructions: info.ri_instructions)
    }

    public static func - (a: CPUCost, b: CPUCost) -> CPUCost {
        CPUCost(cycles: a.cycles &- b.cycles, instructions: a.instructions &- b.instructions)
    }
}
