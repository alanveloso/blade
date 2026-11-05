# JAAMAS: evidências de protocolos, Subscribe experimental e políticas Solidity

A revisão adiciona evidência reproduzível sobre ordenação, extensibilidade e falhas de entrega
sem substituir Request ou Contract Net. O baseline é `6642b2f41ab0c89e8114e464fa4790a69985d4ad`.

Inclui Subscribe nativo experimental com notificações e cancelamento confirmado; demonstração
reativa de políticas de estoque inteiramente em Solidity; seis intercalamentos Request;
propriedades/invariantes; harness SMTChecker com replays de candidatos; e um manager experimental
que grava decisões e permite entregá-las individualmente. A fila isola falhas de destinatários,
mas mantém pendências e não garante encerramento global. Somente os dois enums existentes foram
alterados, com novos valores ao final; os módulos atuais de transporte/Request/Contract Net permanecem intactos.

Validação executada: baseline 445/445; revisão 470/470 (25 testes novos), zero falhas/skips;
fuzz seed 0x42; invariantes 48×24; cobertura executada. Forge 1.7.1, solc 0.8.26, Cancun,
optimizer 200, sem via-IR. Microbenchmarks Request iguais ao baseline; avaliação síncrona
31577 gas versus fila+entregas 105623 gas no cenário honesto definido, sem intrinsic gas/refunds.

CHC/BMC com Z3 4.12.2: uma asserção local solver-safe e sete não demonstradas, com recursos
não suportados (custom errors; aliasing em BMC). Os candidatos concretos de autenticação/transição
revertem na EVM. Não se reivindica prova formal integral, conformidade FIPA completa, autonomia
de execução dos contratos ou equivalência de atomicidade entre fila e entrega síncrona.

Reprodução: `python3 scripts/jaamas_evidence.py`; para checks formais, definir `SOLC` e `Z3_LIB_DIR`
conforme `docs/JAAMAS_REVISION.md`. Manifesto e saídas brutas em `evidence/jaamas/`.

Branch local: `revision/jaamas-protocol-evidence`. Este arquivo é a descrição preparada para o PR;
o PR remoto depende do commit e push que serão feitos pelo autor. Nenhum commit ou push foi criado
pelo assistente. Selecionar a base remota apropriada após revisar a integração com `develop`.
