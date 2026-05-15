import Foundation

// MARK: - BackoffScheduler

/// Pure, stateless backoff-delay calculator for `UploadQueue`.
///
/// The schedule is exponential doubling starting at `base` seconds, capped at
/// `maxDelay` (1 hour).  The cap is sticky — no attempt index, however large,
/// can produce a delay exceeding `maxDelay`.
///
/// | Attempt | Delay  |
/// |---------|--------|
/// | 1       | 5s     |
/// | 2       | 10s    |
/// | 3       | 20s    |
/// | 4       | 40s    |
/// | 5       | 80s    |
/// | 6       | 160s   |
/// | 7       | 320s   |
/// | 8       | 640s   |
/// | 9       | 1280s  |
/// | 10      | 2560s  |
/// | 11+     | 3600s  |
///
/// # Thread safety
///
/// `BackoffScheduler` is a `struct` with only static members — there is no
/// instance state and no mutable shared state.  It is safe to call from any
/// concurrency context.
enum BackoffScheduler {

  /// Base delay in seconds (first failed attempt).
  static let base: TimeInterval = 5

  /// Maximum delay in seconds (1 hour).
  static let maxDelay: TimeInterval = 3600

  /// Return the backoff delay for the given attempt number.
  ///
  /// - Parameter attempt: 1-based attempt counter (1 = first failure).
  /// - Returns: The capped delay in seconds.
  static func delay(forAttempt attempt: Int) -> TimeInterval {
    // Guard against non-positive attempt numbers.
    guard attempt > 0 else { return base }

    // Compute base * 2^(attempt - 1), guarding against overflow.
    // Swift's Double can represent up to ~1.8×10^308, so even attempt = 1000
    // produces a finite value that the min() cap then clamps to maxDelay.
    let raw = base * pow(2.0, Double(attempt - 1))
    return min(raw, maxDelay)
  }
}
