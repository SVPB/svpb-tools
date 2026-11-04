import Foundation

// MARK: - RecurringSchedule

/// Parsing and describing the intervals of TNG's in-process timers.
///
/// Shared code, not shared meaning: the destination keep-alive, the database backup and
/// the sweepers each decide their own interval, and this only reads an hours value out of
/// the environment and says an interval back in words. It used to live on the Box
/// keep-alive, which every other timer then had to borrow (#86).
enum RecurringSchedule {

    /// The interval in `hours`, or `fallback` when it is missing, unparseable, zero or
    /// negative — so a nonsense value cannot switch a timer off.
    ///
    /// Fractions are accepted, so a test deployment can drive a timer down to minutes.
    static func interval(hours raw: String?, fallback: Duration = .seconds(24 * 60 * 60)) -> Duration {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              let hours = Double(raw), hours > 0 else {
            return fallback
        }
        return .seconds(hours * 60 * 60)
    }

    /// "24 hour(s)", "90 minute(s)" — for log lines and the connections page.
    static func describe(_ interval: Duration) -> String {
        let seconds = Int(interval.components.seconds)
        if seconds % 3600 == 0 { return "\(seconds / 3600) hour(s)" }
        if seconds % 60 == 0 { return "\(seconds / 60) minute(s)" }
        return "\(seconds) second(s)"
    }
}
