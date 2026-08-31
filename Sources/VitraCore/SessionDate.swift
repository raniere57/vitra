import Foundation

/// When a session was last worked on, in the words the sidebar uses.
///
/// Day and time, not "4 days ago": four sessions of the same project called
/// `Farol` are told apart by when they happened, and "4 days ago" says the
/// same thing about two of them.
public enum SessionDate {
    public static func label(
        for date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        // Today and yesterday get named by the system in the user's own
        // language; anything older gets its date. No hand-written words, so
        // nothing to translate and nothing to get wrong.
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
