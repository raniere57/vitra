import Foundation
import VitraOrchestrator

/// The Resumo tab's data: a week of one project's work and a little of
/// another's, with an audit that asked for fixes and a redo after it, a
/// failover after a quota, a delivery still running, a failure, a discarded
/// draft, and a cursor worker resting after three failures in a row.
extension SnapshotFixtures {
    /// The trabalho the expanded snapshot opens.
    static let resumoExpanded = "r01"

    func resumoRuns() -> [Run] {
        let m = 60.0
        let h = 3_600.0
        let d = 86_400.0
        let opus = (WorkerCLI.claude, "opus", "low")
        let sonnet = (WorkerCLI.claude, "sonnet", "high")
        let grok = "cursor-grok-4.6-low-fast"
        let lineup = PickReason(code: .lineup, text: "1st in your lineup for hard pieces", position: 1)
        let cache = "Cache do ranking por projeto"
        let files = "Migrar a lista de arquivos para células"

        var runs: [Run] = [
            // Running now.
            run("r10", "sonnet", .claude, effort: "medium", label: "Ajustar o cabeçalho do maestro", kind: .implement,
                access: .edit, state: .running, ago: 4 * m, pick: PickReason(code: .lineup, text: "1st in your lineup for normal pieces", position: 1)),
            // Audited, fixes asked, redone and delivered.
            run("r01", opus.1, opus.0, effort: opus.2, label: cache, kind: .implement, access: .edit, ago: 3 * h, took: 6 * m + 12,
                cost: 0.42, tokens: (88_000, 6_400), score: 3, note: "Faltou invalidar o cache quando uma nota é corrigida.",
                difficulty: .hard, pick: lineup),
            run("r02", grok, .cursor, label: "auditoria: " + cache, kind: .review, ago: 3 * h - 7 * m, took: 72, cost: 0.03,
                tokens: (24_000, 1_200), score: 5,
                answer: "ship after fixes\n- RankingCache.swift:42 — a nota corrigida não invalida a entrada.",
                pick: PickReason(code: .lineup, text: "1st in your lineup for easy pieces", position: 1)),
            run("r03", sonnet.1, sonnet.0, effort: sonnet.2, label: cache, kind: .implement, access: .edit, ago: 2 * h + 40 * m,
                took: 8 * m + 3, cost: 0.61, tokens: (120_000, 9_000), score: 5, note: "Invalidação coberta por teste.",
                difficulty: .hard, pick: PickReason(code: .lineup, text: "2nd in your lineup: opus (low) is excluded from this redo", position: 2),
                redoOf: "r01"),
            run("r04", grok, .cursor, label: "auditoria: " + cache, kind: .review, ago: 2 * h + 30 * m, took: 65, cost: 0.03,
                tokens: (22_000, 900), score: 5, answer: "ship\nNada a corrigir."),
            // A quota, a failover, an audit that let it through.
            run("r05", "opencode/glm-5.3-flash-free", .opencode, label: files, kind: .implement, access: .edit,
                state: .finished(exitCode: 1), ago: 40 * m, took: 4, isError: true, answer: "Error: free usage limit reached",
                pick: PickReason(code: .lineup, text: "1st in your lineup for normal pieces", position: 1),
                providerFailure: .quota("Error: free usage limit reached")),
            run("r06", "haiku", .claude, effort: "low", label: files, kind: .implement, access: .edit, ago: 39 * m, took: 3 * m + 20,
                cost: 0.08, tokens: (40_000, 3_000), score: 4, note: "Funciona; a rolagem ainda pisca.", retryOf: "r05"),
            run("r07", grok, .cursor, label: "auditoria: " + files, kind: .review, ago: 35 * m, took: 58, cost: 0.02,
                tokens: (18_000, 700), score: 4, answer: "ship\nSem regressões."),
            // Yesterday: a failure and a discarded draft.
            run("r08", sonnet.1, sonnet.0, effort: sonnet.2, label: "Corrigir o build do CGhosttyVT", kind: .implement, access: .edit,
                state: .finished(exitCode: 1), ago: 1 * d + 2 * h, took: 2 * m + 5, cost: 0.12, tokens: (30_000, 900), isError: true,
                answer: "error: 'ghostty/vt.h' file not found", difficulty: .hard),
            run("r09", "gemini-3-flash", .gemini, label: "Rascunho do guia de cores", kind: .docs, ago: 1 * d + 5 * h, took: 4 * m,
                cost: 0, tokens: (52_000, 7_000), score: 2, note: "Genérico; não usa os papéis do tema."),
        ]

        // The rest of the week, for the sparkline and the facts: hard pieces
        // for opus and sonnet, each audited, and reviews by two workers.
        let titles = ["Cobrir o RunFeed com testes", "Explorar o fluxo de merge", "Documentar o ranking", "Revisar a barra de abas",
                      "Atualizar o tema para papéis", "Ler os logs do deploy", "Mapear o fluxo de auditoria"]
        let week: [(day: Double, opusOK: [Bool], sonnetOK: [Bool], cost: Double)] = [
            (1, [true], [true], 0.30), (2, [true, true], [false], 0.55), (3, [true, false, true], [true, true], 1.60),
            (5, [true], [false, true], 0.40), (6, [true], [false], 0.25),
        ]
        for (dayIndex, day) in week.enumerated() {
            let attempts = day.opusOK.map { (opus, $0) } + day.sonnetOK.map { (sonnet, $0) }
            for (index, (worker, ok)) in attempts.enumerated() {
                let id = "w\(dayIndex)\(index)"
                let title = titles[(dayIndex + index) % titles.count] + " \(dayIndex + 1)"
                let ago = day.day * d + Double(index) * h + 3 * h
                runs.append(run(
                    id, worker.1, worker.0, effort: worker.2, label: title, kind: .implement, access: .edit,
                    state: .finished(exitCode: ok ? 0 : 1), ago: ago, took: 5 * m + Double(index) * 40,
                    cost: day.cost / Double(attempts.count), tokens: (50_000, 4_000), score: ok ? 5 : nil, isError: !ok,
                    answer: ok ? "pronto" : "error: os testes não passaram", difficulty: .hard, pick: lineup
                ))
                guard ok else { continue }
                runs.append(run(
                    "a\(dayIndex)\(index)", index % 2 == 0 ? grok : "haiku", index % 2 == 0 ? .cursor : .claude,
                    effort: index % 2 == 0 ? nil : "low", label: "auditoria: " + title, kind: .review,
                    ago: ago - 6 * m, took: index % 2 == 0 ? 70 + Double(index) * 3 : 150 + Double(index) * 5,
                    cost: index % 2 == 0 ? 0.02 : 0.03, tokens: (20_000, 800), score: 5,
                    answer: index == 1 ? "ship after fixes\n- falta um teste" : "ship"
                ))
            }
        }

        // Another project: in the all-projects line, and a cursor worker that
        // failed three times in twenty minutes, so the picker rests it.
        let other = "/private/tmp/hapto"
        for (index, ago) in [22.0, 15, 9].enumerated() {
            runs.append(run(
                "h\(index)", "grok-4.7-low-fast", .cursor, label: "Revisar o checkout", kind: .review,
                state: .finished(exitCode: 1), ago: ago * m, took: 90, cost: 0.02, tokens: (15_000, 300), isError: true,
                answer: "error: tool call refused", project: other
            ))
        }
        runs.append(run("h9", "sonnet", .claude, effort: "high", label: "Migrar o banco do hapto", kind: .implement,
                        ago: 5 * h, took: 12 * m, cost: 0.88, tokens: (140_000, 11_000), score: 4, project: other))
        return runs.sorted { $0.started > $1.started }
    }

    func resumo() -> Resumo {
        Resumo.make(runs: resumoRuns(), project: CockpitProject(path: path), usage: subscription, now: now)
    }
}
