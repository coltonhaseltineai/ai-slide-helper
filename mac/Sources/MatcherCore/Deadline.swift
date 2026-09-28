import Foundation

/// Runs `operation` but gives up after `seconds`, throwing `JudgeFailure.timeout`.
/// Returns at the deadline even if the operation ignores cancellation: the operation is cancelled and
/// left to finish in the background, so callers should treat the judge as busy until it really ends.
public func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = ResumeOnce<T>()
    let work = Task {
        do { box.resume(.success(try await operation())) } catch { box.resume(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        if !Task.isCancelled { box.resume(.failure(JudgeFailure.timeout)) }
    }
    defer { timer.cancel() }
    do {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in box.set(cont) }
        } onCancel: {
            box.resume(.failure(CancellationError()))
        }
    } catch {
        work.cancel()
        throw error
    }
}

/// A continuation resumed exactly once, by whichever of the work, the timer or cancellation gets there first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var finished = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let r = early {
            early = nil
            finished = true
            lock.unlock()
            c.resume(with: r)
            return
        }
        continuation = c
        lock.unlock()
    }

    func resume(_ r: Result<T, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        if let c = continuation {
            continuation = nil
            finished = true
            lock.unlock()
            c.resume(with: r)
            return
        }
        if early == nil { early = r }
        lock.unlock()
    }
}
