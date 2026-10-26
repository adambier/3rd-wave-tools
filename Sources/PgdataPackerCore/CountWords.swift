import Foundation

/// Counted phrases for reports, worded as people say them.
public enum CountWords {
    /// "All 74 tables" for a whole group of `n`; "Both tables" for two. `plural` is the plural
    /// noun ("tables", "programs").
    public static func all(_ n: Int, _ plural: String) -> String {
        n == 2 ? "Both \(plural)" : "All \(n) \(plural)"
    }
}

/// Splits a paragraph into its sentences, for views that set each sentence as a short paragraph
/// of its own (the Wavetables page's explanations): at a period, exclamation mark, or question
/// mark followed by a space and then a capital letter, a digit, an opening quotation mark, or an
/// opening parenthesis, the mark itself or a closing parenthesis or quotation mark right after
/// it ("(The rest follows.) 3 tables"). A period inside a number ("0.1 dB"), an abbreviation
/// followed by a lowercase word ("e.g., a table"), or a parenthesis ("(approx.) and") stays.
public func sentencesOfParagraph(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        current.append(c)
        // A sentence ends at the mark, or at a closing parenthesis or quotation mark right after it.
        let ends = ".!?".contains(c) || ((c == ")" || c == "\u{201D}") && i > 0 && ".!?".contains(chars[i - 1]))
        if ends, i + 2 < chars.count, chars[i + 1] == " ",
           chars[i + 2].isUppercase || chars[i + 2].isNumber || chars[i + 2] == "\u{201C}" || chars[i + 2] == "(" {
            out.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            i += 1   // the space
        }
        i += 1
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { out.append(last) }
    return out
}
