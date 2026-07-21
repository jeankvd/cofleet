import Foundation
import SwiftUI

#if !os(watchOS)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct CoFleetRichNoteDocument: Equatable, Sendable {
    public var blocks: [CoFleetRichNoteBlock]

    public init(blocks: [CoFleetRichNoteBlock] = []) {
        self.blocks = blocks
    }
}

public struct CoFleetRichNoteBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case unorderedList
        case orderedList(ordinal: Int)
        case quote
        case codeBlock(language: String?)
        case checklist(isChecked: Bool)
    }

    public var kind: Kind
    public var runs: [CoFleetRichNoteRun]

    public init(kind: Kind = .paragraph, runs: [CoFleetRichNoteRun] = []) {
        self.kind = kind
        self.runs = runs
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }
}

public struct CoFleetRichNoteStyle: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = Self(rawValue: 1 << 0)
    public static let italic = Self(rawValue: 1 << 1)
    public static let inlineCode = Self(rawValue: 1 << 2)
}

public struct CoFleetRichNoteRun: Equatable, Sendable {
    public var text: String
    public var styles: CoFleetRichNoteStyle
    public var link: String?

    public init(text: String, styles: CoFleetRichNoteStyle = [], link: String? = nil) {
        self.text = text
        self.styles = styles
        self.link = link
    }
}

/// The portable storage boundary for CoFleet notes. The editor uses attributed text in memory,
/// while this codec keeps the persisted and synchronized representation deterministic Markdown.
public enum CoFleetRichNoteMarkdownCodec {
    public static func parse(_ markdown: String) -> CoFleetRichNoteDocument {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [CoFleetRichNoteBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if let fence = fenceOpening(in: line) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].hasPrefix(fence.marker) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.init(
                    kind: .codeBlock(language: fence.language),
                    runs: [.init(text: codeLines.joined(separator: "\n"))]
                ))
                continue
            }

            let parsed = parseBlockLine(line)
            blocks.append(.init(kind: parsed.kind, runs: parseInline(parsed.content)))
            index += 1
        }

        if markdown.isEmpty { return .init() }
        return .init(blocks: blocks)
    }

    public static func serialize(_ document: CoFleetRichNoteDocument) -> String {
        document.blocks.map(serializeBlock).joined(separator: "\n")
    }

    private static func parseBlockLine(_ line: String) -> (kind: CoFleetRichNoteBlock.Kind, content: String) {
        if let heading = heading(in: line) {
            return (.heading(level: heading.level), heading.content)
        }
        if line.hasPrefix("- [ ] ") {
            return (.checklist(isChecked: false), String(line.dropFirst(6)))
        }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return (.checklist(isChecked: true), String(line.dropFirst(6)))
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (.unorderedList, String(line.dropFirst(2)))
        }
        if let ordered = orderedItem(in: line) {
            return (.orderedList(ordinal: ordered.ordinal), ordered.content)
        }
        if line.hasPrefix("> ") {
            return (.quote, String(line.dropFirst(2)))
        }
        return (.paragraph, line)
    }

    private static func serializeBlock(_ block: CoFleetRichNoteBlock) -> String {
        let content = serializeInline(block.runs)
        switch block.kind {
        case .paragraph:
            return content
        case let .heading(level):
            return String(repeating: "#", count: min(max(level, 1), 6)) + " " + content
        case .unorderedList:
            return "- " + content
        case let .orderedList(ordinal):
            return "\(max(ordinal, 1)). " + content
        case .quote:
            return "> " + content
        case let .checklist(isChecked):
            return "- [\(isChecked ? "x" : " ")] " + content
        case let .codeBlock(language):
            let raw = block.plainText
            let marker = raw.contains("```") ? "````" : "```"
            return marker + (language ?? "") + "\n" + raw + "\n" + marker
        }
    }

    private static func parseInline(
        _ source: String,
        inheritedStyles: CoFleetRichNoteStyle = [],
        inheritedLink: String? = nil
    ) -> [CoFleetRichNoteRun] {
        let characters = Array(source)
        var runs: [CoFleetRichNoteRun] = []
        var buffer = ""
        var index = 0

        func append(_ text: String, styles: CoFleetRichNoteStyle, link: String?) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.styles == styles, last.link == link {
                runs[runs.count - 1].text += text
            } else {
                runs.append(.init(text: text, styles: styles, link: link))
            }
        }

        func flush() {
            append(buffer, styles: inheritedStyles, link: inheritedLink)
            buffer = ""
        }

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }

            if has("**", at: index, in: characters),
               let end = find("**", after: index + 2, in: characters) {
                flush()
                let inner = String(characters[(index + 2)..<end])
                runs.append(contentsOf: parseInline(
                    inner,
                    inheritedStyles: inheritedStyles.union(.bold),
                    inheritedLink: inheritedLink
                ))
                index = end + 2
                continue
            }

            if characters[index] == "_",
               let end = find("_", after: index + 1, in: characters) {
                flush()
                let inner = String(characters[(index + 1)..<end])
                runs.append(contentsOf: parseInline(
                    inner,
                    inheritedStyles: inheritedStyles.union(.italic),
                    inheritedLink: inheritedLink
                ))
                index = end + 1
                continue
            }

            if characters[index] == "`",
               let end = find("`", after: index + 1, in: characters) {
                flush()
                append(
                    String(characters[(index + 1)..<end]),
                    styles: inheritedStyles.union(.inlineCode),
                    link: inheritedLink
                )
                index = end + 1
                continue
            }

            if characters[index] == "[",
               let labelEnd = find("](", after: index + 1, in: characters),
               let destinationEnd = find(")", after: labelEnd + 2, in: characters) {
                flush()
                let label = String(characters[(index + 1)..<labelEnd])
                let destination = String(characters[(labelEnd + 2)..<destinationEnd])
                runs.append(contentsOf: parseInline(
                    label,
                    inheritedStyles: inheritedStyles,
                    inheritedLink: destination
                ))
                index = destinationEnd + 1
                continue
            }

            buffer.append(characters[index])
            index += 1
        }
        flush()
        return runs
    }

    private static func serializeInline(_ runs: [CoFleetRichNoteRun]) -> String {
        runs.map { run in
            var text = escapeInline(run.text)
            if run.styles.contains(.inlineCode) {
                let marker = run.text.contains("`") ? "``" : "`"
                text = marker + run.text + marker
            }
            if run.styles.contains(.italic) { text = "_" + text + "_" }
            if run.styles.contains(.bold) { text = "**" + text + "**" }
            if let link = run.link {
                text = "[" + text + "](" + escapeDestination(link) + ")"
            }
            return text
        }.joined()
    }

    private static func escapeInline(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_`[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func escapeDestination(_ destination: String) -> String {
        destination.replacingOccurrences(of: ")", with: "%29")
    }

    private static func heading(in line: String) -> (level: Int, content: String)? {
        let characters = Array(line)
        var level = 0
        while level < min(6, characters.count), characters[level] == "#" { level += 1 }
        guard level > 0, characters.count > level, characters[level] == " " else { return nil }
        return (level, String(characters.dropFirst(level + 1)))
    }

    private static func orderedItem(in line: String) -> (ordinal: Int, content: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        guard index > 0,
              index + 1 < characters.count,
              characters[index] == ".",
              characters[index + 1] == " ",
              let ordinal = Int(String(characters[..<index])) else { return nil }
        return (ordinal, String(characters.dropFirst(index + 2)))
    }

    private static func fenceOpening(in line: String) -> (marker: String, language: String?)? {
        let characters = Array(line)
        var length = 0
        while length < characters.count, characters[length] == "`" { length += 1 }
        guard length >= 3 else { return nil }
        let language = String(characters.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        return (String(repeating: "`", count: length), language.isEmpty ? nil : language)
    }

    private static func has(_ token: String, at index: Int, in characters: [Character]) -> Bool {
        let tokenCharacters = Array(token)
        guard index + tokenCharacters.count <= characters.count else { return false }
        return Array(characters[index..<(index + tokenCharacters.count)]) == tokenCharacters
    }

    private static func find(_ token: String, after start: Int, in characters: [Character]) -> Int? {
        guard start < characters.count else { return nil }
        var index = start
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if has(token, at: index, in: characters) { return index }
            index += 1
        }
        return nil
    }
}

public enum CoFleetMarkdownCommand: String, CaseIterable, Sendable {
    case heading
    case bold
    case italic
    case link
    case unorderedList
    case orderedList
    case quote
    case inlineCode
    case codeBlock
    case checklist

    public var title: String {
        switch self {
        case .heading: "Heading"
        case .bold: "Bold"
        case .italic: "Italic"
        case .link: "Link"
        case .unorderedList: "Bulleted list"
        case .orderedList: "Numbered list"
        case .quote: "Quote"
        case .inlineCode: "Inline code"
        case .codeBlock: "Code block"
        case .checklist: "Checklist"
        }
    }

    public var symbol: String {
        switch self {
        case .heading: "textformat.size"
        case .bold: "bold"
        case .italic: "italic"
        case .link: "link"
        case .unorderedList: "list.bullet"
        case .orderedList: "list.number"
        case .quote: "text.quote"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .codeBlock: "curlybraces.square"
        case .checklist: "checklist"
        }
    }

    public func applying(to markdown: String) -> String {
        var document = CoFleetRichNoteMarkdownCodec.parse(markdown)
        let block: CoFleetRichNoteBlock
        switch self {
        case .heading: block = .init(kind: .heading(level: 2), runs: [.init(text: "Heading")])
        case .bold: block = .init(runs: [.init(text: "bold text", styles: .bold)])
        case .italic: block = .init(runs: [.init(text: "italic text", styles: .italic)])
        case .link: block = .init(runs: [.init(text: "link text", link: "https://example.com")])
        case .unorderedList: block = .init(kind: .unorderedList, runs: [.init(text: "List item")])
        case .orderedList: block = .init(kind: .orderedList(ordinal: 1), runs: [.init(text: "List item")])
        case .quote: block = .init(kind: .quote, runs: [.init(text: "Quote")])
        case .inlineCode: block = .init(runs: [.init(text: "code", styles: .inlineCode)])
        case .codeBlock: block = .init(kind: .codeBlock(language: nil), runs: [.init(text: "code")])
        case .checklist: block = .init(kind: .checklist(isChecked: false), runs: [.init(text: "Task")])
        }
        if !document.blocks.isEmpty { document.blocks.append(.init()) }
        document.blocks.append(block)
        return CoFleetRichNoteMarkdownCodec.serialize(document)
    }
}

private struct CoFleetEditorInvocation: Equatable {
    var sequence: Int
    var command: CoFleetMarkdownCommand
    var linkDestination: String?
}

public struct CoFleetRichNoteEditor: View {
    @Binding private var markdown: String
    private var isReadOnly: Bool
    @State private var commandSequence = 0
    @State private var invocation: CoFleetEditorInvocation?
    @State private var isPresentingLink = false
    @State private var linkDestination = "https://"

    public init(markdown: Binding<String>, isReadOnly: Bool = false) {
        _markdown = markdown
        self.isReadOnly = isReadOnly
    }

    public var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(CoFleetMarkdownCommand.allCases, id: \.self) { command in
                        Button {
                            if command == .link {
                                isPresentingLink = true
                            } else {
                                invoke(command)
                            }
                        } label: {
                            Image(systemName: command.symbol)
                                .frame(width: 25, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isReadOnly)
                        .help(command.title)
                        .accessibilityLabel(command.title)
                    }
                }
            }
            CoFleetNativeRichTextEditor(markdown: $markdown, isReadOnly: isReadOnly, invocation: invocation)
                .frame(minHeight: 120)
                .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("cofleet.note.editor")
        }
        .alert("Add Link", isPresented: $isPresentingLink) {
            TextField("https://example.com", text: $linkDestination)
            Button("Cancel", role: .cancel) {}
            Button("Apply") { invoke(.link, linkDestination: linkDestination) }
                .disabled(URL(string: linkDestination)?.scheme == nil)
        } message: {
            Text("The selected text will link to this address.")
        }
    }

    private func invoke(_ command: CoFleetMarkdownCommand, linkDestination: String? = nil) {
        commandSequence += 1
        invocation = .init(sequence: commandSequence, command: command, linkDestination: linkDestination)
    }
}

private extension NSAttributedString.Key {
    static let coFleetBlockKind = Self("dev.cofleet.note.block-kind")
    static let coFleetBlockValue = Self("dev.cofleet.note.block-value")
    static let coFleetBold = Self("dev.cofleet.note.bold")
    static let coFleetItalic = Self("dev.cofleet.note.italic")
    static let coFleetInlineCode = Self("dev.cofleet.note.inline-code")
    static let coFleetGeneratedPrefix = Self("dev.cofleet.note.generated-prefix")
}

@MainActor
private enum CoFleetAttributedNoteCodec {
    static func attributedString(markdown: String) -> NSAttributedString {
        attributedString(document: CoFleetRichNoteMarkdownCodec.parse(markdown))
    }

    static func attributedString(document: CoFleetRichNoteDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let blockStart = result.length
            let prefix = visualPrefix(for: block.kind)
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: [.coFleetGeneratedPrefix: true]))
            }
            for run in block.runs {
                result.append(NSAttributedString(string: run.text, attributes: attributes(for: run, block: block.kind)))
            }
            let length = result.length - blockStart
            if length > 0 {
                result.addAttributes(blockAttributes(for: block.kind), range: NSRange(location: blockStart, length: length))
            }
        }
        return result
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        CoFleetRichNoteMarkdownCodec.serialize(document(from: attributedString))
    }

    static func document(from attributedString: NSAttributedString) -> CoFleetRichNoteDocument {
        guard attributedString.length > 0 else { return .init() }
        let source = attributedString.string as NSString
        var blocks: [CoFleetRichNoteBlock] = []
        var location = 0

        while location <= source.length {
            let nextNewline = source.range(of: "\n", options: [], range: NSRange(location: location, length: source.length - location))
            let lineEnd = nextNewline.location == NSNotFound ? source.length : nextNewline.location
            let lineRange = NSRange(location: location, length: lineEnd - location)
            let attributeLocation = min(location, attributedString.length - 1)
            let attributes = attributedString.attributes(at: attributeLocation, effectiveRange: nil)
            let kind = blockKind(from: attributes)
            let contentRange = contentRangeExcludingGeneratedPrefix(in: lineRange, attributedString: attributedString)
            let runs = semanticRuns(in: contentRange, attributedString: attributedString)

            if case let .codeBlock(language) = kind, case .codeBlock = blocks.last?.kind {
                blocks[blocks.count - 1].runs.append(.init(text: "\n"))
                blocks[blocks.count - 1].runs.append(contentsOf: runs)
                if language != codeLanguage(blocks[blocks.count - 1].kind) {
                    blocks[blocks.count - 1].kind = .codeBlock(language: language)
                }
            } else {
                blocks.append(.init(kind: kind, runs: runs))
            }

            if nextNewline.location == NSNotFound { break }
            location = nextNewline.location + 1
            if location == source.length {
                blocks.append(.init())
                break
            }
        }
        return .init(blocks: blocks)
    }

    static func apply(_ invocation: CoFleetEditorInvocation, to textStorage: NSMutableAttributedString, selection: NSRange) -> NSRange {
        switch invocation.command {
        case .bold, .italic, .inlineCode, .link:
            return applyInline(invocation, to: textStorage, selection: selection)
        case .heading, .unorderedList, .orderedList, .quote, .codeBlock, .checklist:
            return applyBlock(invocation.command, to: textStorage, selection: selection)
        }
    }

    private static func applyInline(_ invocation: CoFleetEditorInvocation, to storage: NSMutableAttributedString, selection: NSRange) -> NSRange {
        var range = selection
        if range.length == 0 {
            let placeholder: String
            switch invocation.command {
            case .bold: placeholder = "bold text"
            case .italic: placeholder = "italic text"
            case .inlineCode: placeholder = "code"
            case .link: placeholder = "link"
            default: placeholder = "text"
            }
            storage.insert(NSAttributedString(string: placeholder), at: range.location)
            range.length = (placeholder as NSString).length
        }

        let key: NSAttributedString.Key?
        switch invocation.command {
        case .bold: key = .coFleetBold
        case .italic: key = .coFleetItalic
        case .inlineCode: key = .coFleetInlineCode
        case .link: key = .link
        default: key = nil
        }
        guard let key else { return range }

        if invocation.command == .link {
            if let destination = invocation.linkDestination, let url = URL(string: destination) {
                storage.addAttribute(.link, value: url, range: range)
            }
        } else {
            var fullyApplied = true
            storage.enumerateAttribute(key, in: range) { value, _, stop in
                if (value as? Bool) != true {
                    fullyApplied = false
                    stop.pointee = true
                }
            }
            if fullyApplied { storage.removeAttribute(key, range: range) }
            else { storage.addAttribute(key, value: true, range: range) }
        }
        restyle(storage, range: range)
        return range
    }

    private static func applyBlock(_ command: CoFleetMarkdownCommand, to storage: NSMutableAttributedString, selection: NSRange) -> NSRange {
        guard storage.length > 0 else {
            let placeholder = command == .checklist ? "Task" : "Text"
            storage.append(NSAttributedString(string: placeholder))
            return applyBlock(command, to: storage, selection: NSRange(location: 0, length: storage.length))
        }
        let source = storage.string as NSString
        let safeLocation = min(selection.location, source.length)
        let safeSelection = NSRange(location: safeLocation, length: min(selection.length, max(0, source.length - safeLocation)))
        let paragraphRange = source.paragraphRange(for: safeSelection)
        var paragraphRanges: [NSRange] = []
        var cursor = paragraphRange.location
        while cursor < NSMaxRange(paragraphRange) {
            let range = source.paragraphRange(for: NSRange(location: cursor, length: 0))
            paragraphRanges.append(range)
            cursor = NSMaxRange(range)
        }
        if paragraphRanges.isEmpty { paragraphRanges = [paragraphRange] }

        for (offset, rawRange) in paragraphRanges.enumerated().reversed() {
            var contentRange = rawRange
            if contentRange.length > 0,
               (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)) == "\n" {
                contentRange.length -= 1
            }
            let attributeLocation = min(contentRange.location, storage.length - 1)
            let oldKind = blockKind(from: storage.attributes(at: attributeLocation, effectiveRange: nil))
            let target = toggledBlockKind(command, oldKind: oldKind, ordinal: offset + 1)

            let prefixRange = generatedPrefixRange(at: contentRange.location, in: storage)
            if prefixRange.length > 0 {
                storage.deleteCharacters(in: prefixRange)
                contentRange.length -= prefixRange.length
            }
            let prefix = visualPrefix(for: target)
            if !prefix.isEmpty {
                storage.insert(NSAttributedString(string: prefix, attributes: [.coFleetGeneratedPrefix: true]), at: contentRange.location)
                contentRange.length += (prefix as NSString).length
            }
            if contentRange.length > 0 {
                storage.addAttributes(blockAttributes(for: target), range: contentRange)
                restyle(storage, range: contentRange)
            }
        }
        return NSRange(location: min(selection.location, storage.length), length: 0)
    }

    private static func toggledBlockKind(_ command: CoFleetMarkdownCommand, oldKind: CoFleetRichNoteBlock.Kind, ordinal: Int) -> CoFleetRichNoteBlock.Kind {
        if command == .heading, case let .heading(level) = oldKind {
            return level < 3 ? .heading(level: level + 1) : .paragraph
        }
        if command == .checklist, case let .checklist(isChecked) = oldKind {
            return isChecked ? .paragraph : .checklist(isChecked: true)
        }
        let target: CoFleetRichNoteBlock.Kind
        switch command {
        case .heading: target = .heading(level: 2)
        case .unorderedList: target = .unorderedList
        case .orderedList: target = .orderedList(ordinal: ordinal)
        case .quote: target = .quote
        case .codeBlock: target = .codeBlock(language: nil)
        case .checklist: target = .checklist(isChecked: false)
        default: target = .paragraph
        }
        return sameKind(oldKind, target) ? .paragraph : target
    }

    private static func sameKind(_ lhs: CoFleetRichNoteBlock.Kind, _ rhs: CoFleetRichNoteBlock.Kind) -> Bool {
        switch (lhs, rhs) {
        case (.paragraph, .paragraph), (.unorderedList, .unorderedList), (.quote, .quote): true
        case (.heading, .heading), (.orderedList, .orderedList), (.codeBlock, .codeBlock), (.checklist, .checklist): true
        default: false
        }
    }

    private static func semanticRuns(in range: NSRange, attributedString: NSAttributedString) -> [CoFleetRichNoteRun] {
        guard range.length > 0 else { return [] }
        var runs: [CoFleetRichNoteRun] = []
        attributedString.enumerateAttributes(in: range) { attributes, subrange, _ in
            let text = (attributedString.string as NSString).substring(with: subrange)
            guard !text.isEmpty else { return }
            var styles: CoFleetRichNoteStyle = []
            if attributes[.coFleetBold] as? Bool == true { styles.insert(.bold) }
            if attributes[.coFleetItalic] as? Bool == true { styles.insert(.italic) }
            if attributes[.coFleetInlineCode] as? Bool == true { styles.insert(.inlineCode) }
            let link: String?
            if let url = attributes[.link] as? URL { link = url.absoluteString }
            else { link = attributes[.link] as? String }
            if let last = runs.last, last.styles == styles, last.link == link {
                runs[runs.count - 1].text += text
            } else {
                runs.append(.init(text: text, styles: styles, link: link))
            }
        }
        return runs
    }

    private static func contentRangeExcludingGeneratedPrefix(in lineRange: NSRange, attributedString: NSAttributedString) -> NSRange {
        guard lineRange.length > 0 else { return lineRange }
        let prefix = generatedPrefixRange(at: lineRange.location, in: attributedString)
        return NSRange(location: lineRange.location + prefix.length, length: max(0, lineRange.length - prefix.length))
    }

    private static func generatedPrefixRange(at location: Int, in attributedString: NSAttributedString) -> NSRange {
        guard location < attributedString.length,
              attributedString.attribute(.coFleetGeneratedPrefix, at: location, effectiveRange: nil) as? Bool == true else {
            return NSRange(location: location, length: 0)
        }
        var effective = NSRange()
        _ = attributedString.attribute(.coFleetGeneratedPrefix, at: location, effectiveRange: &effective)
        return effective
    }

    private static func blockKind(from attributes: [NSAttributedString.Key: Any]) -> CoFleetRichNoteBlock.Kind {
        let value = attributes[.coFleetBlockValue]
        switch attributes[.coFleetBlockKind] as? String {
        case "heading": return .heading(level: value as? Int ?? 2)
        case "unordered-list": return .unorderedList
        case "ordered-list": return .orderedList(ordinal: value as? Int ?? 1)
        case "quote": return .quote
        case "code-block": return .codeBlock(language: value as? String)
        case "checklist": return .checklist(isChecked: value as? Bool ?? false)
        default: return .paragraph
        }
    }

    private static func blockAttributes(for kind: CoFleetRichNoteBlock.Kind) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.coFleetBlockKind: "paragraph"]
        switch kind {
        case .paragraph: break
        case let .heading(level):
            attributes[.coFleetBlockKind] = "heading"
            attributes[.coFleetBlockValue] = level
        case .unorderedList: attributes[.coFleetBlockKind] = "unordered-list"
        case let .orderedList(ordinal):
            attributes[.coFleetBlockKind] = "ordered-list"
            attributes[.coFleetBlockValue] = ordinal
        case .quote: attributes[.coFleetBlockKind] = "quote"
        case let .codeBlock(language):
            attributes[.coFleetBlockKind] = "code-block"
            if let language { attributes[.coFleetBlockValue] = language }
        case let .checklist(isChecked):
            attributes[.coFleetBlockKind] = "checklist"
            attributes[.coFleetBlockValue] = isChecked
        }
        attributes[.paragraphStyle] = paragraphStyle(for: kind)
        return attributes
    }

    private static func visualPrefix(for kind: CoFleetRichNoteBlock.Kind) -> String {
        switch kind {
        case .unorderedList: "•  "
        case let .orderedList(ordinal): "\(ordinal).  "
        case .quote: "▌  "
        case let .checklist(isChecked): isChecked ? "☑︎  " : "☐  "
        default: ""
        }
    }

    private static func codeLanguage(_ kind: CoFleetRichNoteBlock.Kind) -> String? {
        if case let .codeBlock(language) = kind { return language }
        return nil
    }

    private static func restyle(_ storage: NSMutableAttributedString, range: NSRange) {
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            let kind = blockKind(from: attributes)
            var styles: CoFleetRichNoteStyle = []
            if attributes[.coFleetBold] as? Bool == true { styles.insert(.bold) }
            if attributes[.coFleetItalic] as? Bool == true { styles.insert(.italic) }
            if attributes[.coFleetInlineCode] as? Bool == true { styles.insert(.inlineCode) }
            storage.addAttribute(.font, value: font(styles: styles, block: kind), range: subrange)
            if styles.contains(.inlineCode) || codeLanguage(kind) != nil {
                storage.addAttribute(.backgroundColor, value: codeBackgroundColor, range: subrange)
            } else {
                storage.removeAttribute(.backgroundColor, range: subrange)
            }
        }
    }

    private static func attributes(for run: CoFleetRichNoteRun, block: CoFleetRichNoteBlock.Kind) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(styles: run.styles, block: block),
            .foregroundColor: primaryTextColor,
        ]
        if run.styles.contains(.bold) { attributes[.coFleetBold] = true }
        if run.styles.contains(.italic) { attributes[.coFleetItalic] = true }
        if run.styles.contains(.inlineCode) {
            attributes[.coFleetInlineCode] = true
            attributes[.backgroundColor] = codeBackgroundColor
        }
        if codeLanguage(block) != nil { attributes[.backgroundColor] = codeBackgroundColor }
        if let link = run.link, let url = URL(string: link) {
            attributes[.link] = url
            attributes[.foregroundColor] = linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    #if canImport(AppKit)
    private static var primaryTextColor: NSColor { .labelColor }
    private static var linkColor: NSColor { .linkColor }
    private static var codeBackgroundColor: NSColor { .quaternaryLabelColor.withAlphaComponent(0.16) }

    private static func paragraphStyle(for kind: CoFleetRichNoteBlock.Kind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 5
        switch kind {
        case .unorderedList, .orderedList, .checklist:
            style.firstLineHeadIndent = 4
            style.headIndent = 22
        case .quote:
            style.firstLineHeadIndent = 8
            style.headIndent = 18
        default: break
        }
        return style
    }

    private static func font(styles: CoFleetRichNoteStyle, block: CoFleetRichNoteBlock.Kind) -> NSFont {
        let size: CGFloat
        switch block {
        case let .heading(level): size = max(16, 26 - CGFloat(level * 2))
        default: size = NSFont.systemFontSize
        }
        if styles.contains(.inlineCode) || codeLanguage(block) != nil {
            return .monospacedSystemFont(ofSize: size, weight: styles.contains(.bold) ? .bold : .regular)
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if styles.contains(.bold) || isHeading(block) { traits.insert(.bold) }
        if styles.contains(.italic) { traits.insert(.italic) }
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }
    #elseif canImport(UIKit)
    private static var primaryTextColor: UIColor { .label }
    private static var linkColor: UIColor { .link }
    private static var codeBackgroundColor: UIColor { .tertiarySystemFill }

    private static func paragraphStyle(for kind: CoFleetRichNoteBlock.Kind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 5
        switch kind {
        case .unorderedList, .orderedList, .checklist:
            style.firstLineHeadIndent = 4
            style.headIndent = 22
        case .quote:
            style.firstLineHeadIndent = 8
            style.headIndent = 18
        default: break
        }
        return style
    }

    private static func font(styles: CoFleetRichNoteStyle, block: CoFleetRichNoteBlock.Kind) -> UIFont {
        let size: CGFloat
        switch block {
        case let .heading(level): size = max(16, 26 - CGFloat(level * 2))
        default: size = UIFont.preferredFont(forTextStyle: .body).pointSize
        }
        if styles.contains(.inlineCode) || codeLanguage(block) != nil {
            return .monospacedSystemFont(ofSize: size, weight: styles.contains(.bold) ? .bold : .regular)
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if styles.contains(.bold) || isHeading(block) { traits.insert(.traitBold) }
        if styles.contains(.italic) { traits.insert(.traitItalic) }
        let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits)
        return descriptor.map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }
    #endif

    private static func isHeading(_ kind: CoFleetRichNoteBlock.Kind) -> Bool {
        if case .heading = kind { return true }
        return false
    }
}

#if canImport(AppKit)
private struct CoFleetNativeRichTextEditor: NSViewRepresentable {
    @Binding var markdown: String
    var isReadOnly: Bool
    var invocation: CoFleetEditorInvocation?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textStorage?.setAttributedString(CoFleetAttributedNoteCodec.attributedString(markdown: markdown))
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
        let current = textView.textStorage.map(CoFleetAttributedNoteCodec.markdown(from:)) ?? ""
        if current != markdown, context.coordinator.lastEmittedMarkdown != markdown {
            context.coordinator.isApplying = true
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(CoFleetAttributedNoteCodec.attributedString(markdown: markdown))
            textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0))
            context.coordinator.isApplying = false
        }
        if let invocation, invocation.sequence != context.coordinator.lastInvocationSequence,
           let storage = textView.textStorage {
            context.coordinator.isApplying = true
            let selection = CoFleetAttributedNoteCodec.apply(invocation, to: storage, selection: textView.selectedRange())
            textView.setSelectedRange(selection)
            context.coordinator.lastInvocationSequence = invocation.sequence
            context.coordinator.isApplying = false
            context.coordinator.emitChange()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CoFleetNativeRichTextEditor
        weak var textView: NSTextView?
        var isApplying = false
        var lastInvocationSequence = 0
        var lastEmittedMarkdown: String?

        init(parent: CoFleetNativeRichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplying else { return }
            emitChange()
        }

        func emitChange() {
            guard let storage = textView?.textStorage else { return }
            let value = CoFleetAttributedNoteCodec.markdown(from: storage)
            lastEmittedMarkdown = value
            if parent.markdown != value { parent.markdown = value }
        }
    }
}
#elseif canImport(UIKit)
private struct CoFleetNativeRichTextEditor: UIViewRepresentable {
    @Binding var markdown: String
    var isReadOnly: Bool
    var invocation: CoFleetEditorInvocation?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.allowsEditingTextAttributes = true
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        textView.attributedText = CoFleetAttributedNoteCodec.attributedString(markdown: markdown)
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
        let current = CoFleetAttributedNoteCodec.markdown(from: textView.attributedText)
        if current != markdown, context.coordinator.lastEmittedMarkdown != markdown {
            context.coordinator.isApplying = true
            let selection = textView.selectedRange
            textView.attributedText = CoFleetAttributedNoteCodec.attributedString(markdown: markdown)
            textView.selectedRange = NSRange(location: min(selection.location, textView.text.utf16.count), length: 0)
            context.coordinator.isApplying = false
        }
        if let invocation, invocation.sequence != context.coordinator.lastInvocationSequence {
            context.coordinator.isApplying = true
            let storage = NSMutableAttributedString(attributedString: textView.attributedText)
            let selection = CoFleetAttributedNoteCodec.apply(invocation, to: storage, selection: textView.selectedRange)
            textView.attributedText = storage
            textView.selectedRange = selection
            context.coordinator.lastInvocationSequence = invocation.sequence
            context.coordinator.isApplying = false
            context.coordinator.emitChange()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CoFleetNativeRichTextEditor
        weak var textView: UITextView?
        var isApplying = false
        var lastInvocationSequence = 0
        var lastEmittedMarkdown: String?

        init(parent: CoFleetNativeRichTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying else { return }
            emitChange()
        }

        func emitChange() {
            guard let attributedText = textView?.attributedText else { return }
            let value = CoFleetAttributedNoteCodec.markdown(from: attributedText)
            lastEmittedMarkdown = value
            if parent.markdown != value { parent.markdown = value }
        }
    }
}
#endif
#endif
