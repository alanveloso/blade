# Evidências para a revisão JAAMAS — 5 de novembro de 2026

## Escopo e proveniência

Trabalho apenas no repositório `blade`; `blade-evaluation` não foi modificado.
Branch local: `revision/jaamas-protocol-evidence`, criada a partir de `develop`.
Baseline: `6642b2f41ab0c89e8114e464fa4790a69985d4ad`. Nenhum commit ou push feito.
Os novos resultados correspondem à árvore de trabalho, não a um novo commit.
`evidence/jaamas/manifest.json` registra hashes SHA-256 de fontes e bytecode e a versão do Forge.
O baseline é reconstruído de `git archive` em diretório temporário, sem checkout da branch principal.

Ambiente: Forge 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`;
solc `0.8.26+commit.8a97fa7a.Linux.g++`; optimizer 200, sem via-IR;
EVM **Cancun** explicitamente configurada e passada ao comando de reprodução.
Z3: pacote `z3-solver==4.12.2.0`, instalado isoladamente em `/tmp` para disponibilizar a biblioteca nativa.
Fuzz seed `0x42`, 256 casos por propriedade; invariantes: 48 execuções × profundidade 24,
`fail_on_revert=true`. São campanhas finitas, não provas universais.
O warning de cache de assinaturas Foundry em diretório somente leitura não impede os testes.

## Reprodução

A partir da raiz de `blade`, com Foundry e solc 0.8.26 já disponíveis:

```sh
python3 scripts/jaamas_evidence.py
forge test --match-path 'test/jaamas/*' --fuzz-seed 0x42 -vv
forge coverage --report summary --fuzz-seed 0x42
```

Para incluir CHC e BMC, instalar o solver separadamente e fornecer os caminhos locais:

```sh
python3 -m pip install --target /tmp/blade-jaamas-z3 z3-solver==4.12.2.0
SOLC="$HOME/.local/share/svm/0.8.26/solc-0.8.26" \
Z3_LIB_DIR=/tmp/blade-jaamas-z3/z3/lib python3 scripts/jaamas_evidence.py
```

O script não instala dependências, não usa testnet e não cria commits. Os testes rodam offline.
Não execute `forge coverage` e a reprodução simultaneamente: usam os mesmos diretórios de artefatos.
O status de saída zero do solc significa compilação bem-sucedida, não aprovação de todas as propriedades.
Leia os diagnósticos `formal-*-z3.txt`, inclusive os avisos de recursos não suportados.

## Avaliação inicial e cobertura

A suíte inicial passou: **445 testes, zero falhas**. Já existiam autenticação, correlação de Request,
composição, testes adversariais, invariantes e demonstrações de comportamento em Solidity.
Isso é evidência anterior reaproveitada, não contribuição nova desta revisão.
A suíte final contém **470 testes, zero falhas**, dos quais **25 novos**, sem duplicar testes por herança.
Os logs completos estão em `baseline-tests.txt`, `baseline-seeded-tests.txt`, `final-tests.txt` e `new-tests.txt`.
A tentativa inicial de compor capacidades encontrou um erro de compilação por override de `_reply`;
o erro foi corrigido no contrato de composição e está preservado em `composition-compile-failure.txt`.
Não houve teste de execução reprovado na campanha final.

Lacunas do baseline: não havia terceiro protocolo Subscribe; a cobertura de ordens era amostrada,
não uma enumeração explícita de intercalamentos; os testes de liveness documentavam o bloqueio,
mas não comparavam uma alternativa de entrega individual; não havia o harness SMT desta entrega.
A cobertura instrumentada final está em `coverage.txt` (optimizer desabilitado pelo Foundry,
portanto não usada para gas). Cobertura de branches: Request 38/42; manager Contract Net 24/26;
participante Contract Net 22/27; Subscribe 25/33. Há ramos ainda não cobertos. Percentuais não equivalem
à correção, especialmente para condições de autorização, reentrância e liveness.

## R1.6 — ordens de mensagens

`Interleaving.t.sol` enumera as seis ordens que preservam Agree→Inform dentro de cada uma de duas
sessões Request. Verifica isolamento após cada passo e encerramento. Contract Net varia a ordem
das propostas e exercita a fronteira temporal exata do prazo. Os invariantes existentes continuam
cobrindo sequências adversariais e rollback. O novo handler Subscribe intercala três IDs, atores e
atos válidos/inválidos; verifica concordância de fase, peer/token, isolamento e estado intacto após falha.

Esses são intercalamentos de chamadas completas sobre a EVM local, não execução paralela dentro
de uma transação nem uma simulação de mempool, consenso, reorganizações ou MEV. Para estado,
entradas e ordem fixos, o resultado da EVM é determinístico. Ordens diferentes podem produzir
resultados diferentes: dois compradores disputam estoque limitado em `SolidityPolicy.t.sol`.
O teste de prazo também varia o timestamp, portanto não deve ser descrito como uma permutação
com contexto de bloco idêntico. Chamadas de um teste compartilham seu contexto de execução;
não são recibos de transações independentes em uma rede.

## R2.3 — Subscribe e extensibilidade

`src/core/SubscribeAgent.sol` reutiliza `Agent.handle`, autenticação, política de autorização,
`_send`, validação do envelope e eventos de recebimento. Adiciona armazenamento próprio,
nonce, construtor de continuações e máquina de estados. Os tokens foram **acrescentados** ao fim
dos enums, preservando os valores existentes. Não houve mudança em Agent, RequestAgent,
ContractNetManager ou ContractNetParticipant. Não foi extraída uma abstração comum mais ampla:
seria uma refatoração sem necessidade demonstrada por este experimento.

Subconjunto experimental: Subscribe→Agree explícito→zero ou mais Inform; Refuse na abertura;
Failure e NotUnderstood encerram; Cancel em Active→Cancelling; Inform confirma o cancelamento;
Failure de cancelamento restaura Active. Failure durante Pending também é aceito como término
antecipado. Cancel antes de Agree é rejeitado. Endereços nativos apenas, sem identidade lógica via relay;
sem scheduler, prazo automático ou análise semântica de `content`. A aplicação deve diferenciar
notificação de confirmação conforme a fase: Inform recebido em Cancelling é cancel-done.
Não há fila de notificações antigas nem ordenação por número de sequência nesta variante síncrona.

A especificação [FIPA SC00035H, pp. 60–61 do PDF compilado](https://www.eecis.udel.edu/~decker/courses/886f04/pubs/FIPA-ips.pdf)
prevê Agree opcional e cancelamento em qualquer ponto. Essas possibilidades não estão integralmente
implementadas aqui. Identificadores reutilizáveis com nonce também não representam uma garantia
de conversation-id globalmente único. Não apresentar o experimento como conformidade FIPA completa.

Testes: notificações repetidas; recusa; falha; cancelamento bem-sucedido e malsucedido; atos inválidos;
identidade/token incorretos; repetição de abertura; reutilização com token antigo; falha de entrega;
isolamento de sessões; invariantes; composição Request+Subscribe com o mesmo ID.
`SubscribeComposition.t.sol` demonstra os overrides necessários de `_onInbound` e `_reply` na folha
por herança múltipla Solidity. A aplicação ainda precisa expor comandos autorizados e políticas.
Os wrappers dos testes são deliberadamente permissivos e não são aplicações para implantação.

## R1.1 e R2.1 — políticas de decisão em Solidity

`examples/SolidityPolicyExample.sol` implementa dois agentes. `ReorderAgent.tick()` calcula o déficit
em relação à meta e envia Request ao fornecedor fixo; `InventoryAgent` decide Inform/Refuse segundo
a quantidade e o estoque e atualiza o estoque atomicamente. As decisões e os efeitos são Solidity.
O script Python apenas organiza evidências e nunca decide ações de aplicação.

Os testes cobrem estoque suficiente/insuficiente, quantidade zero, idempotência após atingir a meta,
disputa por estoque e ausência de execução espontânea após avanço de blocos/tempo. Qualquer conta
pode acionar tick, mas não escolher a quantidade nem o fornecedor. Trata-se de um exemplo de
controle reativo com decisões internas, não agentes que se autoagendam nem um mercado com pagamentos.

## R2.5 — resultados formais e limites

`formal/RequestProperties.sol` herda e chama os métodos reais, sem reescrever uma FSM abstrata.
São oito asserções locais em cinco funções, com entradas arbitrárias e armazenamento preparado
explicitamente nos checks de peer/correlação. Isso não modela uma implantação completa nem prova
que todo estado preparado pelo harness é alcançável pela aplicação.

A primeira execução não encontrou `libz3.so.4.12`; a execução posterior com Z3 de fato rodou.
CHC e BMC reportaram **uma asserção safe**: se `_nextInbound(Initiator, phase, act)` retorna Agreed,
então a fase anterior é Requested e o ato é Agree. Ambos reportaram violações nas outras sete
asserções. Os logs completos mostram que solc 0.8.26 não suporta o tipo error nos `revert` com erros
personalizados. BMC também avisa sobre perda de informações de mappings/aliasing.
Portanto, registrar o resultado positivo como **asserção local classificada segura pelo solver sob
sua abstração**, não como certificação formal integral da implementação.

Os candidatos concretos de transição e autenticação foram reproduzidos em
`FormalCounterexamples.t.sol`: todos revertem com o erro esperado antes das asserções.
Isso descarta esses candidatos concretos na EVM; não converte as sete propriedades em provas.
Correlação e peer permanecem não demonstrados pelo SMT nesta configuração; preservação de estado
após chamadas externas falhas, todo o Contract Net, Subscribe, ausência de deadlock e progresso
global não foram formalmente provados. Rollback e autorização possuem evidência de testes.
Não houve bug da implementação demonstrado pelos candidatos formais desta campanha.

A [documentação do SMTChecker 0.8.26](https://docs.soliditylang.org/en/v0.8.26/smtchecker.html)
distingue análise CHC/BMC e abstração de chamadas externas. Não foi habilitado `extCalls=trusted`.
[Halmos](https://github.com/a16z/halmos) é uma alternativa para testes simbólicos de bytecode EVM,
mas não estava instalado nem foi executado. [Echidna](https://github.com/crytic/echidna) é fuzzing de
propriedades, não prova formal, e também não foi executado. Próximo passo: avaliar bytecode simbólico
com limites explícitos ou outro compilador com suporte aos erros, sem misturar essa execução com
o baseline fixo de gas. Não alterar os erros de produção apenas para obter um resultado do solver.

## R2.6 e R3.4 — Contract Net sob participantes maliciosos

Os nove testes existentes de `ContractNetLiveness.t.sol` foram executados. Revert em uma decisão
faz rollback da avaliação inteira, inclusive efeitos nos participantes honestos; um participante
que rejeita toda decisão impede o encerramento. O burner infinito é exercitado com limites de
2M e 25M gas; o burner limitado deixa resíduo insuficiente a 1M e permite execução cara a 20M.
Esses resultados são reproduções com limites concretos, não uma medição de todos os limites possíveis.
Sessões distintas ficam isoladas quando acionadas separadamente; agrupá-las numa chamada propaga rollback.

`experiments/QueuedContractNetManager.sol` é uma alternativa separada que sobrescreve `_send`
para armazenar decisões e usa o `_evaluate` original. O owner escolhe a partição; qualquer conta
pode consultar `pending` e acionar `deliver` para um destinatário. CFP continua síncrono.
Cada entrega é atômica; sua falha restaura a entrada da fila e permite retry. A decisão de um
participante honesto pode ser entregue mesmo após revert/OOG de outro. Os testes completam também
o Inform do participante honesto, não apenas a entrega de AcceptProposal.

A separação muda garantias: decisão gravada não implica recebimento; há estado persistente,
mais chamadas, observabilidade intermediária e custo extra. Um rejeitado malicioso deixa mensagem
pendente mesmo após a limpeza da conversação no manager. O wrapper bloqueia reutilização do ID
nessa condição. Um aceito que não reporta continua impedindo o encerramento global. Não há
coleta de pendências, timeout de aceitos ou recuperação de CFP malicioso. Consulta individual da
decisão evita callback para observar o resultado, mas não atualiza por si só o estado do participante;
a entrega individual preserva essa atualização. Não recomendar substituição automática da versão
síncrona: adotar fila apenas se progresso individual justificar essas novas obrigações.

## R1.4 — gas medido

`baseline-gas.txt` e `final-gas.txt` executam o mesmo `GasRequestTest`, com bytecode compilado sob
as mesmas opções, mesmos cenários e estado inicial. O manifesto guarda os hashes de criação/runtime;
metadados podem mudar com os enums mesmo sem alteração no comportamento. Medidas por `gasleft`
são gas de execução observado no harness, sem contabilização líquida de refunds ou intrinsic gas,
e não preço monetário. Não comparar diretamente esses números com os resultados históricos
`--isolate` em `SECURITY.md`, cuja metodologia é diferente.

Baseline → revisão (gas): primeira abertura Request **137932 → 137932**; abertura seguinte
**106995 → 106995**; Agree **17609 → 17609**; Inform **17742 → 17742**;
total Request/Agree/Inform após aquecimento **142346 → 142346**; Request/Inform síncrono do
exemplo **120987 → 120987**. Não foi observada regressão nesses cenários; isso não demonstra
igualdade de custos para toda entrada ou aplicação.

A comparação síncrono/fila usa dois participantes honestos, um aceito e um rejeitado, mesmas
entradas e snapshot para restaurar o estado antes da segunda variante. Ambas chegam ao mesmo
resultado final após entregas e Inform. O intervalo medido inclui a avaliação e, na fila,
as duas entregas, excluindo abertura/propostas e o Inform final. Contém overhead do wrapper e
memória do harness; a variante em fila tem checagem de owner e armazenamento adicionais.
É um microbenchmark de implementações com resultado funcional equivalente no caso honesto,
**não** equivalência de atomicidade nem estimativa de recibos de três transações distintas.
Resultado: avaliação síncrona **31577 gas**; gravação da fila **81845 gas**; duas entregas
**23778 gas**; fila total **105623 gas**. Os logs estão em `final-gas.txt`. As chamadas compartilham
um teste, com aquecimento e memória próprios do harness; não há conversão para ETH/USD.
A fila mede mais execução e exigiria transações adicionais para isolamento real dos custos entre pagadores.

## Recomendações ao artigo e PR

1. R1.6: separar determinismo por execução de sensibilidade à ordem; citar os seis schedules,
   invariantes finitos e o contraexemplo de disputa por estoque, com seus limites.
2. R2.3: apresentar Subscribe como estudo de extensibilidade de subconjunto explícito, incluindo
   o diff mínimo dos enums, herança, estado novo e restrições do cancelamento/relay.
3. R1.1/R2.1: incluir pseudocódigo das políticas de estoque, resultado de tick e hipótese de ativação
   por transações externas. Evitar alegação de autonomia temporal.
4. R2.5: usar uma seção de tentativa de verificação, informando a asserção solver-safe, sete checks
   não demonstrados e replays. Não chamar os testes ou o harness de prova completa do BLADE.
5. R2.6/R3.4: explicitar atomicidade versus progresso individual e resultados de participantes
   maliciosos; a fila é uma alternativa experimental com pendências residuais.
6. R1.4: publicar manifesto, seed, comandos, bytecode, baseline e gas de execução; não usar preços
   ou testnet como validação nem apresentar cobertura como prova.

O texto do PR está em `docs/JAAMAS_PR.md`. A branch e arquivos estão prontos para revisão local.
Um PR remoto com essas mudanças depende de você criar o commit e publicá-lo; nenhum PR vazio
foi aberto e nenhuma branch principal foi modificada.
