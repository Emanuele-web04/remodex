// FILE: TurnComposerInlineSkillToken.swift
// Purpose: Bridges canonical skill-token text to atomic attributed runs in the composer.
// Layer: View Support
// Exports: TurnComposerInlineSkillToken
// Depends on: Foundation, UIKit, RemodexIcon, SkillDisplayNameFormatter

import Foundation
import UIKit

nonisolated enum TurnComposerInlineSkillToken {
    static let attributeKey = NSAttributedString.Key("remodex.inlineSkillToken")
    private static let objectReplacementCharacter = "\u{FFFC}"
    private static let tokenSeparator = "\u{00A0}"

    static func displayAttributedString(
        canonicalText: String,
        mentionNames: [String],
        font: UIFont,
        textColor: UIColor,
        tintColor: UIColor
    ) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let result = NSMutableAttributedString(string: canonicalText, attributes: baseAttributes)
        let names = Array(Set(mentionNames.compactMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted { $0.count > $1.count }
        guard !names.isEmpty else { return result }

        let alternatives = names.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "(?<!\\S)([$/])(" + alternatives + ")(?=[\\s,.;:!?)\\]}>]|$)",
            options: [.caseInsensitive]
        ) else {
            return result
        }

        let source = canonicalText as NSString
        let matches = regex.matches(
            in: canonicalText,
            range: NSRange(location: 0, length: source.length)
        )
        for match in matches.reversed() {
            let canonicalToken = source.substring(with: match.range)
            let rawName = source.substring(with: match.range(at: 2))
            let displayName = SkillDisplayNameFormatter.displayName(for: rawName)
            let token = NSMutableAttributedString()
            if let icon = tokenIcon(tintColor: tintColor) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                let side = tokenIconSide
                attachment.bounds = CGRect(
                    x: 0,
                    y: (font.ascender + font.descender - side) / 2,
                    width: side,
                    height: side
                )
                token.append(NSAttributedString(attachment: attachment))
                token.append(NSAttributedString(string: tokenSeparator))
            }
            token.append(NSAttributedString(string: displayName))
            token.addAttributes(
                [
                    attributeKey: canonicalToken,
                    .font: font,
                    .foregroundColor: tintColor,
                ],
                range: NSRange(location: 0, length: token.length)
            )
            result.replaceCharacters(in: match.range, with: token)
        }
        return result
    }

    static func canonicalText(from attributedText: NSAttributedString) -> String {
        var result = ""
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(attributeKey, in: fullRange) { value, range, _ in
            if let token = value as? String {
                result += token
            } else {
                result += attributedText.attributedSubstring(from: range).string
                    .replacingOccurrences(of: objectReplacementCharacter, with: "")
            }
        }
        return result
    }

    static func expandedEditingRange(for range: NSRange, in attributedText: NSAttributedString) -> NSRange {
        guard range.length > 0 else { return range }
        var expanded = range
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(attributeKey, in: fullRange) { value, tokenRange, _ in
            guard value != nil, NSIntersectionRange(expanded, tokenRange).length > 0 else { return }
            expanded = NSUnionRange(expanded, tokenRange)
        }
        return expanded
    }

    static func snappedSelection(_ range: NSRange, in attributedText: NSAttributedString) -> NSRange {
        let fullRange = NSRange(location: 0, length: attributedText.length)
        if range.length == 0 {
            var location = range.location
            attributedText.enumerateAttribute(attributeKey, in: fullRange) { value, tokenRange, stop in
                guard value != nil,
                      location > tokenRange.location,
                      location < NSMaxRange(tokenRange) else { return }
                let distanceToStart = location - tokenRange.location
                let distanceToEnd = NSMaxRange(tokenRange) - location
                location = distanceToStart < distanceToEnd ? tokenRange.location : NSMaxRange(tokenRange)
                stop.pointee = true
            }
            return NSRange(location: location, length: 0)
        }
        return expandedEditingRange(for: range, in: attributedText)
    }

    @discardableResult
    static func normalizeTokenAttributes(in storage: NSMutableAttributedString) -> Bool {
        var rangesToStrip: [NSRange] = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(attributeKey, in: fullRange) { value, range, _ in
            guard let canonicalToken = value as? String else { return }
            let name = String(canonicalToken.dropFirst())
            let displayName = SkillDisplayNameFormatter.displayName(for: name)
            let expectedWithIcon = objectReplacementCharacter + tokenSeparator + displayName
            let displayed = storage.attributedSubstring(from: range).string
            let validPrefix: String
            if displayed.hasPrefix(expectedWithIcon) {
                validPrefix = expectedWithIcon
            } else if displayed.hasPrefix(displayName) {
                validPrefix = displayName
            } else {
                rangesToStrip.append(range)
                return
            }
            let validLength = (validPrefix as NSString).length
            if range.length > validLength {
                rangesToStrip.append(NSRange(
                    location: range.location + validLength,
                    length: range.length - validLength
                ))
            }
        }
        for range in rangesToStrip {
            storage.removeAttribute(attributeKey, range: range)
        }
        return !rangesToStrip.isEmpty
    }

    private static func tokenIcon(tintColor: UIColor) -> UIImage? {
        guard let base = RemodexIcon.uiImage(systemName: "remodex.skill") else { return nil }
        let side = tokenIconSide
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            base.withTintColor(tintColor, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    // Matches the user-bubble token's 17pt `.body`-relative metric without
    // tying icon size to a percentage of the current font's cap height.
    private static var tokenIconSide: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 17)
    }
}
