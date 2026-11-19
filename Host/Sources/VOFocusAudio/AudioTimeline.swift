import Foundation

/// What was heard during one scenario step.
public struct StepAudio: Sendable, Codable, Equatable {
    public let label: String
    /// Seconds from the start of the recording.
    public let start: Double
    public let end: Double
    /// What the runner reported VoiceOver saying, if this step reports speech.
    public let expected: String?
    /// The words heard, as transcribed.
    public let heard: String
    /// VoiceOver was still speaking this step's speech when the next step took
    /// effect, so the rest of it was never heard.
    public let cutOff: Bool
    /// How many of `expected`'s words were heard, in order, when `expected` is known.
    public let wordsHeard: Int?
    public let wordsExpected: Int?
    public let sounds: [HeardSound]
}

/// A scenario step's time span, for lining audio up with steps.
public struct StepWindow: Sendable {
    public let label: String
    /// Seconds from the start of the recording.
    public let start: Double
    public let expected: String?

    public init(label: String, start: Double, expected: String?) {
        self.label = label
        self.start = start
        self.expected = expected
    }
}

public enum AudioTimeline {
    /// A pause longer than this separates two stretches of speech.
    static let runGap = 0.5
    /// Speech that stops and is followed this quickly by another step's speech was
    /// cut off: VoiceOver stopped mid-way to say something new.
    static let interruptGap = 0.3

    /// Lines the words and sounds up with the steps.
    ///
    /// VoiceOver's audio lags the runner: a step can finish before its speech is
    /// heard. So words are matched by content to what each step reported VoiceOver
    /// saying (`expected`), in order; words that match nothing go with the speech
    /// around them, or by time. `end` is the length of the recording.
    public static func steps(_ windows: [StepWindow], words: [HeardWord], sounds: [HeardSound], end: Double) -> [StepAudio] {
        guard !windows.isEmpty else { return [] }
        let (owners, matched) = assign(windows, words: words)
        let lag = audioLag(windows, words: words, owners: owners, matched: matched)

        return windows.enumerated().map { index, window in
            let indices = words.indices.filter { owners[$0] == index }
            let stepWords = indices.map { words[$0] }
            let heard = stepWords.map(\.text).joined(separator: " ")
            var wordsHeard: Int?
            var wordsExpected: Int?
            if let expected = window.expected {
                wordsExpected = normalizedWords(expected).count
                wordsHeard = indices.reduce(0) { $0 + matched[$1] }
            }
            // Cut off: the next word belongs to a later step and follows right away,
            // and (when known) not all of this step's speech was heard.
            var cutOff = false
            if let last = indices.last, last + 1 < words.count, owners[last + 1] > index,
               words[last + 1].start - words[last].end < interruptGap {
                cutOff = wordsHeard.map { $0 < (wordsExpected ?? 0) } ?? true
            }
            let from = window.start + lag
            let to = index + 1 < windows.count ? windows[index + 1].start + lag : max(end, from)
            return StepAudio(
                label: window.label, start: window.start, end: to, expected: window.expected, heard: heard,
                cutOff: cutOff, wordsHeard: wordsHeard, wordsExpected: wordsExpected,
                sounds: sounds.filter { $0.time >= (index == 0 ? 0 : from) && $0.time < to })
        }
    }

    /// Which step each word belongs to, and how many expected words each word matched.
    static func assign(_ windows: [StepWindow], words: [HeardWord]) -> (owners: [Int], matched: [Int]) {
        // Expected words in step order, and heard words split the same way.
        var expected: [(word: String, step: Int)] = []
        for (step, window) in windows.enumerated() {
            for word in normalizedWords(window.expected ?? "") { expected.append((word, step)) }
        }
        var heard: [(word: String, index: Int)] = []
        for (index, word) in words.enumerated() {
            for token in normalizedWords(word.text) { heard.append((token, index)) }
        }

        // Longest common subsequence, keeping the matched pairs.
        let rows = heard.count, columns = expected.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        if rows > 0 && columns > 0 {
            for i in 1...rows {
                for j in 1...columns {
                    table[i][j] = similar(heard[i - 1].word, expected[j - 1].word)
                        ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
                }
            }
        }
        var matchedStep = [Int?](repeating: nil, count: words.count)
        var matched = [Int](repeating: 0, count: words.count)
        var i = rows, j = columns
        // Walking back from the end, skip expected words when that costs nothing, so
        // speech said once goes to the earliest step that reported it.
        while i > 0 && j > 0 {
            if table[i][j - 1] == table[i][j] {
                j -= 1
            } else if similar(heard[i - 1].word, expected[j - 1].word) && table[i][j] == table[i - 1][j - 1] + 1 {
                matchedStep[heard[i - 1].index] = expected[j - 1].step
                matched[heard[i - 1].index] += 1
                i -= 1; j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        // Unmatched words go with the matched words in the same stretch of speech.
        var owners = matchedStep
        var runs: [[Int]] = []
        for index in words.indices {
            if let last = runs.last?.last, words[index].start - words[last].end <= runGap {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        for run in runs {
            var previous: Int?
            for index in run {
                if let step = matchedStep[index] { previous = step } else if let previous { owners[index] = previous }
            }
            var next: Int?
            for index in run.reversed() {
                if let step = matchedStep[index] { next = step } else if owners[index] == nil, let next { owners[index] = next }
            }
        }

        // Stretches that matched nothing go by time, kept between the steps of the
        // matched speech before and after them. When the next matched speech is a
        // separate stretch, they come before its step: VoiceOver hadn't reached it.
        let runOf: [Int] = runs.enumerated().reduce(into: [Int](repeating: 0, count: words.count)) { result, run in
            for index in run.element { result[index] = run.offset }
        }
        for index in words.indices where owners[index] == nil {
            let previous = (0..<index).last { matchedStep[$0] != nil }
            let next = (index + 1..<words.count).first { matchedStep[$0] != nil }
            let lower = previous.flatMap { matchedStep[$0] } ?? 0
            var upper = next.flatMap { matchedStep[$0] } ?? windows.count - 1
            if let next, runOf[next] != runOf[index], upper > lower { upper -= 1 }
            let byTime = windows.lastIndex { $0.start <= words[index].start } ?? 0
            owners[index] = min(max(byTime, lower), upper)
        }
        // Keep steps in order.
        var floor = 0
        let ordered = owners.map { owner -> Int in floor = max(floor, owner!); return floor }
        return (ordered, matched)
    }

    /// How long after a step starts its audio is heard, estimated from the steps whose
    /// speech was recognized; used to place sounds.
    static func audioLag(_ windows: [StepWindow], words: [HeardWord], owners: [Int], matched: [Int]) -> Double {
        var lags: [Double] = []
        for (step, window) in windows.enumerated() {
            if let first = words.indices.first(where: { owners[$0] == step && matched[$0] > 0 }) {
                lags.append(words[first].start - window.start)
            }
        }
        return min(max(lags.min() ?? 0.15, 0.1), 1.5)
    }

    /// Lowercased words without punctuation, with numbers spelled out the way speech
    /// recognition writes them ("2" → "two").
    static func normalizedWords(_ text: String) -> [String] {
        let speller = NumberFormatter()
        speller.numberStyle = .spellOut
        speller.locale = Locale(identifier: "en-US")
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .flatMap(splitRunTogether)
            .flatMap { word -> [String] in
                if let number = Int(word), let spelled = speller.string(from: NSNumber(value: number)) {
                    return spelled.split { $0 == " " || $0 == "-" }.map(String.init)
                }
                return [String(word)]
            }
    }

    /// Splits words that speech recognition runs together after a number ("w1w2w3" →
    /// "w1", "w2", "w3").
    static func splitRunTogether(_ word: Substring) -> [Substring] {
        var parts: [Substring] = []
        var start = word.startIndex
        var index = word.startIndex
        while index < word.endIndex {
            let next = word.index(after: index)
            if next < word.endIndex, word[index].isNumber, word[next].isLetter {
                parts.append(word[start..<next])
                start = next
            }
            index = next
        }
        parts.append(word[start...])
        return parts
    }

    /// The same word, allowing for what speech recognition gets slightly wrong:
    /// plurals and endings ("notification" for "notifications"), or one letter off in
    /// a longer word.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if long.hasPrefix(short) && long.count - short.count <= 2 { return true }
        guard short.count >= 5, long.count - short.count <= 1 else { return false }
        return editDistance(Array(short), Array(long), limit: 1) <= 1
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j] + (x == y ? 0 : 1), previous[j + 1] + 1, current[j] + 1)
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = similar(x, y) ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }
}
