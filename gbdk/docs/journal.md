# Diário do projeto

Registro em nível macro dos principais bugs encontrados e correções
feitas ao longo das versões deste TestSuite, sem entrar em detalhe
técnico profundo — a ideia é dar uma visão da "jornada", não um log de
commits. Detalhes técnicos completos de cada um estão em
`docs/protocol-notes.md` e nos commits correspondentes.

## Handshake / sessão inicial

A troca de bytes inicial com o adaptador (Begin Session) exigiu alguns
ajustes finos:

- O registrador de velocidade/clock do serial (`SC_REG`) precisa ser
  escrito em **duas etapas separadas**, não numa escrita só — escrever
  tudo de uma vez causava falhas de handshake.
- A ROM CGB-only ligava e rodava, mas ficava com a tela em branco até
  chamarmos `set_default_palette()`.
- No BGB com `libmobile-bgb`, o relay do link serial pode entregar
  bytes de confirmação (ACK) atrasados — foi preciso tolerar o byte de
  "espera" (`0xD2`) em todo ponto de checagem, não só no loop de espera
  dedicado.

## Tela de configuração corrompida

A tela de "Read Config" mostrava números sem sentido no cabeçalho
(tipo "769/0" em vez de "1/3"). Investigando a fundo, achamos um bug
real do `printf` deste GBDK/SDCC: ele corrompe a saída quando recebe
uma expressão calculada na hora (tipo `page + 1`) como argumento —
passando o valor por uma variável já calculada antes, o problema some.
Aproveitamos pra também separar o título, que tinha um caractere a
mais que cabia na tela.

## Autenticação HTTP (GB00)

Um teste de HTTP específico do REON (autenticação GB00, com
MD5+base64) dava erro 401 depois de uma nova tentativa. A causa real
era um buffer pequeno demais que cortava a resposta do servidor no
meio — aumentando o buffer, resolveu. Nessa mesma frente, corrigimos
para usar o login lido de verdade da configuração do adaptador, em vez
de um valor fixo de teste.

## Travamento na tela de entrada de texto

Ao tentar adicionar um teclado na tela e depois "segurar para repetir
mais rápido", a ROM travava ao abrir a tela. Depois de investigar a
fundo (inclusive um caminho errado que parecia ter corrigido mas não
tinha), a causa real era que a função de repetição não bloqueava
esperando uma tecla nova — ela ficava redesenhando a tela sem parar, o
que parecia um travamento. A correção final manteve a repetição ao
segurar o botão, mas fazendo-a esperar direito entre teclas.

## P2P: erro genérico em vez do motivo real

Testando P2P entre duas máquinas via BGB, o Caller mostrava
"UNEXPECTED CMD" e o Listener só "TIMEOUT" — sem dizer o que realmente
aconteceu. Descobrimos que o adaptador tem um pacote de erro
específico ("Error Status") que qualquer comando pode receber no lugar
da resposta esperada, e nosso código não reconhecia esse pacote.
Depois de corrigido, a tela passou a mostrar exatamente qual comando
falhou e por quê, em vez de um erro genérico.

Também descobrimos, direto no código-fonte do `libmobile`, que ligação
P2P direta (por IP) e ligação via relay (tipo REON) são dois
mecanismos completamente diferentes — um não é só "trocar o número" do
outro. Isso estava documentado errado antes; foi corrigido.

Com o erro real (Error Status) já sendo mostrado corretamente, um novo
teste em duas máquinas físicas revelou a causa raiz por trás dele: o
Caller discava e mandava o "PING" quase na hora, mas o Listener ficava
esperando por só ~3 segundos antes de desistir — tempo curto demais
para duas instâncias de BGB rodando em máquinas diferentes, ligadas por
um socket TCP real, se sincronizarem. Quando o Listener desistia, ele
encerrava a ligação, e é exatamente isso que o Caller via do outro lado
como "Error Status" (a conexão foi derrubada por ele, não travou
sozinha). A espera foi aumentada para a mesma ordem de grandeza da
espera de discagem (bem mais generosa), mantendo o cancelamento pelo
botão B em todo momento.

Depois, descobrimos que o próprio adaptador só espera ~1 segundo por
uma ligação recebida (Wait For Call), não importa quanto tempo a ROM
esteja disposta a esperar — confirmamos isso lendo o código-fonte real
do `libmobile` e comparando com o disassembly original do Pokémon
Crystal, que faz exatamente a mesma coisa: ao ver esse erro específico
do adaptador, simplesmente manda o comando de novo. Passamos a fazer o
mesmo — tentar de novo em vez de esperar uma vez só por muito tempo.

Por fim, percebemos que quando um lado encerrava a ligação, às vezes o
outro lado ficava rodando pra sempre sem perceber, e às vezes recebia
um erro na hora — de forma inconsistente. Rastreamos até o
`libmobile`: ele já tinha uma correção parcial pra isso (ligação P2P
não é like internet, é mais parecida com uma chamada de telefone real,
que não tem como saber na hora que a linha caiu — o jogo tem que
perceber sozinho, por timeout). Só que essa correção cobria só metade
dos casos. Completamos a outra metade diretamente no fork do
`libmobile` usado pelo projeto. Depois de ajustar o PicoAdapterGB (o
hardware real usado para os testes) com essa correção, os testes de
P2P passaram a funcionar corretamente de ponta a ponta.

## E-mail: bytes perdidos numa mesma resposta

Um teste real mostrou o servidor de e-mail respondendo com duas linhas
de uma vez no mesmo pacote de rede. Nosso código só lia a primeira e
jogava fora o resto — o que passava despercebido até precisarmos ler
várias linhas seguidas (para o recurso de apagar o e-mail de teste
automaticamente após o recebimento funcionar).

## E-mail: ponto final que engana o servidor SMTP do REON

Na versão em RGBDS, um teste real contra o `libmobile-bgb` revelou um
bug do lado do servidor de teste do REON: ele decide que a mensagem
acabou (fim do `DATA`) checando se **cada linha, isoladamente**, termina
em ponto final seguido de quebra de linha — não se a linha é *só* um
ponto, como o SMTP de verdade exige. A mensagem de teste deste projeto
terminava a frase do corpo com um ponto final normal, e o servidor
achava que aquela já era a linha de encerramento, uma linha antes da
hora — o resto virava lixo, incluindo o ponto de encerramento de
verdade, que o servidor então tentava rodar como se fosse um comando
digitado (dando `500 command not recognized`).

Olhando o código desta versão em GBDK depois, achamos a mesma frase
exata, com o mesmo ponto final no mesmo lugar — ou seja, o mesmo bug
estava latente aqui também, só que nunca tinha sido pego num teste real
contra o servidor de e-mail de verdade. Corrigido preventivamente, sem
esperar aparecer: tiramos o ponto final da frase de teste, do mesmo
jeito que na versão em RGBDS. Testado de verdade contra o
`libmobile-bgb` logo em seguida (2026-08-30): `250 OK` limpo, sem o
`500 command not recognized` — confirma que a correção funciona aqui
também.

## E-mail: mandava certo, mas o Mobile Trainer não conseguia abrir

Reportando esse mesmo bug pro mantenedor do REON, ele questionou como a
gente sabia o que era "comportamento correto" pro servidor, já que o
teste automatizado deles não roda contra hardware real. Aproveitamos
pra testar de verdade: enviar e receber e-mail usando o próprio Mobile
Trainer (o utilitário oficial que acompanha o Mobile Adapter GB) — algo
que nunca tínhamos feito, só testávamos com o nosso próprio ROM dos dois
lados.

O envio pelo Mobile Trainer funcionou limpo. Só que, ao tentar receber
uma mensagem de teste enviada pelo *nosso* ROM, o Mobile Trainer não
conseguia abri-la — mesmo ela chegando certinho pelo POP3 (o nosso
próprio cliente de teste conseguia ler o mesmo e-mail sem problema). A
diferença: as mensagens de verdade que o Mobile Trainer manda sempre
levam um conjunto de cabeçalhos (`MIME-Version`, `From`, `To`,
`Content-Type: text/plain; charset=iso-2022-jp`) — documentado desde o
início no nosso próprio `docs/dandocs-magb.md`, seção "Mobile Trainer" /
"Email", mas nunca comparado byte a byte contra o que o nosso teste
realmente mandava, que só tinha `Subject:`. Confirmado injetando uma
mensagem de teste sem esses cabeçalhos direto numa caixa de entrada real
e tentando abrir no Mobile Trainer (falhou), depois repetindo com os
cabeçalhos adicionados (funcionou) — sem precisar mexer em nenhum código
ainda, só validar a hipótese primeiro.

Corrigido: o teste de envio agora monta a mensagem com esses mesmos
cabeçalhos, usando o e-mail real lido do adaptador tanto em `From:`
quanto em `To:` (a mensagem sempre é endereçada pra si mesma). O texto
maior estourou o limite de 32 KiB da ROM (sem mapper) por pouco — 14
bytes. Em vez de cortar algo do próprio formato de e-mail recém
validado, encurtamos "FAILED" para "FAIL" numa lista de mensagens de
erro já existentes, de forma uniforme (todas ou nenhuma, pra não deixar
duas mensagens parecidas discordando sobre qual palavra usar).

A validação do formato em si (injetar direto na caixa de entrada, abrir
no Mobile Trainer) confirma que os cabeçalhos certos resolvem o
problema — mas ainda falta rodar o envio de verdade, com esse novo
formato, através desta ROM contra o `libmobile-bgb` de novo (só o
formato anterior, sem cabeçalho, tinha sido confirmado assim).

## Robustez geral e ajustes de usabilidade

Ao longo das versões também fomos ajustando: senha do ISP limitada a 8
caracteres e nunca assumindo um valor padrão inventado; ordem do
teclado de senha (minúsculas, depois maiúsculas, depois números);
efeitos sonoros de seleção/erro/sucesso; e o campo de discagem do P2P
passou a permitir menos de 12 dígitos (para testar números de relay,
tipicamente de 10 dígitos), em vez de sempre forçar 12.

## Reorganização do projeto

Todo o código, em preparação para uma futura versão em RGBDS/assembly
rodando lado a lado com esta em GBDK, foi movido para dentro de uma
pasta própria (`gbdk/`), deixando a raiz do repositório livre para
futuras implementações alternativas.
