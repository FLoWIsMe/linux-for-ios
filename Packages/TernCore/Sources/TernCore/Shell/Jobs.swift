import Foundation

/// A pipeline started with `&`.
final class Job {
    let id: Int
    let command: String
    private let lock = NSCondition()
    private var finished = false
    private var exitStatus: Int32 = 0
    /// Set when `kill` targets this job; the job's stage checks it between commands.
    private(set) var cancelled = false

    init(id: Int, command: String) {
        self.id = id
        self.command = command
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    var status: Int32 {
        lock.lock(); defer { lock.unlock() }
        return exitStatus
    }

    func finish(status: Int32) {
        lock.lock()
        finished = true
        exitStatus = status
        lock.broadcast()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Blocks until the job finishes. Returns false if `deadline` passes first.
    func wait(until deadline: Date? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        while !finished {
            if let deadline {
                if !lock.wait(until: deadline) { return finished }
            } else {
                lock.wait()
            }
        }
        return true
    }
}

/// Background jobs of one shell. Shared by subshells so `wait` works from anywhere.
final class JobTable {
    private let lock = NSLock()
    private var jobs: [Job] = []
    private var nextID = 1

    func add(command: String) -> Job {
        lock.lock(); defer { lock.unlock() }
        let job = Job(id: nextID, command: command)
        nextID += 1
        jobs.append(job)
        return job
    }

    func job(withID id: Int) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs.first { $0.id == id }
    }

    var all: [Job] {
        lock.lock(); defer { lock.unlock() }
        return jobs
    }

    var running: [Job] {
        all.filter { !$0.isFinished }
    }

    /// Removes finished jobs (after `jobs` or `wait` reported them).
    func reap() {
        lock.lock(); defer { lock.unlock() }
        jobs.removeAll { $0.isFinished }
        if jobs.isEmpty { nextID = 1 }
    }

    func cancelAll() {
        for job in all { job.cancel() }
    }
}
