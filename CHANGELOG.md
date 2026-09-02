# Changelog

Cada versão, o que mudou nela, e as medições por trás das afirmações.
As datas são o dia em que a imagem de disco foi construída.

## Não publicado

### Um navegador por painel

- **Cada terminal tem o seu navegador.** Dois agentes em dois painéis usavam o
  mesmo browser e um atropelava a página do outro. Agora cada painel recebe um
  nome no ambiente do shell (`VITRA_PANE`); o helper `vitra mcp` que o agente
  inicia herda esse nome e o manda em cada chamada, e a GUI entrega a chamada à
  janela daquele painel e a um browser só dele. O painel lateral mostra o
  browser do painel em foco — ou do agente que acabou de pedir — e os outros
  seguem carregando atrás, sem escrever no cabeçalho.
- O globo, o menu e um link clicado abrem o browser do painel em foco. Fechar
  um painel derruba o browser dele; fechar a sidebar derruba todos.

### Botão de maximizar o painel

- Ao lado dos botões do cabeçalho do painel, um de **maximizar/restaurar**: o
  mesmo que o duplo clique no divisor e o `Esc` fazem, para quem está com a mão
  no mouse. As setas apontam para fora quando o painel cabe na metade, e para
  dentro quando ele tem a janela inteira.

### O painel lembra o caminho, e um caminho é um link

- **Voltar volta para onde você estava.** A seta do painel percorre o histórico
  de pastas e arquivos abertos; antes ela caía na raiz do shell, porque cada
  comando terminado sobrescrevia a pasta navegada com o `cwd` do terminal. O
  browser é um desvio: voltar dele leva ao arquivo ou pasta que ele interrompeu.
- **Caminhos de arquivo na saída são links.** `/abs/olu/to.png`, `~/x.md`,
  `src/App.swift:12:3` — absolutos, `~`, e relativos à pasta do shell, com a
  citação `:linha:coluna` descartada. Um clique abre no painel. O ponteiro só
  vira mão quando o arquivo existe: um `stat` no token sob o ponteiro, não em
  cada palavra da tela.
- **Três ações no cabeçalho** do painel: revelar no Finder, abrir no app padrão,
  copiar o caminho — para o arquivo aberto ou a pasta listada.
- **`Cmd-F` num texto** abre a barra de busca do próprio sistema. Custo zero.

### O agente não te arrasta mais de volta

- Uma chamada de ferramenta trazia a janela pra frente **ativando o app inteiro**
  (`NSApp.activate`), então enquanto um agente mexia no browser você era puxado
  de volta pro Vitra de qualquer outro app. Agora a janela só sobe dentro do
  Vitra, sem roubar o foco: ela está lá e à frente quando você voltar por conta
  própria.

### Buscar, zoom e abrir no sistema

- **`Cmd-F`** abre a busca na página — próximo com Enter, anterior com
  Shift-Enter, `Esc` fecha; um pontinho verde ou vermelho diz se achou.
- **`Cmd`-`+` / `-` / `0`** dão o zoom da página.
- **Botão de seta** no fim da barra de endereço abre a página atual no navegador
  do sistema, para o que não cabe num painel.
- Tudo nativo do WebKit: nenhum peso a mais no app.

### O browser lembra os logins

- As sessões e cookies do navegador agora **persistem em disco**, no container
  WebKit do próprio app: um login sobrevive ao painel fechar e ao app reiniciar,
  em vez de precisar entrar em tudo de novo toda vez. O painel de preview de
  arquivos continua sem persistir — ele mostra arquivos locais, não sites.

### O MCP para de cair no meio do trabalho

- O helper `vitra mcp` atendia **uma requisição por vez, travando**. Uma chamada
  demorada — uma página carregando, ou os segundos esperando o app subir —
  segurava a fila, e o `ping` que o cliente manda de tempos em tempos ficava sem
  resposta atrás dela: o Claude Code marcava o servidor como morto e você
  reconectava. Agora cada requisição é atendida por conta própria, a leitura
  nunca para, e só a escrita na saída é serializada. As respostas carregam o id,
  então o cliente casa cada uma na ordem que chegar.

### Uma GUI só, e sempre à vista

- O Vitra passou a ser **instância única**. Um helper `vitra mcp` que não
  alcança o socket abre o app; se o app já estava de pé mas lento pra responder,
  aquela segunda cópia rodava sem janela e tomava as ferramentas pra si — era o
  browser abrindo num processo que ninguém via. Agora a cópia extra detecta o
  dono vivo do socket e sai.
- Toda chamada de ferramenta **traz o app e a janela pra frente**. O browser de
  um agente não serve numa janela que está atrás, noutra Space; agora ela sobe
  junto com o que foi aberto.

### O Claude Code volta para a tela principal

- Versões recentes do Claude Code desenham a conversa na **tela alternativa**,
  onde o terminal não guarda nada que rolou para fora: a seleção que rola
  sozinha parava de alcançar respostas longas, e a roda passou a ser do
  programa. O Vitra agora exporta `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`
  para os shells que abre, e o CC imprime como antes — scrollback, seleção e
  roda de volta ao terminal. Quem preferir o modo novo define a variável como
  vazia no próprio perfil; o Vitra não sobrescreve o que já está definido.

### Mudar os terminais de uma aba para outra

- Botão novo na direita da barra de título: ele lista as outras abas — nome e
  quantos terminais cada uma tem — e a escolhida recebe **todos os terminais
  desta aba**, cada um contra o lado mais comprido do painel onde cai. A aba
  esvaziada fecha.
- Os botões da barra de título **acendem sob o ponteiro** — uma placa fraca, e
  mais forte ainda na que está aberta. Ícone pequeno sem rótulo e sem reação ao
  mouse é decoração, não controle.
- Era o que arrastar uma aba sobre a outra deveria fazer e nunca fez: aquele
  gesto pertence à barra de abas do sistema, que só reordena a fila.

### Marcas próprias para as duas sidebars

- Os botões do Claude Code e do opencode agora usam **as mesmas duas marcas que
  as sessões carregam na lista**: a estrela e o losango, desenhados no mesmo
  peso dos ícones do sistema. O relógio e os sinais de menor/maior que estavam
  ali não diziam nada sobre o que abriam, nem tinham relação um com o outro.

### Digitar por cima da palavra selecionada

- **Duplo clique numa palavra da linha que você está digitando e digite**: a
  palavra é substituída, e `backspace` a apaga. O terminal move o cursor do
  próprio programa com setas e apaga com backspaces, que é a única linguagem que
  ele entende — seleção de terminal é marcação de células, o programa do outro
  lado nunca soube dela.
- Vale só para a linha do cursor, na tela viva — inclusive na tela alternativa,
  que é onde o Claude Code desenha o prompt dele. Uma palavra selecionada no
  histórico rolado não é texto que alguém está editando, e ali nada é enviado.

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
