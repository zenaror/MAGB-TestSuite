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

## O que falta

Com o Raw TCP confirmado também, só falta o P2P (Caller/Listener) —
que precisa de duas instâncias rodando ao mesmo tempo, uma conversando
com a outra, algo que não dá pra confirmar sozinho numa única sessão de
teste.
