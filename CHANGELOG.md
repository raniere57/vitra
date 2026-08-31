# Changelog

Cada versão, o que mudou nela, e as medições por trás das afirmações.
As datas são o dia em que a imagem de disco foi construída.

## 0.1.2 — 2026-08-31

- Janelas que ninguém está olhando param de desenhar. Uma aba em segundo plano,
  uma janela minimizada ou o app escondido agora devolvem as superfícies de GPU
  que seguravam e param o display link. Oito abas foram de **494 MB para
  80 MB**, e 56 MB de saída impressos numa janela escondida custam **0,03 s de
  CPU em vez de 0,21 s**. O que está rodando continua rodando, e volta
  desenhado.
- O atlas de glifos é dimensionado pela célula da fonte em vez de ser sempre
  2048×2048: 1 MB em vez de 4 MB no tamanho padrão.
- Corrigido: o buffer de instâncias era reescrito enquanto a GPU ainda podia
  estar lendo o frame anterior. Agora são dois buffers e um semáforo.
- Corrigido: um shell aberto pelo Vitra não herda mais os marcadores de sessão
  do agente que lançou o Vitra (`CLAUDECODE`, `CLAUDE_CODE_*`, `AI_AGENT`). Um
  Claude Code iniciado num painel desses acreditava ser filho da sessão que
  abriu a janela e desligava a própria transcrição. O que o usuário define num
  perfil continua voltando quando o shell lê aquele perfil.

## 0.1.1 — 2026-08-31

- Duplo clique no divisor do painel de visualização o maximiza sobre a janela
  inteira; `Esc` restaura a divisão.
- Corrigido: um painel não segue mais o layout até virar uma lasca. Maximizar o
  painel redimensionava o shell para umas duas colunas, o que fazia o que
  estivesse rodando refluir todas as linhas que segurava; o Escape trazia de
  volta uma janela de escombros. O tamanho de um painel só chega ao programa
  enquanto o painel está visível e com mais de 100 pontos de largura.
- Corrigido: o divisor da divisão não é mais desenhado por cima do painel
  maximizado.
- Uma chamada de ferramenta agora inicia o Vitra quando ele não está rodando,
  em vez de falhar com "abra o Vitra e tente de novo". O auxiliar pede ao
  sistema para abrir o bundle de onde ele mesmo está rodando, e executa o
  binário por conta própria onde o sistema não abre.
- `browser_back` e `browser_forward`: histórico no painel do navegador, cada um
  esperando a página realmente mudar antes de responder.
- `browser_click` e `browser_type` com submissão agora esperam a navegação que
  começaram e relatam onde a página parou, inclusive aplicações de página única
  que trocam o endereço sem carregar nada. A resposta avisa que os refs antigos
  se foram, porque se foram mesmo.
- A fonte padrão é a SF Mono em vez da Menlo. Ela vem com o macOS, então nada é
  instalado e nada é embutido; `family = "SF Mono"` na configuração agora é
  resolvido pela fonte do sistema, que é o único jeito de pedi-la.

## 0.1.0 — 2026-08-31

Primeira build pública. Um terminal que hospeda agentes de código de linha de
comando.

### O terminal

- libghostty-vt para o núcleo VT, um renderizador Metal com atlas de glifos do
  Core Text, e nenhum timer rodando quando a tela não muda.
- Divisões, abas e janelas, com o painel em foco anelado na cor da pasta.
- Scrollback, seleção, copiar e colar; a roda vai para o programa quando ele
  pede o mouse, e para o scrollback quando não pede.
- Blocos de comando: cada comando carrega o próprio trilho, o próprio tempo e o
  próprio status de saída, via integração de shell para zsh.
- `Cmd-+`, `Cmd--` e `Cmd-0` mudam o tamanho da fonte em tudo de uma vez.

### Em volta dele

- **Barra lateral de sessões** — cada conversa do Claude Code na máquina,
  agrupada por projeto, pesquisável, retomada numa aba nova. A que você está é
  marcada.
- **Trilho de pastas** — diretórios favoritos com ícone, cor e tema próprios.
- **Anexos** — solte um arquivo ou cole uma imagem e o caminho é digitado no
  prompt; os bytes nunca tocam o pty.
- **Painel de visualização** — HTML, Markdown, imagens, PDFs e um navegador, num
  WKWebView criado quando abre e destruído quando fecha.
- **Layout** — janelas, abas, divisões, pastas e sessões voltam depois de um
  reinício. O botão vermelho esconde o app; `Cmd-Q` encerra.
- **Servidor MCP** compilado no binário: um agente dentro do Vitra pode abrir um
  arquivo na visualização ou ler a página que está vendo, e nada além disso. Sem
  shell, sem arquivo que você não abriu.
- **CLI** — `vitra open <arquivo>` mostra um arquivo no painel de visualização.

### Medido

- Cerca de 80 MB de footprint físico para uma janela, 50 MB dos quais são os
  drawables de onde a GPU compõe.
- 300 mil linhas de scrollback custam cerca de 2 MB.
- Os números completos, e como foram tirados, estão em
  [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

### Limites conhecidos

- A imagem de disco é assinada ad-hoc, não notarizada, então uma cópia baixada
  precisa de `xattr -dr com.apple.quarantine /Applications/Vitra.app`.
- Apenas Apple silicon e macOS 14 ou posterior.
- A integração de shell cobre zsh; bash e fish ainda não estão ligados.
- Sem ligaduras e sem emoji colorido no renderizador ainda.
