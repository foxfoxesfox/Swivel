import Foundation

/// One conversion run (one or more files): reports progress and can be cancelled.
/// Thread-safe: the app cancels on the main thread while the work runs in the background.
final class Job {
    let name: String
    /// Called on the background thread with overall progress 0…1.
    var onProgress: (Double) -> Void = { _ in }

    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var fileIndex = 0, fileCount = 1

    init(name: String) { self.name = name }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }

    /// Ties a tool process to the job so Cancel can stop it. Throws if already cancelled.
    func attach(_ p: Process?) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled && p != nil { throw ConvertError("Cancelled") }
        process = p
    }

    func startFile(_ index: Int, of count: Int) {
        fileIndex = index
        fileCount = max(count, 1)
        onProgress(Double(index) / Double(fileCount))
    }

    /// Progress within the current file, mapped onto the whole job.
    func report(_ fileFraction: Double) {
        onProgress((Double(fileIndex) + min(max(fileFraction, 0), 1)) / Double(fileCount))
    }

    /// The job running on this thread. A thread-local, so the many converter functions
    /// don't each need a job parameter; convertAll sets it for the duration of a run.
    static var current: Job? {
        get { Thread.current.threadDictionary["swivel.job"] as? Job }
        set { Thread.current.threadDictionary["swivel.job"] = newValue }
    }
}
