// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A block of formatted text from a depiction. Inline formatting (bold,
/// italics, code, links) stays in Markdown, for the app to render with the
/// system's own Markdown support; Codling lays out the blocks itself so that
/// they follow the system's fonts, colors and text size.
public enum MarkupBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// marker is "•" or a number such as "1."; depth starts at 0.
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case code(String)
    case rule
    case image(URL, alt: String, link: URL?)
}

public enum Markup {
    /// The most blocks one text is split into.
    static let blockLimit = 2000

    /// Markdown, which may contain basic HTML as Sileo's depictions allow.
    public static func blocks(markdown: String, base: URL?) -> [MarkupBlock] {
        let converted = HTMLConverter(base: base, htmlMode: false).convert(markdown)
        return MarkdownBlocks.parse(converted, base: base)
    }

    /// Basic HTML: paragraphs, line breaks, headings, lists, emphasis, links
    /// and images. Scripts and styles are dropped.
    public static func blocks(html: String, base: URL?) -> [MarkupBlock] {
        let converted = HTMLConverter(base: base, htmlMode: true).convert(html)
        return MarkdownBlocks.parse(converted, base: base)
    }
}

// MARK: - Markdown blocks

enum MarkdownBlocks {
    static func parse(_ text: String, base: URL?) -> [MarkupBlock] {
        var blocks: [MarkupBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var listIndents: [Int] = []
        var lastWasListItem = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks += splitImages(paragraph.joined(separator: "\n"), base: base)
                paragraph = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            if blocks.count >= Markup.blockLimit {
                break
            }
            let line = String(rawLine).replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            if var codeLines = code {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    code = nil
                } else {
                    codeLines.append(line)
                    code = codeLines
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                lastWasListItem = false
                code = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                lastWasListItem = false
                continue
            }
            if indent < 4, let heading = atxHeading(trimmed) {
                flushAll()
                lastWasListItem = false
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if indent < 4, !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: level, text: text))
                continue
            }
            if indent < 4, isRule(trimmed) {
                flushAll()
                lastWasListItem = false
                blocks.append(.rule)
                continue
            }
            if indent < 4, trimmed.hasPrefix(">") {
                flushParagraph()
                lastWasListItem = false
                var content = trimmed.dropFirst()
                if content.hasPrefix(" ") {
                    content = content.dropFirst()
                }
                quote.append(String(content))
                continue
            }
            if let item = listItem(trimmed) {
                flushAll()
                while let last = listIndents.last, last > indent {
                    listIndents.removeLast()
                }
                if listIndents.last != indent {
                    listIndents.append(indent)
                }
                blocks.append(.listItem(marker: item.marker, depth: max(listIndents.count - 1, 0), text: item.text))
                lastWasListItem = true
                continue
            }
            if lastWasListItem, indent > 0, case .listItem(let marker, let depth, let text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + "\n" + trimmed)
                continue
            }
            flushQuote()
            if !lastWasListItem {
                listIndents = []
            }
            lastWasListItem = false
            paragraph.append(trimmed)
        }
        if let codeLines = code {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of "#" is not part of the heading.
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func setextLevel(_ line: String) -> Int? {
        if line.allSatisfy({ $0 == "=" }) { return 1 }
        if line.count >= 2, line.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        guard let first = line.first else { return nil }
        if "-*+".contains(first) {
            let rest = line.dropFirst()
            guard rest.first == " " else { return nil }
            return ("•", rest.trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        return (digits + ".", after.trimmingCharacters(in: .whitespaces))
    }

    private static let imagePattern: NSRegularExpression = {
        // A linked image, [![alt](image)](link), or a plain one, ![alt](image).
        let image = #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#
        let linked = #"\[\s*"# + image + #"\s*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#
        return try! NSRegularExpression(pattern: linked + "|" + image)
    }()

    /// A paragraph, with its images taken out as image blocks.
    static func splitImages(_ text: String, base: URL?) -> [MarkupBlock] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = imagePattern.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return [.paragraph(text)]
        }
        var blocks: [MarkupBlock] = []
        var cursor = text.startIndex
        func addText(upTo end: String.Index) {
            let piece = text[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                blocks.append(.paragraph(piece))
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        for match in matches {
            guard let whole = Range(match.range, in: text) else { continue }
            addText(upTo: whole.lowerBound)
            cursor = whole.upperBound
            let linked = group(match, 2) != nil
            let alt = (linked ? group(match, 1) : group(match, 4)) ?? ""
            let source = linked ? group(match, 2) : group(match, 5)
            let link = linked ? DepictionURL.any(group(match, 3), base: base) : nil
            if let url = DepictionURL.web(source, base: base) {
                blocks.append(.image(url, alt: alt, link: link))
            } else if !alt.isEmpty {
                blocks.append(.paragraph(alt))
            }
        }
        addText(upTo: text.endIndex)
        return blocks
    }
}

// MARK: - HTML

/// Turns HTML into the Markdown above. In HTML mode whitespace collapses and
/// text is escaped so that it stays literal; in Markdown mode only the known
/// tags change and the rest of the text is left as written.
struct HTMLConverter {
    let base: URL?
    let htmlMode: Bool

    private static let blockTags: Set<String> = [
        "p", "section", "article", "header", "footer", "main", "aside", "nav", "blockquote", "table", "figure",
        "dl", "details",
    ]
    private static let lineTags: Set<String> = [
        "div", "center", "thead", "tbody", "tfoot", "figcaption", "dt", "dd", "summary",
    ]
    private static let skippedTags: Set<String> = [
        "script", "style", "head", "title", "noscript", "iframe", "svg", "select", "template", "object",
        "audio", "video", "canvas", "button", "textarea",
    ]
    private static let ignoredTags: Set<String> = [
        "html", "body", "span", "font", "u", "small", "big", "sup", "sub", "mark", "abbr", "cite", "label", "ins",
        "meta", "link", "input", "form", "source", "picture", "time", "address", "wbr", "q", "var", "kbd", "samp",
        "option",
    ]
    private static let emphasis: [String: String] = [
        "b": "**", "strong": "**", "i": "*", "em": "*", "s": "~~", "strike": "~~", "del": "~~",
    ]

    private struct Link {
        let url: URL?
        /// Where the output stood when the link opened, and the delimiters
        /// waiting to be written then, which go before the link's "[".
        let start: Int
        let prefix: String
        var usedByImage = false
    }

    private struct State {
        var output = ""
        /// Opening delimiters, written just before the next text so that
        /// they never sit next to a space.
        var pending = ""
        var lists: [(ordered: Bool, counter: Int)] = []
        var itemStart = false
        var links: [Link] = []
        var skipDepth = 0
        var preDepth = 0
    }

    func convert(_ source: String) -> String {
        var state = State()
        var index = source.startIndex
        while index < source.endIndex {
            guard let open = source[index...].firstIndex(of: "<") else {
                text(String(source[index...]), &state)
                break
            }
            if open > index {
                text(String(source[index..<open]), &state)
            }
            if let (tag, end) = Self.readTag(source, at: open) {
                handle(tag, raw: String(source[open..<end]), &state)
                index = end
            } else {
                // Not a tag: a "<" in text.
                text("<", &state)
                index = source.index(after: open)
            }
        }
        return state.output
    }

    // MARK: Tags

    struct Tag {
        var name: String
        var closing: Bool
        var attributes: [String: String]
        /// A comment or a declaration such as <!DOCTYPE html>.
        var ignorable: Bool
        /// Written <tag />.
        var selfClosing = false
    }

    /// The tag that starts at index, and where it ends; nil when the "<"
    /// does not start a tag.
    static func readTag(_ source: String, at index: String.Index) -> (Tag, String.Index)? {
        let after = source.index(after: index)
        guard after < source.endIndex else { return nil }
        if source[after...].hasPrefix("!--") {
            guard let end = source[after...].range(of: "-->") else { return nil }
            return (Tag(name: "", closing: false, attributes: [:], ignorable: true), end.upperBound)
        }
        if source[after] == "!" || source[after] == "?" {
            guard let end = source[after...].firstIndex(of: ">") else { return nil }
            return (Tag(name: "", closing: false, attributes: [:], ignorable: true), source.index(after: end))
        }
        var cursor = after
        let closing = source[cursor] == "/"
        if closing {
            cursor = source.index(after: cursor)
        }
        let nameStart = cursor
        while cursor < source.endIndex, source[cursor].isASCII, source[cursor].isLetter || source[cursor].isNumber {
            cursor = source.index(after: cursor)
        }
        guard cursor > nameStart, source[nameStart].isLetter else { return nil }
        let name = source[nameStart..<cursor].lowercased()
        guard cursor < source.endIndex, source[cursor] == ">" || source[cursor] == "/" || source[cursor].isWhitespace else {
            return nil
        }
        // Attributes, up to the ">" that is not inside quotes.
        var attributes: [String: String] = [:]
        var slash = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == ">" {
                return (Tag(name: name, closing: closing, attributes: attributes, ignorable: false, selfClosing: slash),
                        source.index(after: cursor))
            }
            if character.isWhitespace || character == "/" {
                if character == "/" {
                    slash = true
                }
                cursor = source.index(after: cursor)
                continue
            }
            slash = false
            let keyStart = cursor
            while cursor < source.endIndex, !source[cursor].isWhitespace, source[cursor] != "=", source[cursor] != ">" {
                cursor = source.index(after: cursor)
            }
            let key = source[keyStart..<cursor].lowercased()
            while cursor < source.endIndex, source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }
            var value = ""
            if cursor < source.endIndex, source[cursor] == "=" {
                cursor = source.index(after: cursor)
                while cursor < source.endIndex, source[cursor].isWhitespace {
                    cursor = source.index(after: cursor)
                }
                if cursor < source.endIndex, source[cursor] == "\"" || source[cursor] == "'" {
                    let quote = source[cursor]
                    let valueStart = source.index(after: cursor)
                    guard let valueEnd = source[valueStart...].firstIndex(of: quote) else { return nil }
                    value = String(source[valueStart..<valueEnd])
                    cursor = source.index(after: valueEnd)
                } else {
                    let valueStart = cursor
                    while cursor < source.endIndex, !source[cursor].isWhitespace, source[cursor] != ">" {
                        cursor = source.index(after: cursor)
                    }
                    value = String(source[valueStart..<cursor])
                }
            }
            if !key.isEmpty {
                attributes[key] = Entities.decode(value)
            }
        }
        return nil
    }

    private func handle(_ tag: Tag, raw: String, _ state: inout State) {
        if tag.ignorable {
            return
        }
        let name = tag.name
        if Self.skippedTags.contains(name) {
            if tag.closing {
                state.skipDepth = max(state.skipDepth - 1, 0)
            } else if !tag.selfClosing {
                state.skipDepth += 1
            }
            return
        }
        if state.skipDepth > 0 {
            return
        }
        if let delimiter = Self.emphasis[name] {
            if tag.closing {
                close(delimiter, &state)
            } else {
                state.pending += delimiter
            }
            return
        }
        switch name {
        case "br":
            lineBreak(&state, blank: false)
        case "hr":
            blankLine(&state)
            state.output += "---"
            blankLine(&state)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            blankLine(&state)
            if !tag.closing, let level = Int(name.dropFirst()) {
                state.output += String(repeating: "#", count: level) + " "
            }
        case "ul", "ol":
            if tag.closing {
                if !state.lists.isEmpty {
                    state.lists.removeLast()
                }
            } else {
                state.lists.append((name == "ol", 0))
            }
            if state.lists.isEmpty {
                blankLine(&state)
            } else {
                newline(&state)
            }
        case "li":
            newline(&state)
            if !tag.closing {
                var marker = "- "
                if var list = state.lists.last, list.ordered {
                    list.counter += 1
                    state.lists[state.lists.count - 1] = list
                    marker = "\(list.counter). "
                }
                state.output += String(repeating: "  ", count: max(state.lists.count - 1, 0)) + marker
                state.itemStart = true
            }
        case "pre":
            if tag.closing {
                if state.preDepth > 0 {
                    state.preDepth -= 1
                    newline(&state)
                    state.output += "```"
                    blankLine(&state)
                }
            } else {
                blankLine(&state)
                state.output += "```\n"
                state.preDepth += 1
            }
        case "code":
            if state.preDepth == 0 {
                if tag.closing {
                    close("`", &state)
                } else {
                    state.pending += "`"
                }
            }
        case "a":
            if tag.closing {
                closeLink(&state)
            } else {
                let href = tag.attributes["href"]
                let url = href.flatMap { $0.lowercased().hasPrefix("javascript:") ? nil : DepictionURL.any($0, base: base) }
                state.links.append(Link(url: url, start: state.output.count, prefix: state.pending))
            }
        case "img":
            image(tag, &state)
        case "tr":
            newline(&state)
        case "td", "th":
            if tag.closing {
                state.output += " "
            }
        default:
            if Self.blockTags.contains(name) {
                lineBreak(&state, blank: true)
            } else if Self.lineTags.contains(name) {
                lineBreak(&state, blank: false)
            } else if !htmlMode, !Self.ignoredTags.contains(name) {
                // An unknown tag in Markdown stays as written.
                text(raw, &state, literal: true)
            }
        }
    }

    private func image(_ tag: Tag, _ state: inout State) {
        guard let url = DepictionURL.web(tag.attributes["src"], base: base) else { return }
        // Tracking pixels and spacers.
        for key in ["width", "height"] {
            if let size = tag.attributes[key].flatMap({ Double($0.filter { $0.isNumber || $0 == "." }) }), size <= 2 {
                return
            }
        }
        let alt = Self.escape(tag.attributes["alt"] ?? "").replacingOccurrences(of: "\n", with: " ")
        var link: URL?
        if let last = state.links.indices.last, let url = state.links[last].url {
            // Text already in the link keeps it; the image gets it too.
            let open = state.links[last]
            finishLink(open, url: url, &state)
            state.links[last].usedByImage = true
            link = url
        }
        newline(&state)
        let markdown = "![\(alt)](\(Self.urlText(url)))"
        state.output += link.map { "[\(markdown)](\(Self.urlText($0)))" } ?? markdown
        newline(&state)
    }

    private func closeLink(_ state: inout State) {
        guard let link = state.links.popLast(), let url = link.url, !link.usedByImage else { return }
        finishLink(link, url: url, &state)
    }

    /// Wraps the text written since the link opened in Markdown link syntax,
    /// when there is text and it stays on one line.
    private func finishLink(_ link: Link, url: URL, _ state: inout State) {
        let output = state.output
        guard link.start < output.count else { return }
        var index = output.index(output.startIndex, offsetBy: link.start)
        while index < output.endIndex, output[index] == " " {
            index = output.index(after: index)
        }
        if output[index...].hasPrefix(link.prefix) {
            index = output.index(index, offsetBy: link.prefix.count)
        }
        let linked = output[index...]
        guard !linked.contains("\n"), !linked.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.output.insert("[", at: index)
        appendClosing("](\(Self.urlText(url)))", &state)
    }

    // MARK: Text

    private func text(_ raw: String, _ state: inout State, literal: Bool = false) {
        guard state.skipDepth == 0, !raw.isEmpty else { return }
        if state.preDepth > 0 {
            flushPending(&state)
            state.output += htmlMode ? Entities.decode(raw) : raw
            return
        }
        guard htmlMode, !literal else {
            let leading = raw.prefix { $0 == " " }
            state.output += leading
            flushPending(&state)
            state.output += raw.dropFirst(leading.count)
            state.itemStart = false
            return
        }
        var collapsed = ""
        var lastWasSpace = false
        for character in Entities.decode(raw) {
            if character.isWhitespace && character != "\u{00A0}" {
                if !lastWasSpace {
                    collapsed.append(" ")
                }
                lastWasSpace = true
            } else {
                collapsed.append(character == "\u{00A0}" ? " " : character)
                lastWasSpace = false
            }
        }
        if collapsed.hasPrefix(" ") {
            collapsed.removeFirst()
            if !(state.output.isEmpty || state.output.hasSuffix("\n") || state.output.hasSuffix(" ")) {
                state.output += " "
            }
        }
        guard !collapsed.isEmpty else { return }
        let lineStart = (state.output.isEmpty || state.output.hasSuffix("\n")) && state.pending.isEmpty
        flushPending(&state)
        let escaped = Self.escape(collapsed)
        state.output += lineStart ? Self.escapeLineStart(escaped) : escaped
        state.itemStart = false
    }

    private func flushPending(_ state: inout State) {
        state.output += state.pending
        state.pending = ""
    }

    /// Closes a delimiter; one whose opening is still waiting (nothing came
    /// between the tags) is dropped.
    private func close(_ delimiter: String, _ state: inout State) {
        if state.pending.hasSuffix(delimiter) {
            state.pending.removeLast(delimiter.count)
            return
        }
        appendClosing(delimiter, &state)
    }

    /// Writes a closing delimiter before any trailing spaces, so that
    /// Markdown still sees it as closing.
    private func appendClosing(_ delimiter: String, _ state: inout State) {
        var trailing = ""
        while state.output.hasSuffix(" ") {
            trailing.append(" ")
            state.output.removeLast()
        }
        state.output += delimiter + trailing
    }

    /// A line break, or a paragraph break when blank; inside a list item the
    /// next line stays part of the item.
    private func lineBreak(_ state: inout State, blank: Bool) {
        guard !state.lists.isEmpty else {
            if blank {
                blankLine(&state)
            } else {
                newline(&state)
            }
            return
        }
        if state.itemStart {
            return
        }
        newline(&state)
        state.output += String(repeating: "  ", count: state.lists.count)
    }

    private func newline(_ state: inout State) {
        state.pending = ""
        state.itemStart = false
        while state.output.hasSuffix(" ") {
            state.output.removeLast()
        }
        if !state.output.isEmpty && !state.output.hasSuffix("\n") {
            state.output += "\n"
        }
    }

    private func blankLine(_ state: inout State) {
        newline(&state)
        if !state.output.isEmpty && !state.output.hasSuffix("\n\n") {
            state.output += "\n"
        }
    }

    // MARK: Escaping

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "\\`*_[]<>~&".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Escapes what would start a heading, quote or list at the start of a line.
    static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#>-+".contains(first) {
            return "\\" + text
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, let next = text.dropFirst(digits.count).first, next == "." || next == ")" {
            return digits + "\\" + text.dropFirst(digits.count)
        }
        return text
    }

    /// A URL as Markdown link syntax can hold it.
    static func urlText(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }
}

enum Entities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "bull": "•", "middot": "·", "rsquo": "’",
        "lsquo": "‘", "rdquo": "”", "ldquo": "“", "laquo": "«", "raquo": "»", "deg": "°", "times": "×",
        "rarr": "→", "larr": "←", "hearts": "♥", "star": "☆", "check": "✓", "euro": "€", "pound": "£", "yen": "¥",
        "cent": "¢", "sect": "§", "para": "¶", "plusmn": "±", "frac12": "½", "shy": "",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = named[String(entity)]
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }
}
