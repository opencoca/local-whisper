import Foundation

/// Splits arbitrary input text into paragraph chunks for the
/// ParagraphPlayer pipeline. Used by SpeakService.speakViaSayCommand
/// to decide whether to take the chunked code path (≥ 2 chunks) or
/// the legacy single-utterance path (1 chunk).
///
/// Primary boundary is `\n\n` (any whitespace between the two newlines
/// is tolerated). Any single paragraph that exceeds `softWordCap`
/// words re-splits via `NSString.enumerateSubstrings(.bySentences)`,
/// grouping consecutive sentences until each group is at or below
/// the cap. The cap bounds simulator drift even for wall-of-text
/// input pasted without blank-line breaks.
enum TextSplitter {

    /// Returns the input split into paragraph chunks suitable for
    /// the `say -o tmpfile.aiff` pre-render pipeline.
    ///
    /// - Parameters:
    ///   - text: Source text. Leading/trailing whitespace stripped.
    ///   - softWordCap: Target maximum words per chunk. Default 200.
    ///     At ~150 wpm this is roughly 80 seconds of speech per chunk,
    ///     short enough that interpolator drift stays below ~200 ms
    ///     over the chunk even when the per-paragraph duration
    ///     estimate is a few percent off.
    /// - Returns: Array of paragraph strings. Empty for empty input.
    static func paragraphs(from text: String, softWordCap: Int = 200) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Normalise runs of two-or-more newlines (with any whitespace
        // between) into a single \n\n separator so "\n\n\n" and "\n \n"
        // both yield one boundary.
        let normalised = trimmed.replacingOccurrences(
            of: #"\n\s*\n+"#,
            with: "\n\n",
            options: .regularExpression
        )
        let primary = normalised
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        for chunk in primary {
            if wordCount(of: chunk) <= softWordCap {
                result.append(chunk)
            } else {
                result.append(contentsOf: splitBySentences(chunk, softWordCap: softWordCap))
            }
        }
        return result
    }

    // MARK: - Private

    private static func wordCount(of text: String) -> Int {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    /// Sentence-level fallback for overly-long paragraphs. Mirrors the
    /// `.bySentences` enumeration in `LargeLiveTranscriptionView`. If
    /// the enumeration yields nothing (no sentence-ending punctuation),
    /// returns the input as one chunk so the caller never gets an empty
    /// array for non-empty input.
    ///
    /// A single sentence whose own word count exceeds the cap is emitted
    /// as its own chunk rather than split further — splitting mid-sentence
    /// harms prosody more than the modest drift over one long sentence.
    private static func splitBySentences(_ text: String, softWordCap: Int) -> [String] {
        var sentences: [String] = []
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                sentences.append(s)
            }
        }
        guard !sentences.isEmpty else { return [text] }

        var groups: [String] = []
        var currentGroup: [String] = []
        var currentCount = 0
        for sentence in sentences {
            let sc = wordCount(of: sentence)
            if sc > softWordCap {
                if !currentGroup.isEmpty {
                    groups.append(currentGroup.joined(separator: " "))
                    currentGroup = []
                    currentCount = 0
                }
                groups.append(sentence)
                continue
            }
            if currentCount + sc > softWordCap, !currentGroup.isEmpty {
                groups.append(currentGroup.joined(separator: " "))
                currentGroup = [sentence]
                currentCount = sc
            } else {
                currentGroup.append(sentence)
                currentCount += sc
            }
        }
        if !currentGroup.isEmpty {
            groups.append(currentGroup.joined(separator: " "))
        }
        return groups
    }
}
