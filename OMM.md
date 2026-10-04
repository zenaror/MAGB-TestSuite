# Memória do MAGB TestSuite na OMM

A memória compartilhada deste projeto fica na **OMM central**. O agente a consulta pelo MCP, no escopo `magb-testsuite`; o escopo `global` guarda o conhecimento de domínio de REON, libmobile e Mobile Adapter GB. O backup da OMM é o repositório de dados `ai-omm-backup`, não este repositório.

Como consultar e quando registrar: veja a seção "Memória" do [`AGENTS.md`](AGENTS.md).

## A pasta `memory/` deste repositório é legado

A pasta `memory/` foi criada em 2026-10-01 por `omm init`, quando a memória ficava dentro de cada projeto. **Não grave nela.** Também não rode `omm remember` ou `omm handoff` nesta pasta: isso criaria uma segunda memória fora da OMM central.

As 4 anotações da pasta foram copiadas para a OMM central em 2026-10-04, no escopo `magb-testsuite`, com o ID original na origem:

| Anotação | ID na OMM central |
| --- | --- |
| Duas implementações | `296ce6d2` |
| Alvo apenas GBC | `47a7844e` |
| Build ≠ runtime | `95a408bb` |
| Preservar incerteza | `8718cdb3` |

Remover a pasta depende de uma decisão do Rafael.

O índice `.omm/` é local, pode ser recriado e fica fora do Git.
