import AppKit

/// Which of the maestro header's plates are shown at a given width. Pure:
/// widths in, choices out, so the give-way order is testable without a view.
///
/// The header must never be wider than its pane, or it pushes the side panel
/// off the window. What gives way, first to last: the session name, the usage
/// figure (the tab bar's chip says it too), the path, the long label of the
/// mode switch, the words of the Terminal · Leitura switch (its two icons
/// stay), the branch, and last the words of the update pill — its button
/// stays. Title, both switches, model and "waiting for you" never go.
struct HeaderFit: Equatable {
    /// Each plate's natural width; nil for one that has nothing to show.
    struct Widths {
        var title: CGFloat
        var modeFull: CGFloat
        var modeShort: CGFloat
        /// The Terminal · Leitura switch with its words, and as two icons.
        var readingFull: CGFloat = 0
        var readingCompact: CGFloat = 0
        var model: CGFloat
        var attention: CGFloat?
        /// The update pill with its words, and with its button alone.
        var update: CGFloat?
        var updateCompact: CGFloat?
        var usage: CGFloat?
        var hasSession: Bool
        var branch: CGFloat?
    }

    var abbreviatesMode = false
    var compactsReading = false
    var compactsUpdate = false
    var showsUsage = true
    var showsSession = true
    var showsPlace = true
    var showsBranch = true
    var showsTitle = true

    static let sessionMinWidth: CGFloat = 96
    static let placeMinWidth: CGFloat = 56
    static let inset = CockpitStyle.inset
    static let gap = CockpitStyle.Space.md
    /// The wider gap after the title.
    static let titleGap = CockpitStyle.Space.lg

    /// The choices for `width`; everything that has something to show when
    /// the width is not known yet (zero), before the first layout.
    static func fit(width: CGFloat, _ widths: Widths) -> HeaderFit {
        var fit = HeaderFit()
        fit.showsUsage = widths.usage != nil
        fit.showsSession = widths.hasSession
        fit.showsBranch = widths.branch != nil
        guard width > 0 else { return fit }
        let steps: [(inout HeaderFit) -> Void] = [
            { $0.showsSession = false },
            { $0.showsUsage = false },
            { $0.showsPlace = false },
            { $0.abbreviatesMode = true },
            { $0.compactsReading = true },
            { $0.showsBranch = false },
            { $0.compactsUpdate = true },
            { $0.showsTitle = false },
        ]
        for step in steps where fit.needs(widths) > width {
            step(&fit)
        }
        // The last step may have freed more than it had to: the branch comes
        // back if it now fits, then the path.
        if fit.compactsUpdate, widths.branch != nil, !fit.showsBranch {
            var withBranch = fit
            withBranch.showsBranch = true
            if withBranch.needs(widths) <= width { fit = withBranch }
        }
        if !fit.showsPlace {
            var withPlace = fit
            withPlace.showsPlace = true
            if withPlace.needs(widths) <= width { fit = withPlace }
        }
        return fit
    }

    /// The width these choices take: the plates, the gaps between those
    /// shown, the spacer, and the path and session at their minimum.
    func needs(_ widths: Widths) -> CGFloat {
        // A header with no title (zero) has neither its plate nor its gap.
        let hasTitle = showsTitle && widths.title > 0
        var plates: [CGFloat] = hasTitle ? [widths.title] : []
        plates.append(abbreviatesMode ? widths.modeShort : widths.modeFull)
        if widths.readingFull > 0 { plates.append(compactsReading ? widths.readingCompact : widths.readingFull) }
        plates.append(widths.model)
        if let attention = widths.attention { plates.append(attention) }
        if let update = compactsUpdate ? widths.updateCompact : widths.update { plates.append(update) }
        if showsUsage, let usage = widths.usage { plates.append(usage) }
        if showsSession, widths.hasSession { plates.append(Self.sessionMinWidth) }
        plates.append(0) // the spacer
        if showsPlace { plates.append(Self.placeMinWidth) }
        if showsBranch, let branch = widths.branch { plates.append(branch) }
        let gaps = CGFloat(plates.count - 1) * Self.gap + (hasTitle ? Self.titleGap - Self.gap : 0)
        return 2 * Self.inset + plates.reduce(0, +) + gaps
    }
}
