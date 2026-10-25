import Foundation

/// Counted phrases for reports, worded as people say them.
public enum CountWords {
    /// "All 74 tables" for a whole group of `n`; "Both tables" for two. `plural` is the plural
    /// noun ("tables", "programs").
    public static func all(_ n: Int, _ plural: String) -> String {
        n == 2 ? "Both \(plural)" : "All \(n) \(plural)"
    }
}
