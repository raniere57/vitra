import AppKit

/// A made-up conversation for Leitura's pictures: the user asks for a fix to
/// a report, the maestro reads and edits, answers with a table, a code block
/// and a list, delegates to two workers, one call fails, the conversation is
/// compacted and the maestro is at work again. Every word is invented.
enum SnapshotLeitura {
    static func call(
        _ id: String, _ name: String, _ summary: String, icon: String, at start: TimeInterval, took: TimeInterval?,
        now: Date, file: String? = nil, worker: String? = nil, added: Int? = nil, removed: Int? = nil,
        input: String = "", output: String = "", error: String? = nil
    ) -> Activity.Step {
        let started = now.addingTimeInterval(start)
        var call = ToolCall(id: id, name: name, summary: summary, icon: icon, input: input, filePath: file, workerID: worker,
                            added: added, removed: removed, started: started)
        if let took {
            call.finished = started.addingTimeInterval(took)
            call.output = output
            call.status = error.map { .error($0) } ?? .ok
        }
        return .call(call)
    }

    /// The conversation, its times counted back from `now`.
    static func items(now: Date, project: URL, image: String?) -> [TranscriptItem] {
        let t = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }
        let root = project.path
        let first: [TranscriptItem] = [
            .user(UserMessage(id: "u1", time: t(52), text: "Olha esse relatório: as colunas de custo estão desalinhadas e o total some quando filtro por fornecedor. Dá pra corrigir?",
                              images: image.map { [ImageRef(path: $0)] } ?? [])),
            .activity(Activity(id: "a1", steps: [
                .thought,
                call("c1", "Read", "RankingFigures.swift", icon: "doc.text", at: -51.8 * 60, took: 1, now: now, file: root + "/Sources/RankingFigures.swift"),
                call("c2", "Grep", "buscou “totalCost” em Sources", icon: "magnifyingglass", at: -51.7 * 60, took: 1, now: now),
                call("c3", "Read", "RankingRows.swift · linhas 120–180", icon: "doc.text", at: -51.6 * 60, took: 1, now: now, file: root + "/Sources/RankingRows.swift"),
                call("c4", "Edit", "RankingFigures.swift", icon: "pencil", at: -50.5 * 60, took: 2, now: now, file: root + "/Sources/RankingFigures.swift", added: 18, removed: 6),
                call("c5", "Edit", "RankingRows.swift", icon: "pencil", at: -50 * 60, took: 2, now: now, file: root + "/Sources/RankingRows.swift", added: 4, removed: 2),
                call("c6", "Bash", "Rodar os testes do relatório", icon: "terminal", at: -49.9 * 60, took: 180, now: now),
            ])),
            .answer(Answer(id: "r1", time: t(47.5), markdown: answerOne)),
            .worked(Worked(id: "w1", time: t(47.4), seconds: 271)),
            .divider(ReadingDivider(id: "p1", time: t(28), kind: .time)),
            .user(UserMessage(id: "u2", time: t(28), text: "Perfeito. Agora delega a exportação em CSV pra dois operários e fica com a melhor.")),
            .activity(Activity(id: "a2", steps: [
                call("d1", "mcp__vitra__agent_spawn", "delegou: Exportar o relatório em CSV (implement)", icon: "arrow.triangle.branch", at: -27.8 * 60, took: 2, now: now, worker: "4f9f6b9d"),
                call("d2", "mcp__vitra__agent_spawn", "delegou: CSV com cabeçalho localizado (implement)", icon: "arrow.triangle.branch", at: -27.7 * 60, took: 2, now: now, worker: "b2179ee2"),
                call("d3", "mcp__vitra__agent_wait", "aguardou 2 operários", icon: "hourglass", at: -27.6 * 60, took: 9 * 60, now: now),
                call("d4", "Bash", "Compilar a entrega do 4f9f6b9d", icon: "terminal", at: -18.4 * 60, took: 41, now: now,
                     input: "swift build --package-path ../.vitra-wt/4f9f6b9d",
                     output: "Building for debugging...\nCSVExport.swift:42:17: error: cannot find 'RankingRow' in scope\n        let rows: [RankingRow] = slice.rows\n                   ^~~~~~~~~~\nerror: fatalError",
                     error: "CSVExport.swift:42:17: error: cannot find 'RankingRow' in scope"),
                call("d5", "mcp__vitra__agent_merge", "integrou b2179ee2", icon: "arrow.triangle.merge", at: -17.6 * 60, took: 6, now: now, worker: "b2179ee2"),
                call("d6", "mcp__vitra__agent_rate", "nota 5/5 a b2179ee2", icon: "star", at: -17.4 * 60, took: 1, now: now, worker: "b2179ee2"),
                call("d7", "mcp__vitra__agent_rate", "nota 2/5 a 4f9f6b9d", icon: "star", at: -17.3 * 60, took: 1, now: now, worker: "4f9f6b9d"),
            ])),
            .answer(Answer(id: "r2", time: t(17), markdown: answerTwo)),
            .worked(Worked(id: "w2", time: t(17), seconds: 11 * 60 + 2)),
            .note(Note(id: "n1", time: t(9), kind: .command, text: "/rename relatório-csv", output: "Session renamed to: relatório-csv")),
            .divider(ReadingDivider(id: "k1", time: t(8), kind: .compacted)),
            .user(UserMessage(id: "u3", time: t(1.3), text: "Roda a suíte inteira e me diz o que quebrou.")),
            .activity(Activity(id: "a3", steps: [
                call("e1", "Bash", "Rodar a suíte inteira", icon: "terminal", at: -70, took: nil, now: now),
            ])),
        ]
        return first
    }

    static let answerOne = """
    Achei as duas coisas. O total sumia porque `RankingSlice` filtrava as runs **antes** de somar o custo, e o desalinhamento vinha de as colunas numéricas usarem a fonte proporcional.

    ## O que mudou

    - O total agora é somado sobre as runs **visíveis**, depois do filtro
    - As colunas de custo e tempo usam algarismos tabulares e ficam alinhadas à direita
      - inclusive no cabeçalho, para a régua bater
    - Nenhuma mudança no formato salvo em disco

    | Fornecedor | Runs | Custo | Tempo médio |
    |---|---:|---:|---:|
    | claude | 41 | R$ 18,40 | 3m 12s |
    | opencode | 27 | R$ 0,00 | 5m 40s |
    | cursor | 9 | R$ 2,10 | 2m 05s |

    O cálculo ficou assim:

    ```swift
    let visible = runs.filter(options.matches)
    let total = visible.reduce(0) { $0 + ($1.cost ?? 0) }
    ```

    Os 23 testes do relatório passam. Quer que eu exporte em CSV também?
    """

    static let answerTwo = """
    Fiquei com a entrega do **b2179ee2**: o cabeçalho sai em português e os valores usam vírgula decimal, como no relatório. A do 4f9f6b9d nem compilava — referenciava um tipo que não existe mais.

    1. `Exportar CSV…` no menu do Ranking grava o recorte que está na tela
    2. O arquivo abre direto no Numbers e no Excel
    """

    /// A wide table and a long code block, for the table picture.
    static func tableItems(now: Date) -> [TranscriptItem] {
        [
            .user(UserMessage(id: "tu", time: now.addingTimeInterval(-600), text: "Compara os três operários da última rodada numa tabela, com o motivo de cada nota.")),
            .answer(Answer(id: "ta", time: now.addingTimeInterval(-560), markdown: tableAnswer)),
            .worked(Worked(id: "tw", time: now.addingTimeInterval(-559), seconds: 41)),
        ]
    }

    static let tableAnswer = """
    Aqui está a comparação. Os tempos contam da delegação até a entrega; o custo é o que o fornecedor cobrou.

    | Operário | Modelo | Nota | Tempo | Custo | Por quê |
    |---|---|---:|---:|---:|---|
    | b2179ee2 | claude-sonnet | 5 | 4m 31s | R$ 1,20 | Fez o que foi pedido, com testes, e manteve o estilo do arquivo |
    | 4f9f6b9d | deepseek-v4.1-flash | 2 | 9m 02s | R$ 0,00 | Não compilou: referenciou `RankingRow`, que foi renomeado na semana passada |
    | 09c1ff2b | gemini-3-pro | 4 | 6m 48s | R$ 0,35 | Correto, mas duplicou a lógica de filtro em vez de reusar `RankingSlice` |

    O trecho que decidiu a nota do 09c1ff2b:

    ```swift
    // Duplicado de RankingSlice.matches(_:) — deveria chamar o original em vez de reescrever o filtro inteiro aqui dentro
    let visible = runs.filter { run in options.provider.map { run.spec.provider == $0 } ?? true && options.period.contains(run.started) }
    ```

    > Sugestão: dar ao 4f9f6b9d tarefas de leitura até o modelo melhorar.
    """

    /// A small picture standing for a pasted screenshot.
    static func writeScreenshot(into directory: URL) -> String? {
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
            rect.fill()
            NSColor(srgbRed: 0.16, green: 0.18, blue: 0.21, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 34).fill()
            for row in 0 ..< 7 {
                let y = 52 + CGFloat(row) * 34
                NSColor(srgbRed: 0.79, green: 0.80, blue: 0.83, alpha: 0.55).setFill()
                NSRect(x: 20, y: y, width: 120, height: 9).fill()
                NSColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 0.8).setFill()
                NSRect(x: 220 + CGFloat(row % 3) * 9, y: y, width: 70, height: 9).fill()
                NSColor(srgbRed: 0.44, green: 0.81, blue: 0.59, alpha: 0.7).setFill()
                NSRect(x: 360, y: y, width: CGFloat(30 + row * 11), height: 9).fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent("relatorio.png")
        return (try? png.write(to: url)) != nil ? url.path : nil
    }
}
