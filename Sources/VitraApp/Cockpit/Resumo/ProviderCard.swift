import Foundation
import VitraOrchestrator

// MARK: - The providers

/// Where a provider stands, and why it cannot work when it cannot.
enum ProviderState: Equatable, Sendable {
    case ok
    case noQuota(until: Date)
    case down(until: Date)
    case signedOut
    case resting(until: Date)
    case notInstalled
}

/// One card of the Fornecedores section.
struct ProviderCard: Equatable, Sendable {
    let cli: WorkerCLI
    /// Where the CLI is installed; nil when it is not.
    let path: String?
    /// Whether it is signed in: nil when that cannot be told yet.
    let signedIn: Bool?
    /// What it offers as workers; nil until its listing came back.
    let models: [ModelCatalog.Offer]?
    /// For each model offered, the lineup tiers it is in.
    let tiers: [ModelCatalog.Offer: [Difficulty]]
    let deliveriesToday: Int
    let state: ProviderState
    let isOn: Bool

    /// The models in at least one tier of the lineup.
    var inLineup: Int { tiers.values.filter { !$0.isEmpty }.count }

    /// The command that would fix it: sign in, or install.
    var command: String? {
        switch state {
        case .signedOut: return ProviderBoard.login(cli)
        case .notInstalled: return ProviderBoard.install(cli).command
        default: return nil
        }
    }

    func statusText(calendar: Calendar) -> String {
        switch state {
        case .ok: return "ok"
        case let .noQuota(until): return "sem cota · volta ~\(Resumo.clock(until, calendar: calendar))"
        case let .down(until): return "fora do ar · volta ~\(Resumo.clock(until, calendar: calendar))"
        case .signedOut: return "deslogado — rode `\(ProviderBoard.login(cli))` no terminal"
        case let .resting(until): return "descansando até \(Resumo.clock(until, calendar: calendar)) após \(ProviderBoard.restingAfter) falhas"
        case .notInstalled: return "não instalado"
        }
    }

    /// The line under the status: where it lives and what it offers.
    var detailText: String? {
        guard let path else { return nil }
        var parts = [ProviderBoard.tildePath(path)]
        if let models {
            parts.append(models.count == 1 ? "1 modelo" : "\(models.count) modelos")
            parts.append("\(inLineup) na escalação")
        }
        parts.append(deliveriesToday == 1 ? "1 entrega hoje" : "\(deliveriesToday) entregas hoje")
        return parts.joined(separator: " · ")
    }
}

/// Works the provider cards out of what is installed, what each CLI listed,
/// the runs and the user's lineup and switches. Pure.
enum ProviderBoard {
    static let restingAfter = 3

    /// The command that signs `cli` in, typed in a terminal.
    static func login(_ cli: WorkerCLI) -> String {
        switch cli {
        case .claude: return "claude /login"
        case .opencode: return "opencode auth login"
        case .cursor: return "cursor-agent login"
        case .gemini: return "agy auth login"
        }
    }

    /// How to install `cli`: a hint in words and, when there is one, the command.
    static func install(_ cli: WorkerCLI) -> (hint: String, command: String?) {
        switch cli {
        case .claude: return ("Instale o Claude Code:", "curl -fsSL https://claude.ai/install.sh | bash")
        case .opencode: return ("Instale o opencode, ou o app OpenCode:", "curl -fsSL https://opencode.ai/install | bash")
        case .cursor: return ("Instale o Cursor CLI:", "curl https://cursor.com/install -fsS | bash")
        case .gemini: return ("Instale o Antigravity e abra-o uma vez: ele traz o `agy`.", nil)
        }
    }

    /// The card of `cli`.
    ///
    /// - Parameters:
    ///   - lines: what the CLI listed; nil when it has not been asked yet.
    ///   - availability: what its runs say, as the Resumo tab reads them.
    static func card(
        _ cli: WorkerCLI, path: String?, lines: [String]?, availability: Availability, deliveriesToday: Int,
        lineup: Lineup, isOn: Bool
    ) -> ProviderCard {
        let installed = path != nil
        // An installed CLI that listed nothing answered with an error: signed
        // out, as good as. Claude lists nothing and is told by its runs alone.
        let listedNothing = cli != .claude && lines?.isEmpty == true
        let signedIn: Bool? = !installed ? nil
            : (listedNothing || availability == .signedOut) ? false
            : (cli == .claude || lines != nil) ? true : nil
        // Nothing listed says nothing about what it would offer signed in.
        let models: [ModelCatalog.Offer]? = !installed ? [] : listedNothing ? nil : (cli == .claude || lines != nil)
            ? ModelCatalog.offers(listing(cli, lines: lines ?? [])) : nil
        let state: ProviderState
        switch (installed, signedIn, availability) {
        case (false, _, _): state = .notInstalled
        case (_, false?, _): state = .signedOut
        case let (_, _, .noQuota(until)): state = .noQuota(until: until)
        case let (_, _, .down(until)): state = .down(until: until)
        case let (_, _, .resting(until, _)): state = .resting(until: until)
        default: state = .ok
        }
        let tiers = Dictionary(uniqueKeysWithValues: (models ?? []).map { offer in
            (offer, LineupBoard.tiers.filter { lineup.tier($0).contains(offer) })
        })
        return ProviderCard(
            cli: cli, path: path, signedIn: signedIn, models: models, tiers: tiers,
            deliveriesToday: installed ? deliveriesToday : 0, state: state, isOn: isOn
        )
    }

    /// The few words a collapsed row says: the Resumo's word on its runs,
    /// unless the card knows it is not installed or signed out; "desligado"
    /// alone when the user switched it off.
    static func rowStatus(_ availability: Availability, card: ProviderCard?, calendar: Calendar) -> String {
        let base: String = switch card?.state {
        case .notInstalled?: "não instalado"
        case .signedOut?: "deslogado"
        default: Resumo.availabilityText(availability, calendar: calendar)
        }
        // Switched off says the most: why it is not picked is the user's own word.
        return card?.isOn == false ? "desligado" : base
    }

    /// A listing in which only `cli` answered.
    private static func listing(_ cli: WorkerCLI, lines: [String]) -> ModelCatalog.Listing {
        ModelCatalog.Listing(
            claude: cli == .claude, openCode: cli == .opencode ? lines : nil,
            gemini: cli == .gemini ? lines : nil, cursor: cli == .cursor ? lines : nil
        )
    }

    /// `/Users/me/.local/bin/x` as `~/.local/bin/x`.
    static func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The model as a card lists it, without opencode's provider prefix.
    static func modelName(_ offer: ModelCatalog.Offer) -> String {
        WorkerPicker.shortName(offer)
    }
}
