import Darwin
import StackCommon

/// A single-threaded run loop that is the executor every task in the async stack
/// runs on, driven by the benchmark's calling thread.
///
/// It is a `TaskExecutor` that every task names as its preference, and the stack's
/// types are deliberately *not* actor-isolated. The idiomatic alternative - a global
/// actor whose `unownedExecutor` is this run loop - was tried first and costs far
/// more here: a continuation resumed inside actor-isolated code is enqueued on the
/// global pool, which runs it just long enough to hop it back onto the actor,
/// waking a thread each time. With only a task-executor preference, a resume
/// enqueues once, directly, from the thread that is already running the loop (see
/// `AsyncActorStack` for the actor version).
///
/// Because every enqueue then comes from the loop thread, the queue needs no lock.
final class RunLoop: TaskExecutor, @unchecked Sendable {
    static let shared = RunLoop()

    /// The thread driving the loop; set by `run` before any task is spawned.
    var owner = pthread_self()
    private var queue = RingQueue<UnownedJob>(minimumCapacity: 1024)

    func enqueue(_ job: consuming ExecutorJob) {
        assert(pthread_equal(pthread_self(), owner) != 0, "RunLoop is single threaded: a job was enqueued from another thread")
        queue.pushBack(UnownedJob(job))
    }

    /// Runs jobs until none remain.
    func runUntilIdle() {
        let executor = asUnownedTaskExecutor()
        while let job = queue.popFront() {
            job.runSynchronously(on: executor)
        }
    }
}

/// Starts a task that runs on the run loop from the start.
func spawn(_ body: @escaping @Sendable () async -> Void) {
    Task(executorPreference: RunLoop.shared, operation: body)
}
