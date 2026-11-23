import Foundation

struct FrontMatterDateIssue: Equatable, Sendable {
    let lineNumber: Int
    let value: String
    let normalizedValue: String?

    var message: String {
        "date は Hugo が受け取れるISO 8601形式にしてください（例: 2026-08-14T18:24:21+09:00）。現在: \(value)"
    }
}

struct FrontMatter: Sendable {
    let fields: [String: String]
    let body: String

    var title: String { scalar("title") ?? "無題" }
    var slug: String { scalar("slug") ?? "" }
    var category: String { scalar("categories") ?? "" }
    var isDraft: Bool { scalar("draft")?.lowercased() == "true" }

    var date: Date? {
        guard let value = scalar("date") else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return fallback.date(from: value)
    }

    func scalar(_ key: String) -> String? {
        fields[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}

enum FrontMatterParser {
    static func parse(_ markdown: String) -> FrontMatter {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return FrontMatter(fields: [:], body: normalized)
        }

        let rest = String(normalized.dropFirst(4))
        guard let closing = rest.range(of: "\n---\n") else {
            return FrontMatter(fields: [:], body: normalized)
        }

        let header = String(rest[..<closing.lowerBound])
        let body = String(rest[closing.upperBound...])
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
        }
        return FrontMatter(fields: fields, body: body)
    }

    static func replacingField(_ key: String, with value: String, in markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return "---\n\(key): \(value)\n---\n\n\(markdown)"
        }

        if let index = lines[1..<closingIndex].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
        }) {
            lines[index] = "\(key): \(value)"
        } else {
            lines.insert("\(key): \(value)", at: closingIndex)
        }
        return lines.joined(separator: "\n")
    }

    static func validationErrors(markdown: String, repository: URL) -> [String] {
        let frontMatter = parse(markdown)
        var errors: [String] = []
        if frontMatter.fields.isEmpty { errors.append("Front Matter（--- で囲まれた部分）がありません。") }
        if frontMatter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || frontMatter.title == "無題" {
            errors.append("title が未入力です。")
        }
        if frontMatter.slug.isEmpty { errors.append("slug が未入力です。") }
        if let dateError = dateValidationError(in: markdown) { errors.append(dateError) }

        for path in imagePaths(in: markdown) {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let imageURL = repository.appendingPathComponent("static").appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: imageURL.path) {
                errors.append("画像が見つかりません: \(path)")
            }
        }
        return errors
    }

    static func dateValidationError(in markdown: String) -> String? {
        dateIssue(in: markdown)?.message
    }

    static func dateIssue(in markdown: String) -> FrontMatterDateIssue? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }

        let lines = normalized.components(separatedBy: "\n")
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else { return nil }

        for index in 1..<closingIndex {
            let line = lines[index]
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "date" else { continue }

            let rawValue = line[line.index(after: separator)...]
            let date = scalarValue(String(rawValue))
            guard !date.isEmpty else { return nil }
            let hasSupportedFormat = supportedHugoDatePatterns.contains {
                matchesEntireDate(date, pattern: $0)
            }
            guard hasSupportedFormat,
                  hasZeroPaddedDatePrefix(date),
                  hasValidTimeAndTimeZone(date) else {
                return FrontMatterDateIssue(
                    lineNumber: index + 1,
                    value: date,
                    normalizedValue: normalizedUnpaddedTimestamp(date)
                )
            }
        }
        return nil
    }

    /// Returns a copy with only a safe, unpadded `date` value normalized. It intentionally
    /// refuses all other malformed dates so the caller never guesses the author's intent.
    static func repairingUnpaddedDate(in markdown: String) -> String? {
        guard let issue = dateIssue(in: markdown), let normalizedValue = issue.normalizedValue else { return nil }

        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let lineIndex = issue.lineNumber - 1
        guard lines.indices.contains(lineIndex),
              let separator = lines[lineIndex].firstIndex(of: ":") else { return nil }

        let prefix = String(lines[lineIndex][...separator])
        let rawValue = String(lines[lineIndex][lines[lineIndex].index(after: separator)...])
        let leading = rawValue.prefix { $0.isWhitespace }
        let trailing = rawValue.reversed().prefix { $0.isWhitespace }.reversed()
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote: Character? = trimmed.first == "\"" && trimmed.last == "\"" ? "\"" :
            (trimmed.first == "'" && trimmed.last == "'" ? "'" : nil)
        let replacement = quote.map { "\($0)\(normalizedValue)\($0)" } ?? normalizedValue
        lines[lineIndex] = prefix + leading + replacement + trailing
        return lines.joined(separator: "\n")
    }

    static func imagePaths(in markdown: String) -> [String] {
        let patterns = [
            #"!\[[^\]]*\]\((/images/[^\s\)]+)\)"#,
            #"src=[\"'](/images/[^\"']+)[\"']"#
        ]
        var paths: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(markdown.startIndex..., in: markdown)
            for match in regex.matches(in: markdown, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: markdown) else { continue }
                paths.append(String(markdown[valueRange]))
            }
        }
        if let frontMatterImage = parse(markdown).scalar("image"),
           frontMatterImage.hasPrefix("images/") || frontMatterImage.hasPrefix("/images/") {
            paths.append(frontMatterImage.hasPrefix("/") ? frontMatterImage : "/" + frontMatterImage)
        }
        return Array(Set(paths)).sorted()
    }

    private static func hasZeroPaddedDatePrefix(_ date: String) -> Bool {
        let characters = Array(date)
        guard characters.count >= 10,
              characters[4] == "-",
              characters[7] == "-" else { return false }
        guard [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ characters[$0].isNumber }) else { return false }

        let day = String(characters.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: day) else { return false }
        return formatter.string(from: parsed) == day
    }

    private static let supportedHugoDatePatterns = [
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
    ]

    private static func matchesEntireDate(_ date: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(date.startIndex..., in: date)
        return expression.firstMatch(in: date, range: range)?.range == range
    }

    private static func hasValidTimeAndTimeZone(_ date: String) -> Bool {
        guard date.count > 10 else { return true }
        let value = String(date.dropFirst(11))
        let time: Substring
        let timeZone: Substring
        if value.hasSuffix("Z") {
            time = value.dropLast()
            timeZone = "Z"
        } else if let timeZoneStart = value.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            time = value[..<timeZoneStart]
            timeZone = value[timeZoneStart...]
        } else {
            return false
        }

        let timeParts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard timeParts.count == 3,
              let hour = Int(timeParts[0]), hour <= 23,
              let minute = Int(timeParts[1]), minute <= 59 else { return false }
        let second = timeParts[2].split(separator: ".", maxSplits: 1).first ?? ""
        guard let seconds = Int(second), seconds <= 59 else { return false }

        guard timeZone != "Z" else { return true }
        let offset = timeZone.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard offset.count == 2,
              let offsetHour = Int(offset[0]), offsetHour <= 23,
              let offsetMinute = Int(offset[1]), offsetMinute <= 59 else { return false }
        return true
    }

    private static func scalarValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func normalizedUnpaddedTimestamp(_ value: String) -> String? {
        let pattern = "^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})(T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2}))$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.range == NSRange(value.startIndex..., in: value),
              let yearRange = Range(match.range(at: 1), in: value),
              let monthRange = Range(match.range(at: 2), in: value),
              let dayRange = Range(match.range(at: 3), in: value),
              let timeRange = Range(match.range(at: 4), in: value),
              let month = Int(value[monthRange]),
              let day = Int(value[dayRange]) else { return nil }

        let normalized = "\(value[yearRange])-\(String(format: "%02d", month))-\(String(format: "%02d", day))\(value[timeRange])"
        guard normalized != value,
              dateIssue(in: "---\ndate: \(normalized)\n---\n") == nil else { return nil }
        return normalized
    }
}
