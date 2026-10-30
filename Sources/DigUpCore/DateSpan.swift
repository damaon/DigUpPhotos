import Foundation

/// A stretch of time photos were taken in: a year, a month, years, or the last few days. `end` is not included.
public struct DateSpan: Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    /// How it's shown: "2023", "July 2023", "2019–2021", "Last 30 Days".
    public let title: String

    public init(start: Date, end: Date, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public static func year(_ year: Int, calendar: Calendar = .current) -> DateSpan? {
        years(year, year, calendar: calendar)
    }

    public static func years(_ first: Int, _ last: Int, calendar: Calendar = .current) -> DateSpan? {
        guard first <= last, let start = calendar.date(from: DateComponents(year: first, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: last + 1, month: 1, day: 1)) else { return nil }
        return DateSpan(start: start, end: end, title: first == last ? "\(first)" : "\(first)–\(last)")
    }

    public static func month(_ month: Int, of year: Int, calendar: Calendar = .current) -> DateSpan? {
        guard (1...12).contains(month), let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateSpan(start: start, end: end, title: "\(calendar.standaloneMonthSymbols[month - 1]) \(year)")
    }

    /// The last `days` days, today included.
    public static func last(days: Int, now: Date = Date(), calendar: Calendar = .current) -> DateSpan? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        guard let start = calendar.date(byAdding: .day, value: -days, to: tomorrow) else { return nil }
        return DateSpan(start: start, end: tomorrow, title: "Last \(days) Days")
    }

    /// When typed words name a time ("beach 2023", "july 2023", "2019-2021", "kraków w zeszłym roku"): that time, and
    /// the words left to search for. English and Polish. A year on its own counts from 1980 to next year, so "1080p"
    /// or "4815162342" stay words.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current)
        -> (span: DateSpan, rest: String)? {
        let thisYear = calendar.component(.year, from: now)
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let lowered = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }

        func year(_ word: String) -> Int? {
            guard word.count == 4, word.allSatisfy(\.isNumber), let value = Int(word),
                  (1980...thisYear + 1).contains(value) else { return nil }
            return value
        }
        /// Removes words[range] and a preposition right before it ("in 2023", "w 2023", "from july 2023").
        func rest(without range: Range<Int>) -> String {
            var range = range
            if range.lowerBound > 0, prepositions.contains(lowered[range.lowerBound - 1]) {
                range = (range.lowerBound - 1)..<range.upperBound
            }
            words.removeSubrange(range)
            return words.joined(separator: " ")
        }

        // "last year", "this year", "w zeszłym roku", "w tym roku".
        for (phrase, offset) in relativeYears {
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.count <= lowered.count else { continue }
            for start in 0...(lowered.count - parts.count) where Array(lowered[start..<start + parts.count]) == parts {
                guard let span = Self.year(thisYear + offset, calendar: calendar) else { continue }
                return (span, rest(without: start..<start + parts.count))
            }
        }
        for (index, word) in lowered.enumerated() {
            // "2019-2021", "2019–2021"
            let ends = word.split(whereSeparator: { $0 == "-" || $0 == "–" }).map(String.init)
            if ends.count == 2, let first = year(ends[0]), let last = year(ends[1]),
               let span = years(first, last, calendar: calendar) {
                return (span, rest(without: index..<index + 1))
            }
            guard let found = year(word) else { continue }
            // "july 2023", "lipiec 2023", "lipca 2023", "jul 2023"
            if index > 0, let number = monthNumber(lowered[index - 1]),
               let span = Self.month(number, of: found, calendar: calendar) {
                return (span, rest(without: (index - 1)..<index + 1))
            }
            if let span = Self.year(found, calendar: calendar) { return (span, rest(without: index..<index + 1)) }
        }
        return nil
    }

    private static let prepositions: Set<String> = ["in", "from", "during", "w", "we", "z", "ze", "od"]

    private static let relativeYears: [(String, Int)] = [
        ("last year", -1), ("this year", 0),
        ("w zeszłym roku", -1), ("w zeszlym roku", -1), ("w ubiegłym roku", -1), ("w ubieglym roku", -1),
        ("zeszły rok", -1), ("zeszly rok", -1), ("w tym roku", 0), ("ten rok", 0),
    ]

    /// 1…12 for a month's name in English or Polish (any case ending: "lipiec", "lipca"), or its first three letters.
    static func monthNumber(_ word: String) -> Int? {
        let word = word.lowercased()
        for (index, names) in monthNames.enumerated() where names.contains(where: { word == $0 }) { return index + 1 }
        return nil
    }

    private static let monthNames: [[String]] = [
        ["january", "jan", "styczeń", "styczen", "stycznia", "sty"],
        ["february", "feb", "luty", "lutego", "lut"],
        ["march", "mar", "marzec", "marca"],
        ["april", "apr", "kwiecień", "kwiecien", "kwietnia", "kwi"],
        ["may", "maj", "maja"],
        ["june", "jun", "czerwiec", "czerwca", "cze"],
        ["july", "jul", "lipiec", "lipca", "lip"],
        ["august", "aug", "sierpień", "sierpien", "sierpnia", "sie"],
        ["september", "sep", "sept", "wrzesień", "wrzesien", "września", "wrzesnia", "wrz"],
        ["october", "oct", "październik", "pazdziernik", "października", "pazdziernika", "paź", "paz"],
        ["november", "nov", "listopad", "listopada", "lis"],
        ["december", "dec", "grudzień", "grudzien", "grudnia", "gru"],
    ]
}
