# Memória do MAGB TestSuite no OMM

Este repositório mantém a memória do TestSuite na pasta `memory/`, versionada pelo Git. O OMM registra descobertas e passagens de trabalho; as regras completas continuam nos documentos de cada implementação.

## Uso rápido

Com o OMM instalado, abra o terminal na pasta do projeto:

```sh
omm search "Mobile Adapter protocolo"
omm context "DNS e TCP"
omm remember --kind observation --title "Resultado observado" --content "O que ocorreu e em qual implementação" --source "gbdk/docs/protocol-notes.md" --evidence "gbdk/docs/journal.md: seção relevante"
omm handoff --status in_progress --summary "Onde o trabalho parou" --next "Próxima ação"
```

## Limites importantes

- O repositório tem implementações GBDK e RGBDS separadas. Identifique qual delas está em foco antes de alterar ou testar algo.
- A ROM é um cliente de diagnóstico do protocolo Mobile Adapter GB. Não invente respostas do adaptador nem resultados de rede.
- Build e verificação estática não provam funcionamento em hardware ou emulador. Registre uma execução real com ambiente e versão antes de afirmar resultado de runtime.
- Preserve dúvidas de protocolo como dúvidas até que código, documentação ou evidência de execução as resolva.
- Quando uma tarefa envolver REON, libmobile ou Mobile Adapter GB, use a skill compartilhada `reon-libmobile-expert`, se estiver disponível no agente. Regras e resultados específicos do TestSuite ficam nesta memória e nas fontes locais.
- O índice em `.omm/` é local e reconstruível com `omm rebuild`; os arquivos de `memory/` são a referência versionada.

