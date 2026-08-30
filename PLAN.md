# Vitra — Plano de construção

> Status: **aguardando aprovação**. Nenhuma linha de código escrita ainda.

## 0. Ambiente verificado (medido, não estimado)

| Item | Valor |
|---|---|
| Máquina | MacBook Air M1, 8 GB (`hw.memsize` = 8589934592) |
| macOS | 26.5.2 (25F84), arm64 |
| Xcode / Swift | 26.4 (17E192) / Swift 6.3, SDK macOS 26.4 |
| cmake | 4.4.0 ✅ |
| ninja | **ausente** ❌ → `brew install ninja` |
| zig | **ausente** ❌ → `brew install zig` (stable 0.16.0) |

`build.zig.zon` do commit alvo exige `minimum_zig_version = "0.16.0"`. O brew entrega exatamente 0.16.0. Sem conflito.

## 1. O que a investigação do libghostty-vt já confirmou

- A lib é produzida por `zig build -Demit-lib-vt` no repo do Ghostty; o `CMakeLists.txt` de lá é só um wrapper que delega ao Zig.
- **Existe alvo estático** (`ghostty-vt-static`), além do shared. Vamos linkar estático: sem `.dylib` dentro do `.app`, sem `@rpath`, binário único de verdade.
- Superfície da API C (`include/ghostty/vt.h` + `include/ghostty/vt/*.h`) cobre o que o projeto precisa:
  `terminal.h`, `render.h` (estado de render **incremental** — é exatamente o gancho para o dirty-tracking do Metal), `screen.h`, `selection.h`, `key.h` (Kitty keyboard), `mouse.h`, `osc.h`, `kitty_graphics.h`, `snapshot.h`, `unicode.h`, `allocator.h` (allocator customizado → dá para instrumentar a memória do core separadamente).
- O próprio header avisa: *"API is not yet stable. Breaking changes are expected."* Confirma sua instrução: **pinar commit**.

**Commit proposto para pin:** `f64f4aca2c29b554d111b36c3d946a9bddd159ff` (2026-08-09, `lib-vt: answer XTGETTCAP queries`).
Motivo: é o commit que o `ghostling` pina hoje — ou seja, é a combinação exata de API C que existe uma integração de referência funcionando. Vai para `docs/DEPENDENCIES.md`.

**Lacunas conhecidas do upstream** (do README do ghostling): OSC clipboard ainda não exposto pelo libghostty-vt. Impacto: `OSC 52` (copiar via terminal) não funciona na Fase 1. Não bloqueia nada do que você pediu; fica registrado como pendência do upstream.

## 2. Estrutura de repositório

```
vitra/
├── Package.swift                 # SPM, 6 targets
├── PLAN.md
├── docs/
│   ├── DEPENDENCIES.md           # hash pinado + como reproduzir o vendor
│   ├── MEASUREMENTS.md           # tabela viva de RAM/CPU por fase
│   └── ARCHITECTURE.md
├── scripts/
│   ├── vendor-ghostty-vt.sh      # clona no hash, zig build, instala em vendor/
│   ├── measure.sh                # footprint/ps/top → linha em MEASUREMENTS.md
│   ├── make-icon.sh              # Core Graphics → iconset → icns
│   └── release.sh                # Release + codesign -s - + .dmg
├── vendor/ghostty-vt/            # gitignored: lib/libghostty-vt.a + include/
├── Sources/
│   ├── CGhosttyVT/               # target C: module.modulemap + shim.h
│   ├── VitraCore/                # protocolo TerminalCore, PTY, sessão
│   ├── VitraGhostty/             # TerminalCore sobre libghostty-vt
│   ├── VitraRender/              # Metal, atlas de glifos, layout de células
│   ├── VitraPanel/               # preview: imagem, PDF, HTML, browser
│   ├── VitraBridge/              # MCP + OSC 7337 + CLI + socket
│   └── VitraApp/                 # AppKit: janelas, abas, splits, prefs
└── Tests/
    ├── VitraCoreTests/           # PTY, resolução de caminhos de anexo
    ├── VitraGhosttyTests/        # parsing/estado do terminal
    └── VitraBridgeTests/         # serialização das ferramentas MCP
```

Fronteiras, como você definiu: `VitraRender` importa só `VitraCore` (nunca `VitraGhostty`). `VitraPanel` não importa terminal nenhum — recebe eventos por um `PreviewRequest` enum.

## 3. Ponto de arquitetura que preciso confirmar com você (regra 6)

Você escreveu: *"MCP server embutido no próprio binário (stdio), não processo separado"*.

Na prática isso não fecha sozinho. O `claude mcp add vitra -- vitra mcp` faz o **Claude Code** dar spawn em `vitra mcp` como filho dele, com stdin/stdout dedicados. Esse processo não é a sua janela do Vitra — é outro processo, e é ele que precisa mandar o `browser_click` para a `WKWebView` que está viva no processo da GUI.

O que eu proponho (mesmo binário, mesma ideia, só explicitando o transporte):

```
Claude Code ──stdio──> `vitra mcp` (mesmo binário, modo headless, ~5 MB)
                            │
                            └──unix socket──> ~/.vitra/vitra.sock ──> processo GUI do Vitra
```

`vitra mcp` fica sendo uma casca fina: fala JSON-RPC 2.0 no stdio, traduz para o mesmo protocolo de socket que a CLI `vitra open` já usa, e devolve. Zero processo extra rodando de fundo — ele vive e morre junto com a sessão do Claude Code. Se a GUI não estiver aberta, as ferramentas retornam erro MCP claro ("Vitra não está rodando") em vez de travar.

Alternativa que **não** recomendo: a GUI abrir stdio própria. Não dá — o Claude Code é quem faz o spawn.

Se você preferir outro desenho, me diga antes da Fase 4.

## 4. Fases

Regra em todas: no fim, `main` compila, o app roda, e sai um relatório de 3 linhas (o que funciona / RSS medido em repouso e sob carga / o que ficou pendente).

---

### Fase 0 — Fundação e spike do núcleo (~1 sessão)

Antes de investir no Metal, provar que o libghostty-vt sobe nesta máquina.

1. `git init`, `Package.swift`, esqueleto dos 6 targets (arquivos vazios que compilam).
2. `scripts/vendor-ghostty-vt.sh`: clona o Ghostty no hash pinado, `zig build -Demit-lib-vt -Doptimize=ReleaseFast --prefix vendor/ghostty-vt`, valida que `libghostty-vt.a` e os headers apareceram.
3. Target `CGhosttyVT` com `module.modulemap` apontando para os headers vendorizados.
4. `VitraCore`: `forkpty(3)` + `TerminalCore` (protocolo) + loop de leitura em `DispatchSource`.
5. `VitraGhostty`: implementação mínima — alimenta os bytes do PTY no terminal do libghostty e usa o **formatter** (`formatter.h`) para cuspir a tela como texto puro.
6. Executável de teste headless: roda `ls -la` num PTY 80×24 e imprime a tela renderizada em texto no stdout.

**Critério de saída:** `swift run vitra-spike` mostra a saída do `ls` corretamente formatada, com cores resolvidas. Zero pixel desenhado ainda.

**Riscos:**
- 🔴 **Alto — Zig 0.16 buildar o Ghostty inteiro nesta máquina.** Debug builds do Ghostty são notoriamente lentos e pesados (o README do ghostling avisa). Mitigação: `-Doptimize=ReleaseFast` desde o primeiro build e `-Demit-lib-vt` (que desliga xcframework, app macOS e docs). Se a compilação estourar RAM em 8 GB, mitigo com `-j2`.
- 🟡 Médio — Swift 6 concorrência estrita: os ponteiros opacos do libghostty não são `Sendable`. Mitigação: confinar todo o estado do core num `actor TerminalSession`, e marcar os handles com `@unchecked Sendable` só nessa fronteira, documentado.
- 🟡 Médio — assinaturas da API C mudarem em relação ao ghostling. Mitigação: o pin. Se ainda assim divergir, o ghostling `main.c` é o gabarito de uso correto.

**Gatilho do Plano B:** se ao fim da Fase 0 o núcleo não estiver produzindo tela correta, eu **paro e te aviso** antes de trocar para `SwiftTerm` atrás do `TerminalCore`. Não troco em silêncio.

---

### Fase 1a — Renderer Metal e terminal utilizável (~2 sessões)

Grid Metal, atlas de glifos via Core Text, `CAMetalLayer` em `NSView`.

- Atlas: textura R8 2048×2048 (**4 MB**, não 16 MB — glifos são máscara de cobertura, cor vem do vertex data). Alocação dinâmica por prateleiras, com fallback de crescimento.
- Um draw call por frame: instanced quads, um por célula suja. Cor de fundo/frente vão no buffer de instâncias.
- Truecolor, negrito/itálico/sublinhado, cursor bloco/barra/sublinhado com blink.
- Input: `NSTextInputClient` completo (IME, dead keys) → `ghostty_vt_key_*` → PTY.
- `SIGWINCH` correto no resize, com o reflow vindo de graça do core.
- `TERM=xterm-ghostty`, fallback `xterm-256color` se o terminfo não estiver instalado (checo com `infocmp` no launch, uma vez, e memoizo).
- Bracketed paste ligado.

**Render sob demanda — o coração do orçamento de CPU:**
sem `CVDisplayLink` livre. `CAMetalLayer` com `isAsynchronous = false`; um `setNeedsDisplay` disparado só quando (a) o core sinaliza dirty, (b) o cursor pisca, ou (c) a seleção muda. O timer de blink é um `DispatchSourceTimer` de 500 ms que **se suspende** quando a janela perde foco ou o cursor está sobre texto em movimento.

**Riscos:**
- 🔴 **Alto — esta é a fase de maior volume de código não-trivial do projeto.** É onde um atraso é mais provável. Mitigação: cortar ligaduras da 1a (empurrar para a 1b); ligaduras exigem shaping via Core Text por run, não por célula.
- 🟡 Médio — wide chars/graphemes desalinhando o grid. Mitigação: o core já resolve largura (`unicode.h`); o renderer só obedece a largura que ele reporta, nunca recalcula.
- 🟡 Médio — Kitty graphics precisa de um caminho de textura separado do atlas. Mitigação: adiar para a Fase 3, junto com o painel de imagem (é o mesmo código de decode).

---

### Fase 1b — Janelas, abas, splits, seleção, busca (~1 sessão)

`Cmd+T` abas, `Cmd+D`/`Cmd+Shift+D` splits, seleção por mouse com cópia, `Cmd+F` busca no scrollback (a busca usa os internos do libghostty, não reimplemento), `Cmd+K` limpa, scrollback 10 000 linhas.

**Risco:** 🟡 cada split é um PTY + um core + uma `CAMetalLayer`. Quatro splits = 4 layers. Mitigação: **um único device/command queue/atlas compartilhado** entre todas as views; só o buffer de instâncias é por view. Meço o custo de RAM por split adicional e registro.

---

### Fase 2 — Anexar arquivos ao Claude Code (~1 sessão) — a razão do projeto

- `Cmd+V` com imagem no `NSPasteboard` → PNG em `~/.vitra/attachments/<ISO8601>.png` → caminho absoluto inserido via bracketed paste, com aspas se houver espaço. **Nunca** bytes binários no PTY.
- Drag & drop na janela → caminhos absolutos, múltiplos separados por espaço.
- `Cmd+V` com arquivo do Finder (`NSPasteboard.PasteboardType.fileURL`) → mesmo caminho.
- Chip discreto acima do prompt: nome + miniatura se imagem. Uma `NSView` overlay, não-interativa, não bloqueante.
- Limpeza de `~/.vitra/attachments` > 7 dias, no launch, em background queue.

**Testado de verdade:** resolução e quoting de caminhos (espaços, aspas, acentos NFD do macOS, `~`, symlinks, nomes com `\n`). É onde um bug seu vira um comando errado no shell — vale teste unitário de verdade.

**Riscos:**
- 🟡 Médio — normalização Unicode: o HFS+/APFS entrega NFD e o shell/Claude Code espera o que o usuário digitou. Mitigação: sempre caminho absoluto do `URL.standardizedFileURL`, quoting com escape POSIX, teste com nome acentuado.
- 🟢 Baixo — miniatura: `QLThumbnailGenerator` já dá isso pronto, sem decodificar a imagem inteira.

---

### Fase 3 — Painel lateral de preview (~1 sessão)

`Cmd+Shift+P` alterna, `NSSplitViewController` redimensionável à direita.

| Tipo | Motor |
|---|---|
| png/jpg/heic/webp/gif/svg | `NSImageView` + `CGImageSource` (zoom/pan) |
| pdf | `PDFKit` |
| html / url / localhost | `WKWebView` (sob demanda) |
| texto / código | `NSTextView` com realce simples |

Três entradas, todas válidas: MCP `preview_file` (Fase 4), OSC `ESC ] 7337 ; file=/path ST`, e CLI `vitra open`.

**Ciclo de vida do WKWebView — mensurável:** criada no primeiro conteúdo web; ao fechar o painel ou trocar de tipo, `webView.removeFromSuperview()` + soltar a referência + soltar a `WKProcessPool`. O processo `com.apple.WebKit.WebContent` deve **sumir** da lista de processos. Verifico com `pgrep -f WebKit.WebContent` antes/depois e registro em `docs/MEASUREMENTS.md`.

**Riscos:**
- 🔴 **Alto — o orçamento de 150 MB.** O `WKWebView` sozinho custa 150–300 MB, mas em processos *separados*. Preciso do seu aval sobre qual número conta (ver §5).
- 🟡 Médio — imagens grandes (screenshot de Retina 6K) estouram RAM no `NSImageView`. Mitigação: `CGImageSourceCreateThumbnailAtMaxPixelSize` limitado ao tamanho da tela; a imagem full-res só é decodificada se você der zoom.
- 🟡 Médio — SVG: `NSImageView` não renderiza SVG de forma confiável. Mitigação: SVG cai no `WKWebView`, não no `NSImageView`. Ajuste à sua tabela original, registrado.

---

### Fase 4 — Browser controlável + MCP embutido (~2 sessões)

Aba de browser no painel (endereço, voltar/avançar/recarregar) e as 8 ferramentas MCP.

- Transporte: JSON-RPC 2.0 sobre stdio, escrito à mão com `Codable` (~200 linhas). **Sem dependência** — MCP é JSON-RPC, não justifica um SDK.
- `browser_snapshot`: script JS injetado em `WKUserScript` no **mundo isolado**, que percorre o DOM, descarta invisíveis (`offsetParent == null`, `visibility`, `opacity`, `aria-hidden`), e devolve `[{ref, role, name, value?}]` compacto. `ref` é um contador estável guardado num `WeakMap` do lado JS — sobrevive a re-render, morre com o elemento.
- `browser_screenshot`: `WKSnapshotConfiguration` → PNG em `~/.vitra/screenshots/`, devolve o caminho (não base64 — não estourar seu contexto).
- `browser_console`: `WKUserContentController` interceptando `console.*` no mundo isolado, ring buffer de 200 mensagens.

**Segurança (não negociável, não simplifico):** nenhuma ferramenta MCP executa shell nem lê arquivo fora do que você abriu explicitamente. `preview_file` valida que o caminho existe, é arquivo regular, e resolve symlinks antes de abrir. `browser_eval` roda no mundo isolado do WebKit. O socket em `~/.vitra/vitra.sock` recebe `chmod 0600`.

**Testado de verdade:** serialização/desserialização das 8 ferramentas, incluindo erro bem-formado.

**Riscos:**
- 🟡 Médio — `ref` estável sob SPAs que recriam o DOM inteiro. Mitigação: o snapshot é sempre revalidado no `browser_click`; `ref` morto → erro MCP explícito "elemento não existe mais, refaça o snapshot", em vez de clicar no lugar errado.
- 🟡 Médio — snapshot grande demais em páginas densas. Mitigação: teto de elementos com aviso explícito no retorno (nunca truncar em silêncio).
- 🟢 Baixo — o socket: um `DispatchSource` num `AF_UNIX` de stream, protocolo com prefixo de tamanho.

---

### Fase 5 — Configuração e temas (~1 sessão)

`~/.vitra/config.toml`, hot-reload via `FSEvents` (não polling). Fonte, tamanho, tema (16 cores + fg/bg/cursor), opacidade e blur da janela (`NSVisualEffectView`), padding, scrollback, shell, keybindings. Janela de preferências em SwiftUI editando o mesmo arquivo. Dois temas prontos: um escuro e um claro.

**Decisão sobre TOML:** parser de subset próprio, ~150 linhas + testes (tabelas, strings, ints, floats, bools, arrays). Não vale uma dependência (`TOMLKit` arrasta `tomlplusplus`, C++, e peso de binário) para um arquivo de config que eu mesmo defino. Se o subset apertar na prática, eu te aviso antes de trocar.

**Risco:** 🟢 baixo. `FSEvents` em arquivo único precisa observar o *diretório* (editores fazem rename atômico), não o arquivo — armadilha conhecida, já contornada no desenho.

---

### Fase 6 — Ícone e distribuição (~1 sessão)

**Ícone.** Desenho em Core Graphics num script Swift (`scripts/make-icon.sh`), não SVG — dá controle direto sobre gradiente, refração e o squircle do gabarito Big Sur, e exporta todos os tamanhos numa passada.

Composição: fundo em gradiente radial azul-petróleo → quase preto; lâmina de vidro inclinada em perspectiva com espessura visível; refração dispersando um espectro sutil na borda inferior direita; caret de prompt em luz clara, gravado sobre o vidro. Sem texto, sem "V".

Legibilidade em tamanho pequeno: **três variantes de arte, não um downscale.** 1024/512 com refração e espectro completos; 128/64 sem espectro, vidro simplificado; 32/16 só a lâmina e o caret, contraste aumentado.

**Vou te mostrar o PNG 512×512 e esperar seu ok antes de gerar o `.icns`.**

**Distribuição.** `scripts/release.sh`: Release com `-Osize` + `SWIFT_COMPILATION_MODE=wholemodule`, dead-strip, `.app`, `codesign -s -`, `.dmg` com fundo customizado, ícone de volume e o atalho para `/Applications` posicionado (via AppleScript no Finder). README com a instrução de `xattr -dr com.apple.quarantine`.

**Risco:** 🟡 médio — o posicionamento de ícones no `.dmg` via AppleScript é frágil e depende do Finder. Mitigação: se der problema, uso `create-dmg` como referência de layout, mas mantenho o script próprio.

---

## 5. Como eu vou medir os orçamentos (medir, não estimar)

Nada de "deve estar em torno de". Todo número no relatório vem de um destes comandos, gravado em `docs/MEASUREMENTS.md` com data e hash do commit.

### Memória

Métrica canônica: **`phys_footprint`**, não RSS. É o que o macOS usa para jetsam e o único número que corresponde ao que o Activity Monitor chama de "Memory". RSS conta páginas compartilhadas (frameworks do sistema) que o app não "gasta" de verdade.

```bash
footprint -j $(pgrep -x Vitra)          # phys_footprint, compressed, swapped
vmmap --summary $(pgrep -x Vitra)       # onde a memória está: Metal, malloc, __TEXT
ps -o rss=,vsz= -p $(pgrep -x Vitra)    # RSS, para você comparar com o que já conhece
```

Reporto os dois: `phys_footprint` (canônico) **e** RSS (o que você pediu). Se divergirem muito, explico onde.

Cenários fixos, sempre os mesmos, em `scripts/measure.sh`:

| Cenário | O que é |
|---|---|
| `idle` | app aberto, 1 aba, shell no prompt, 30 s parado |
| `load` | `cat` de um arquivo de 100 MB (gerado com `mktemp` + `head -c`) |
| `scrollback` | scrollback cheio: 10 000 linhas via `yes` + `head` |
| `splits4` | 4 splits ativos, cada um com um shell |
| `preview-img` | painel aberto com um PNG de 4 MB |
| `preview-pdf` | painel aberto com um PDF de 50 páginas |
| `browser` | `WKWebView` ativa numa página real |
| `browser-closed` | **após** fechar o painel — o número que prova a desalocação |

**Como o WKWebView entra na conta — preciso do seu aval.** O WebKit roda em processos separados (`com.apple.WebKit.WebContent`, `Networking`, `GPU`). O `phys_footprint` do processo `Vitra` **não** os inclui. Duas leituras possíveis do seu orçamento de 150 MB:

- **(a)** 150 MB é o processo `Vitra`, e o WebKit é contabilizado à parte — coerente com "o WebKit só entra em cena quando o navegador é aberto".
- **(b)** 150 MB é a soma de tudo, incluindo os filhos do WebKit — mais rigoroso, e provavelmente inatingível com uma página real aberta.

Eu vou reportar **os dois números sempre** (processo e árvore somada, via `footprint` em cada pid filho), e trato **(a)** como a meta contratual, com **(b)** informativo. Se você quiser (b) como meta dura, me diga — muda o desenho da Fase 4.

### CPU

Meta: ~0% ocioso.

```bash
top -l 10 -s 1 -pid $(pgrep -x Vitra) -stats cpu   # média de 10 amostras, ocioso
sudo powermetrics --samplers cpu_power -i 1000 -n 10   # impacto energético real
```

E, quando algum número ficar ruim, aí sim o Instruments para achar a causa:

```bash
xcrun xctrace record --template 'Time Profiler' --attach $(pgrep -x Vitra) --output /tmp/vitra.trace
xcrun xctrace record --template 'Allocations' --launch -- .build/release/Vitra
```

**Critério objetivo de "0% ocioso":** média < 0,3% em 10 amostras de 1 s com a janela em foco e cursor piscando; **0,0%** com a janela sem foco (o timer de blink suspenso é o que prova o desenho de render sob demanda).

### Regressão

`scripts/measure.sh` roda ao fim de cada fase e **anexa** uma linha em `docs/MEASUREMENTS.md`. Se um número piorar entre fases, aparece na tabela — não em memória minha.

## 6. Cronograma e ordem de execução

| Fase | Entrega | Tamanho |
|---|---|---|
| 0 | núcleo VT provado, headless | 1 sessão |
| 1a | terminal Metal utilizável | 2 sessões |
| 1b | abas, splits, seleção, busca | 1 sessão |
| 2 | anexos (a razão do projeto) | 1 sessão |
| 3 | painel de preview | 1 sessão |
| 4 | browser + MCP | 2 sessões |
| 5 | config TOML + temas | 1 sessão |
| 6 | ícone + `.dmg` | 1 sessão |

Commits pequenos, um por unidade lógica, `main` sempre compilando. Português com você; inglês no código, commits e comentários.

## 7. Três coisas que preciso de você antes de começar

1. **Instalar as duas ferramentas ausentes** (é a única coisa que eu não consigo fazer sozinho com segurança, porque muda seu sistema):

   ```bash
   brew install zig ninja
   ```

2. **Confirmar o desenho do MCP** da §3 (casca stdio + unix socket), ou apontar outro.

3. **Escolher a leitura do orçamento de 150 MB** da §5: (a) processo `Vitra`, WebKit à parte — minha recomendação; ou (b) árvore inteira somada.

Com isso respondido, começo pela Fase 0.
