import Darwin
import StackCommon

/// A run loop that is the executor every task in the async stack runs on, driven
/// by the benchmark's calling thread.
///
/// In steady state all jobs are enqueued from that thread: every resumed
/// continuation is enqueued by code that is itself running on this executor. The
/// exception is a new task's very first hop - the runtime starts a `Task` on the
/// global pool and then switches it to its actor - which arrives from a pool
/// thread. So the queue has a lock, and the loop does not stop while a task that
/// has been spawned has yet to finish. (Giving tasks a `TaskExecutor` preference
/// instead avoids the pool hop but makes every later resume enqueue twice, which
/// is far more expensive.) The lock is uncontended in steady state.
final class RunLoop: SerialExecutor, @unchecked Sendable {
    static let shared = RunLoop()

    private var lock = os_unfair_lock()
    private var queue = RingQueue<UnownedJob>(minimumCapacity: 1024)
    /// Tasks spawned and not yet finished. Only touched from the loop thread.
    var liveTasks = 0

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        os_unfair_lock_lock(&lock)
        queue.pushBack(unowned)
        os_unfair_lock_unlock(&lock)
    }

    /// Runs jobs until none are queued and every spawned task has finished.
    func runUntilIdle() {
        let executor = asUnownedSerialExecutor()
        while true {
            os_unfair_lock_lock(&lock)
            let next = queue.popFront()
            os_unfair_lock_unlock(&lock)
            if let job = next {
                job.runSynchronously(on: executor)
            } else if liveTasks == 0 {
                return
            } else {
                sched_yield()
            }
        }
    }
}

@globalActor
public actor StackActor {
    public static let shared = StackActor()

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        RunLoop.shared.asUnownedSerialExecutor()
    }
}

/// Starts a task on the stack's actor.
@StackActor
func spawn(_ body: @escaping @StackActor () async -> Void) {
    RunLoop.shared.liveTasks += 1
    Task { @StackActor in
        await body()
        RunLoop.shared.liveTasks -= 1
    }
}
