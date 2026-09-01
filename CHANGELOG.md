# Changelog

Cada versão, o que mudou nela, e as medições por trás das afirmações.
As datas são o dia em que a imagem de disco foi construída.

## Não publicado

### Digitar por cima da palavra selecionada

- **Duplo clique numa palavra da linha que você está digitando e digite**: a
  palavra é substituída, e `backspace` a apaga. O terminal move o cursor do
  próprio programa com setas e apaga com backspaces, que é a única linguagem que
  ele entende — seleção de terminal é marcação de células, o programa do outro
  lado nunca soube dela.
- Vale só para a linha do cursor, na tela viva e fora da tela alternativa: uma
  palavra selecionada no histórico não é texto que alguém está editando.

### Painéis que se reorganizam

- **Arrastar um painel para cima de outro escolhe o lado.** A metade do painel
  onde o cursor está acende, e é ali que ele entra: esquerda, direita, em cima
  ou embaixo. Antes o painel solto sempre virava uma coluna à direita, que é
  justamente o que ficava fino demais.
- **Alça própria para arrastar**: os seis pontinhos no canto do painel, com a
  mãozinha no cursor. O botão de nova aba voltou a ser só clique — arrastar por
  ele era um significado a mais escondido no mesmo ícone.
- **`Ctrl`-`Cmd`-setas move o painel em foco** para aquela parede da janela —
  o mesmo rearranjo sem tirar as mãos do teclado (File → Move Pane).

- `Cmd-Q` agora precisa ser **segurado** por um segundo, com uma placa na tela
  dizendo isso e uma barra enchendo — como no Chrome. Num terminal, a tecla de
  sair fica ao lado da de fechar painel, e um deslize levava quatro shells
  junto. Um toque não fecha mais nada: mostra a placa e ela some sozinha. O item
  do menu continua fechando na hora, porque escolher Quit com o ponteiro é
  deliberado.

- Clicar numa sessão na barra lateral abre um **painel novo** ao lado, com
  aquela sessão, em vez de tomar o painel que está com o teclado. A conversa em
  que você já estava continua lá, e você fecha quando quiser.
- Corrigido: a rolagem durante o arraste só começava quando o ponteiro saía do
  painel — e numa janela que ocupa a tela inteira o ponteiro para na borda e
  nunca sai. Agora ela começa a doze pontos da borda, por dentro.
- A seleção é desfeita quando a roda é entregue ao programa. Ela marca células,
  e um programa que rola a própria visão repinta aquelas mesmas células com
  outro texto — a marca ficava lá, parecendo que a seleção tinha mudado sozinha.
  No scrollback do terminal (`Shift` + roda) a seleção continua acompanhando o
  texto dela, como sempre acompanhou.
- **`Shift` + roda rola o scrollback do terminal** mesmo com um programa que
  pediu o mouse. Dentro do Claude Code a roda é dele, o que deixava o histórico
  do terminal inalcançável — e com ele a seleção do que já rolou para fora.
- **Shift-clique estende a seleção**: clique onde começa, role à vontade (roda,
  trackpad, `Shift-PageUp`), shift-clique onde termina. É o caminho sem arrastar
  para copiar algo mais longo que a tela.
- Corrigido: a rolagem durante o arraste só começava quando o ponteiro saía do
  painel — e numa janela que ocupa a tela inteira o ponteiro para na borda e
  nunca sai. Agora ela começa a doze pontos da borda, por dentro.
- A seleção é desfeita quando a roda é entregue ao programa. Ela marca células,
  e um programa que rola a própria visão repinta aquelas mesmas células com
  outro texto — a marca ficava lá, parecendo que a seleção tinha mudado sozinha.
  No scrollback do terminal (`Shift` + roda) a seleção continua acompanhando o
  texto dela, como sempre acompanhou.
- **`Shift` + roda rola o scrollback do terminal** mesmo com um programa que
  pediu o mouse. Dentro do Claude Code a roda é dele, o que deixava o histórico
  do terminal inalcançável — e com ele a seleção do que já rolou para fora.
- **Shift-clique estende a seleção** a partir de onde ela começou, mesmo depois
  de rolar a tela: clique no começo, role com a roda, shift-clique no fim. É o
  caminho para copiar um trecho maior que o painel sem segurar o botão.
- Corrigido: arrastar uma seleção para além da borda não rolava a tela, então
  só dava para selecionar o que coubesse nela. Agora a rolagem continua enquanto
  o ponteiro fica parado fora do painel, mais rápida quanto mais longe da borda,
  e a seleção acompanha — a âncora é uma posição na tela do terminal, não na
  janela de visualização.
- **Arrastar um painel para outra aba**: segurando o botão de aba no canto e
  arrastando, passar sobre uma aba a traz para a frente, e soltar dentro dela
  coloca o terminal ali como divisão. A barra de abas nativa não avisa nada a
  ninguém, mas o ponteiro é nosso enquanto o arraste é nosso.
- Um terceiro botão no canto do painel o leva para uma **aba nova**, com o shell
  e o scrollback intactos — o painel muda de janela, não é recriado.

- Um painel pode tomar a janela inteira: ao lado do × que aparece com o
  ponteiro, um segundo botão dá a janela toda àquele terminal, e `Esc` devolve
  os outros — com o divisor de volta onde estava, e não redistribuído. Os
  painéis escondidos param de desenhar enquanto estão fora, como já acontece
  com o painel de visualização maximizado.

- **opencode** ao lado do Claude Code. `Opt-Cmd-O`, ou o terceiro botão da barra
  de título, abre uma barra lateral com as sessões do opencode — lidas do banco
  SQLite dele, só para leitura, sem sub-sessões de subagentes — e clicar numa
  delas roda `opencode --session <id>` no painel em foco. Um painel rodando
  opencode é reconhecido pelo processo que segura o terminal, não pelo título,
  e a barra de título mostra `◆ <sessão>`. O servidor MCP do Vitra funciona
  igual para os dois: registrado em `~/.config/opencode/opencode.json`, o
  opencode usa o mesmo navegador e o mesmo painel de visualização.

- Um favorito pode ser um **servidor SSH**. Preenchendo o campo de host na
  janela de pastas, o favorito passa a apontar para outra máquina, aparece no
  trilho e na árvore como qualquer pasta, e clicar nele abre uma aba rodando
  `ssh -t <host> 'cd "<diretório>" && exec "$SHELL" -l'`. O caminho de um
  favorito remoto nunca é usado como diretório local, e a barra de título mostra
  `host:/diretório`.
- Um botão de globo na barra de título, e `Cmd-Shift-B` (**View → Browser**),
  abrem o navegador no painel com o cursor na barra de endereço. Ele existia desde a primeira versão, mas só um link clicado
  ou um agente conseguia abri-lo.
- `Esc` fecha a janela de pastas.
- Corrigido: `localhost:5173` na barra de endereço era lido como o esquema
  `localhost`, e o macOS perguntava qual aplicativo abre esse tipo de URL. Só
  `http`, `https`, `file`, `about` e `data` contam como esquema; o resto é
  hospedeiro — e um hospedeiro local vai por `http`, o resto por `https`.
- Todo favorito ganhou um campo de **comando**, rodado quando a aba abre —
  `claude`, por exemplo. Num favorito remoto ele roda do outro lado, depois do
  `cd`, num shell de login *e* interativo — sem isso o `claude` instalado pelo
  nvm ou em `~/.local/bin` não está no `PATH` de um `ssh host comando` — com um
  shell de login esperando por baixo: sair do que foi lançado deixa você no
  servidor em vez de desconectar.

- A barra de título sempre nomeia a pasta. Antes ela ficava vazia justamente no
  caso mais comum — o shell parado na raiz da pasta da janela —, que era quando
  ela tinha mais a dizer.
- A sessão do Claude Code do painel em foco aparece ao lado da pasta, com o
  mesmo `✳` da barra lateral. Com a lateral recolhida não havia nada na tela
  dizendo em qual conversa aquele terminal estava. As sessões são lidas na
  primeira vez que um painel é visto rodando Claude Code — ainda nunca no
  lançamento.

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
