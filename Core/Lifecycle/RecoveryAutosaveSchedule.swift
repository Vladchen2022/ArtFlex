public func resolvedRecoveryAutosaveDeadline(
    now: ContinuousClock.Instant,
    delay: Duration,
    forcedDeadline: ContinuousClock.Instant?,
    scheduledDeadline: ContinuousClock.Instant? = nil
) -> ContinuousClock.Instant {
    let requested = now.advanced(by: delay)
    guard let forcedDeadline, forcedDeadline > now else {
        // Do not turn an expired deadline into a busy loop or let new strokes postpone a retry.
        if let scheduledDeadline, scheduledDeadline > now { return min(requested, scheduledDeadline) }
        return requested
    }
    return min(requested, forcedDeadline)
}

/// Scheduling generations are independent of document revisions and capture invalidation.
@MainActor
public final class RecoveryAutosaveSchedule {
    public private(set) var generation: UInt64 = 0
    public private(set) var forcedDeadline: ContinuousClock.Instant?
    private var scheduledDeadline: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    public var isScheduled: Bool { task != nil }
    public let maximumDeferral: Duration
    public var onDeadline: ((UInt64) -> Void)?

    public init(maximumDeferral: Duration = .seconds(120)) { self.maximumDeferral = maximumDeferral }
    deinit { task?.cancel() }

    public func schedule(delay: Duration = .seconds(30)) {
        let clock = ContinuousClock()
        let now = clock.now
        if forcedDeadline == nil { forcedDeadline = now.advanced(by: maximumDeferral) }
        let deadline = resolvedRecoveryAutosaveDeadline(now: now, delay: delay,
            forcedDeadline: forcedDeadline, scheduledDeadline: scheduledDeadline)
        scheduledDeadline = deadline
        generation &+= 1
        let expected = generation
        task?.cancel()
        task = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, self.generation == expected else { return }
            self.task = nil
            self.scheduledDeadline = nil
            self.onDeadline?(expected)
        }
    }

    public func cancel(resetDeadline: Bool = true) {
        generation &+= 1
        task?.cancel()
        task = nil
        scheduledDeadline = nil
        if resetDeadline { forcedDeadline = nil }
    }

    public func didInstallCapture() { forcedDeadline = ContinuousClock().now.advanced(by: maximumDeferral) }

#if DEBUG
    public func fireNowForTesting() { cancel(resetDeadline: false); onDeadline?(generation) }
    public func expireDeadlineForTesting() { forcedDeadline = ContinuousClock().now.advanced(by: .seconds(-1)) }
#endif
}
