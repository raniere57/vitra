import AppKit
import CoreText
import Foundation

/// Cell geometry derived from a monospaced font.
///
/// The grid is built from these numbers, so they are rounded to whole pixels
/// once here rather than at every draw: fractional cell advances accumulate
/// across a wide row and leave the last column visibly out of alignment.
public struct FontMetrics: Equatable, Sendable {
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    /// Distance from the top of the cell down to the text baseline.
    public let baseline: CGFloat
    public let underlinePosition: CGFloat
    public let underlineThickness: CGFloat

    public init(font: CTFont, lineHeightMultiple: CGFloat = 1.0) {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        // Advance of a representative glyph rather than the font's bounding box:
        // in a monospaced face every glyph shares this advance, and the bounding
        // box is wider than the cell for faces with overhanging glyphs.
        var glyph = CGGlyph()
        var character = UniChar(UnicodeScalar("M").value)
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        }

        cellWidth = max(1, advance.width.rounded(.up))
        cellHeight = max(1, ((ascent + descent + leading) * lineHeightMultiple).rounded(.up))
        baseline = (cellHeight - (ascent + descent + leading) * lineHeightMultiple).rounded() + ascent.rounded()
        underlineThickness = max(1, CTFontGetUnderlineThickness(font).rounded())
        // Core Text reports this as a negative offset from the baseline.
        underlinePosition = baseline - CTFontGetUnderlinePosition(font).rounded()
    }
}

/// A monospaced font in its four rendering variants.
///
/// `CTFont` is immutable and thread-safe; Swift just cannot see that through the
/// Core Foundation bridge.
public struct FontSet: @unchecked Sendable {
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont
    public let metrics: FontMetrics

    /// Loads `name` at `size`, falling back to the system monospaced face.
    ///
    /// A missing font is a configuration mistake, not a reason to fail to start,
    /// so this always produces a usable set.
    public init(name: String, size: CGFloat) {
        let base = FontSet.font(named: name, size: size)
            ?? CTFontCreateWithFontDescriptor(
                CTFontDescriptorCreateWithAttributes([
                    kCTFontFamilyNameAttribute: "Menlo" as CFString,
                ] as CFDictionary),
                size,
                nil
            )

        regular = base
        bold = FontSet.variant(of: base, traits: .traitBold)
        italic = FontSet.variant(of: base, traits: .traitItalic)
        boldItalic = FontSet.variant(of: base, traits: [.traitBold, .traitItalic])
        metrics = FontMetrics(font: base)
    }

    public func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    private static func font(named name: String, size: CGFloat) -> CTFont? {
        // SF Mono ships with macOS but carries no public family name: it is the
        // monospaced face of the system font, and this is the only way to ask
        // for it. Naming it in a config file should still work.
        if name.caseInsensitiveCompare("SF Mono") == .orderedSame {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        }

        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: name as CFString,
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        // CTFont always returns something; check that it is the face we asked for.
        let resolved = CTFontCopyFamilyName(font) as String
        return resolved.caseInsensitiveCompare(name) == .orderedSame ? font : nil
    }

    private static func variant(of font: CTFont, traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
    }
}
