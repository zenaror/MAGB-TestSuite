# Diário do projeto (RGBDS)

Registro em nível macro dos principais bugs encontrados e correções
feitas ao longo das versões desta implementação em RGBDS/assembly,
irmã mais nova da versão em GBDK (`gbdk/docs/journal.md`) — sem entrar
em detalhe técnico profundo, só a "jornada". Detalhes completos de cada
item estão em `docs/status.md` e nos commits correspondentes.

## Toolchain mudou debaixo do pé

Entre uma sessão e outra, o `rgbasm` instalado pulou da versão usada
originalmente (0.6.1) direto para a 1.0.3 — várias versões de
diferença. O build simplesmente parou de funcionar: a flag `-H` (que
mantinha o `nop` depois de `halt`) tinha sido removida faz tempo (o
próprio comportamento que ela controlava não existe mais, então nem
faz falta), `-i` de include virou `-I`, e declarar uma constante nova
sem `DEF` na frente (`NOME EQU valor`) parou de ser aceito. Nada disso
mudou qualquer coisa no comportamento do protocolo — foi só acompanhar
a atualização do próprio montador.

## GB00 do zero: dois bugs achados testando, não lendo o código

Implementar MD5, base64 e o "embaralhamento" de bits do REON (GB00) do
zero em assembly, sem poder copiar a versão já pronta em C, trouxe dois
bugs reais que só apareceram comparando a saída contra valores
conhecidos, não relendo o código: uma função de decodificação base64
estava usando o mesmo registrador para duas coisas ao mesmo tempo (o
ponteiro de entrada e um scratch interno de outra função chamada no
meio do caminho), corrompendo tudo depois do primeiro caractere; e duas
funções da parte do GB00 estavam sem querer reaproveitando a mesma
área de memória para guardar coisas diferentes, fazendo uma apagar o
ponteiro da outra no meio do cálculo.

## A ROM só usava metade do espaço

Só depois de precisar de mais espaço pra código (a própria
implementação do GB00) foi que percebemos: a ROM inteira só estava
usando os 16KB de baixo do cartucho — a metade de cima (que também
existe fisicamente, mesmo sem troca de banco, num cartucho sem
mapeador) estava completamente vazia, preenchida só com padding. Bastou
dizer pro linker pra usar aquele espaço também, e o problema de "não
cabe mais nada" sumiu.

## Todo o resto do ISP/HTTP de uma vez

Depois da primeira versão do teste de ISP/HTTP (só o "Tamago Egg")
passar de verdade num teste real, implementamos o resto do menu inteiro
numa única leva: o submenu com os 7 itens que a versão em GBDK já
tinha, a autenticação GB00 (desafio/resposta) para as notícias, e um
motor de protocolo "linha por linha" (parecido com o que SMTP e POP3
usam de verdade) para os testes de e-mail. O Raw TCP (visualizador tipo
netcat) fechou a lista.

## E-mail: dois bugs reais, achados em hardware de verdade

Testando contra o `libmobile-bgb` de verdade pela primeira vez, os dois
testes de e-mail deram problema — cada um por um motivo diferente:

- **Envio (SMTP)**: o servidor de teste do REON respondeu com um erro
  de "comando não reconhecido" logo depois de aceitar a mensagem.
  Olhando o código-fonte real do servidor deles, achamos a causa: ele
  decide que uma mensagem terminou verificando se **cada linha, uma por
  uma**, termina em ponto final seguido de quebra de linha — não se a
  linha é *só* um ponto. Como a nossa mensagem de teste tinha uma frase
  que terminava com ponto final normal, o servidor achou que aquela já
  era a linha de encerramento, uma linha antes da hora, e tratou a
  linha de encerramento de verdade como se fosse um comando digitado
  errado. A correção foi só tirar aquele ponto final da frase de teste.
- **Recebimento (POP3)**: depois de autenticar direitinho, a ROM
  entrava num loop, ficando presa pedindo mais dados pro adaptador sem
  nunca conseguir avançar. A resposta real do servidor (os cabeçalhos
  do e-mail de teste) veio inteira de uma vez, num pacote só, mas
  maior do que o espaço que a ROM tinha reservado pra guardar essa
  resposta — o pedaço que sobrou (justamente o fim da mensagem) foi
  perdido, porque um pacote de resposta real não vem de novo se a gente
  pedir de novo. Aumentando o espaço reservado, o problema não ocorreu
  mais. Essa categoria de bug (mais de uma linha, ou uma resposta maior
  do que o esperado, chegando junto num pacote só) já tinha aparecido
  antes na versão em GBDK -- ver a entrada "E-mail: bytes perdidos numa
  mesma resposta" no diário daquela versão -- mas dessa vez a causa foi
  o tamanho do espaço reservado, não a lógica de separar as linhas.

Depois dessas duas correções, um novo teste real confirmou os dois
passando (envio entregue de verdade, recebimento sem travar).

## Raw TCP: letras sumindo, mas não era a fonte

No mesmo teste real, algumas letras (o "O", por exemplo) simplesmente
não apareciam na tela do Raw TCP de vez em quando. Não era bug de
fonte: toda outra tela deste ROM desliga a tela (LCD) antes de escrever
qualquer coisa na memória de vídeo, justamente para nunca escrever
bem na hora em que o próprio hardware de vídeo está lendo aquela mesma
memória pra desenhar a tela — se isso acontece, a escrita é
simplesmente ignorada. O Raw TCP era a única tela que escrevia ao vivo,
byte por byte, sem essa proteção. Bastou aplicar a mesma proteção que
já existia em todo o resto do código.

## Letras e números quase ilegíveis -- e por que não usar a fonte do Pokémon

Depois de usar o ROM de verdade por um bom tempo, ficou claro que as
letras maiúsculas e os números estavam quase ilegíveis. Olhando os
dados da fonte, dava pra ver o motivo: era uma fonte de sistema
reduzida por um script até caber num espaço pequeno demais, e algumas
letras (o "O", por exemplo) ficaram literalmente tortas -- os dois
traços da lateral não alinhavam entre uma linha e outra.

Antes de redesenhar, veio a pergunta óbvia: dava pra usar a fonte do
próprio jogo Pokémon Crystal, que está guardada como referência neste
repositório? A resposta foi não -- aquele arquivo é a fonte extraída de
dentro da ROM japonesa de verdade, sem licença nenhuma, exatamente o
tipo de material que este projeto já decidiu nunca incluir (ver a seção
de direitos autorais do `CLAUDE.md`). Em vez disso, as 26 letras e 10
números foram desenhados do zero, um por um, usando o espaço inteiro do
quadrado de 8x8 pixels (antes só usava uma fatia pequena dele) e
alinhando a "linha de base" das maiúsculas com a mesma linha que as
minúsculas já usavam, pra tudo continuar combinando visualmente.
Testado numa tela de verdade depois, ficou bem mais legível.

Sobrou um caso isolado: o "m" minúsculo (esse não fazia parte do
redesenho, já existia de antes) usava a mesma "perna" repetida em toda
a altura da letra, sem nada ligando as três partes no topo — na
prática, virava só três riscos soltos na tela, a ponto de "mae" ficar
irreconhecível. Bastou fechar o topo das três pernas com uma barra só,
do mesmo jeito que o "n" (que sempre funcionou bem) já fazia com as
dele.

## Um bug de verdade do lado do servidor, não do ROM

Testando o envio de e-mail (SMTP) de verdade, o `libmobile-bgb` mostrou
um `250 OK` seguido de um estranho `500 command not recognized`.
Comparando bytes exatos com o código-fonte real do servidor de teste do
REON, achamos a causa: o servidor decide que a mensagem terminou
olhando se **cada linha, isoladamente**, termina em ponto final -- não
se a linha inteira é só um ponto, que é a regra real do protocolo. A
frase de teste deste ROM terminava com um ponto final normal de frase,
e o servidor cortou a mensagem uma linha antes da hora por causa disso.
Não era bug daqui -- a correção do nosso lado foi só tirar aquele ponto
final da frase de teste; a correção de verdade (comparar a linha inteira
em vez do sufixo) foi reportada para o próprio projeto do REON.
Confirmado depois, com a correção aplicada dos dois lados, que o envio
funciona limpo (`250 OK`) tanto aqui quanto na versão em GBDK -- que
tinha exatamente a mesma frase de teste, com o mesmo ponto final, nunca
testada até então contra um servidor real; ficou corrigida de graça
junto.

## Polimento depois de usar bastante: tela piscando, sem som, sem saber qual build

Depois de um bom tempo de uso real, três coisas incomodavam:

- **A tela piscava a cada tecla, a cada item de menu, a cada byte
  recebido no Raw TCP.** A causa: toda escrita na tela desligava o LCD
  inteiro, escrevia, e ligava de novo -- forma mais simples de nunca
  corromper a memória de vídeo, mas visível como um flash cada vez que
  acontecia, e isso rodava o tempo todo. A primeira tentativa de
  correção trocou essa abordagem inteira por uma escrita que checa o
  modo do próprio hardware de vídeo antes de cada byte (sem nunca
  desligar a tela) -- o flicker realmente sumiu, mas um teste real logo
  depois mostrou um efeito colateral pior: letras sumindo aleatoriamente
  do texto (ex.: "MOBILE ADAPTER GB" virando "M BIL  ADAPTER GB"), e
  lixo gráfico ao entrar/sair de submenu. A checagem tinha uma corrida
  real -- o intervalo "confirmei que é seguro" até "escrevi de fato" é
  curto o bastante pra às vezes cair bem na hora que o modo perigoso do
  vídeo começa, descartando aquele byte em silêncio. A correção
  definitiva separou por tamanho/frequência: escritas pequenas (uma
  linha de menu, um caractere do Raw TCP) esperam o próximo VBlank uma
  vez só e escrevem tudo de uma vez, já que essa janela é enorme
  perto do que qualquer uma delas precisa escrever; as duas
  transferências grandes (a fonte inteira, a tela inteira -- 1024 bytes
  cada, raras: só no boot ou ao trocar de tela) voltaram a desligar o
  LCD por completo, sem corrida nenhuma, e sem causar o flicker
  constante que motivou tudo isso (rodam raro demais pra incomodar).
  Testado de novo, bem mais a fundo dessa vez (navegação verificada
  lendo a posição do cursor direto da memória, não só olhando a tela):
  30 redesenhos de menu, 25 entradas/saídas completas do submenu de
  ISP/HTTP e 60 trocas de caractere no editor de senha, todos batendo
  exatamente com o esperado.
- **Não tinha nenhum som**, diferente da versão em GBDK (um bipe curto
  ao navegar no menu, um som de sucesso, um de erro). Portado do zero
  pro assembly, ligado exatamente nos mesmos pontos que a versão em
  GBDK já usava.
- **Não dava pra saber qual build estava rodando na tela**, coisa que a
  versão em GBDK já mostrava (hash do commit em builds do CI, hora da
  compilação em builds locais) -- importante justamente para não
  confundir uma versão antiga com uma nova durante teste manual. Levado
  pro assembly do mesmo jeito, incluindo o CI.

Enquanto mexia nos editores de texto/número para adicionar o som, uma
lacuna conhecida (documentada desde o início: "segurar o botão pra
mover mais rápido" não existia aqui, diferente do GBDK) foi fechada
junto -- segurar uma direção agora acelera depois de meio segundo,
igual ao GBDK.

## E-mail: mandava certo, mas o Mobile Trainer não conseguia abrir

Mesma descoberta que a versão em GBDK teve, na mesma sessão: as
mensagens de teste enviadas por este ROM chegavam certinho por POP3,
mas o Mobile Trainer de verdade não conseguia abri-las na caixa de
entrada. A causa: mensagens reais que o próprio Mobile Trainer manda
sempre levam um conjunto de cabeçalhos (`MIME-Version`, `From`, `To`,
`Content-Type: text/plain; charset=iso-2022-jp`) que a nossa mensagem
de teste nunca teve -- só um `Subject:`. Confirmado antes de mexer em
qualquer código: injetando uma mensagem de teste direto numa caixa de
entrada real, sem esses cabeçalhos (Mobile Trainer não abriu) e depois
com eles (abriu normalmente).

Corrigido: o envio agora monta a mensagem com esses mesmos cabeçalhos,
usando o e-mail real lido do adaptador tanto em `From:` quanto em `To:`.
Diferente da versão em GBDK, aqui não faltou espaço de ROM (sobrava bastante),
só precisou aumentar o buffer que monta a mensagem (de 72 para 208
bytes) e trocar uma tentativa inicial de escrita (`ex de,hl`) por
outra, já que essa instrução do Z80 nem existe no SM83 do Game Boy.
Verificado byte a byte via PyBoy -- inclusive um teste que primeiro deu
lixo no meio da string, rastreado até a própria técnica de teste (jogar
o PC direto no meio de um "tick" pode corromper a execução de um jeito
que não tem nada a ver com o código sendo testado); usando um hook num
ponto de execução real em vez de um endereço arbitrário, o resultado
saiu perfeito de primeira.

## O que falta

Com o Raw TCP confirmado também, só falta o P2P (Caller/Listener) —
que precisa de duas instâncias rodando ao mesmo tempo, uma conversando
com a outra, algo que não dá pra confirmar sozinho numa única sessão de
teste.
