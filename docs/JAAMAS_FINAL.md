# Validação final da camada de protocolos do BLADE

**Classificação: PRONTO PARA REVISÃO FINAL.** Isso significa pronto para avaliação do autor,
não aprovação de publicação, auditoria de produção ou conformidade integral FIPA. Não restaram
falhas bloqueantes nos experimentos delimitados abaixo. As limitações de progresso global,
identificação de sessões Contract Net e abrangência formal são explícitas.

## Escopo e preservação

Branch local `revision/jaamas-protocol-evidence`; HEAD permanece
`6642b2f41ab0c89e8114e464fa4790a69985d4ad`. Sem commit, push, PR ou merge.
Somente `blade` foi trabalhado. O relatório anterior `JAAMAS_REVISION.md` é um registro histórico,
superado por este relatório onde houver diferença. `JAAMAS_PR.md` permanece apenas um texto
anterior, sem ação de publicação autorizada nesta rodada.

A árvore anterior foi preservada em `evidence/jaamas-final/prior-work.tar.gz` antes das novas
edições, com hashes em `prior-hashes.json`. Todos os arquivos antigos de `evidence/jaamas/`
foram conferidos byte a byte por SHA-256: **22 arquivos preservados, nenhum alterado**. Os resultados novos estão
exclusivamente em `evidence/jaamas-final/`. O manifesto final distingue fontes, artefatos,
versões e resultados; não associa a árvore modificada a um commit inexistente.

## Revisão técnica e correções demonstradas

A revisão incluiu `Agent`, Request, Contract Net manager/participant, Subscribe, fila experimental,
composição e políticas de estoque. Foram examinados autenticação antes dos efeitos, validação
de peer/token, ordem de efeitos e callbacks, cleanup, reutilização de IDs e rollback.

Quatro testes falharam na implementação anterior e passaram após correção
(`regressions-before.txt`, `regressions-after.txt`):

1. **Subscribe: correlação do cancelamento.** Um Inform com o token de uma notificação anterior
   podia ser interpretado como confirmação do cancelamento. Agora Cancel recebe um token novo
   gerado pelo core; `inReplyTo` referencia a assinatura e `replyWith` identifica o cancelamento.
   A confirmação deve responder ao novo token. Tentativas de cancelamento após Failure usam
   tokens novos. Mensagens atrasadas da assinatura ou de outro cancelamento não encerram a sessão.
2. **Contract Net: identidade lógica na abertura.** O participante aceitava CFP via trusted relay
   com `logicalSender != 0`, mas recusava continuações dessa identidade. Agora rejeita a abertura
   antes de escrever estado. O protocolo já era nativo; a mudança remove uma sessão inconsistente,
   preservando o comportamento de mensagens nativas. Apenas duas linhas funcionais foram
   acrescentadas ao módulo existente, sem mudança de layout ou assinatura.
3. **Fila: conclusão antes da entrega.** O estado Accepted do manager era gravado na avaliação,
   permitindo Inform/Failure enquanto AcceptProposal ainda estava na fila. Esses atos agora
   são rejeitados até o início da entrega. A entrada é removida antes do callback, portanto
   conclusão síncrona durante a entrega continua válida e foi testada.
4. **Fila: aceitação obsoleta após desistência.** NotUnderstood limpava a sessão, mas deixava a
   aceitação na fila para sempre. A desistência válida agora remove essa entrada, atualiza a
   contagem e emite evento. O teste abre uma nova sessão após o cleanup.

Não foi alterado `RequestAgent` nem o manager Contract Net síncrono. Request já valida peer,
token e transição; suas propriedades foram ampliadas por verificação simbólica. O token não
é segredo: é uma referência de correlação, não autenticação criptográfica do remetente.

## Subscribe: subconjunto final e extensibilidade

O subconjunto agora permite Subscribe seguido de Agree explícito **ou Inform com acordo
implícito**; notificações repetidas enquanto Active; recusa/falha; NotUnderstood; cancelamento
tanto em Pending quanto em Active; confirmação de cancelamento; Failure de cancelamento com
restauração da fase anterior. Isso evita transformar uma abertura ainda não aceita em Active
quando seu cancelamento falha. `resumePhase` e `cancelToken` foram acrescentados ao estado.

Reutiliza envelope `Message`, `Agent.handle`, `_authenticate`, `_authorizeInbound`, `_send`,
validação básica e eventos de recebimento. Acrescenta FSM, estado por assinatura, nonce e
construção de continuações. Os enums ganharam valores ao final, sem renumerar os anteriores.
A folha de composição declara os overrides Solidity de `_onInbound` e `_reply`; Request e
Subscribe podem usar o mesmo ID em namespaces separados. Não houve extração de uma nova
infraestrutura genérica nem substituição do transporte.

A [especificação FIPA SC00035H](https://www.eecis.udel.edu/~decker/courses/886f04/pubs/FIPA-ips.pdf)
permite acordo opcional, notificações e o metaprotocolo de cancelamento. O experimento continua
restrito: transporte nativo síncrono, sem linguagem de conteúdo/ontologia, relay lógico,
agendamento, expiração automática, fila de notificações ou número de sequência por notificação.
Failure em Pending é uma extensão explícita de término antecipado. O conteúdo das notificações
é responsabilidade da aplicação; mensagens repetidas dentro de uma assinatura não são deduplicadas.
Nonce garante novos tokens para comandos do core local, não para um iniciador externo arbitrário.
Não há declaração de conformidade FIPA integral.

## Testes e cobertura de riscos

Foram executadas duas campanhas completas, seeds `0x42` e `0x1234`, cada uma com **488 testes
aprovados, zero falhas e zero skips**. Fuzzing: 1.024 casos por propriedade; invariantes: 128 runs,
profundidade 64. Isso corresponde a 8.192 chamadas por campanha de cada invariante, não a uma
exploração exaustiva de todas as execuções. O baseline tinha 445 testes; a rodada anterior 470.
Os testes simbólicos `check_*` são contabilizados separadamente, nunca somados aos testes Foundry.

Cobertura adicional: seis intercalamentos Request; ordem de propostas e fronteira de deadline;
três IDs nos invariantes Subscribe; notificações antigas e cancelamentos repetidos; envelopes
Cancel inválidos; rejeição de relay lógico; mensagens sem sessão; sessões independentes;
callbacks aninhados Subscribe→Inform→Cancel→Inform; rollback integral se o callback falha;
reentrada em entrega da fila; ordem de entrega de rejeições; owner da fila; desistência antes
da entrega; CFP malicioso ainda síncrono; ausência de execução espontânea das políticas Solidity.
A composição e as políticas de estoque existentes voltaram a passar.

Os ramos não cobertos foram examinados com LCOV. Foram priorizados os guardas de correlação
Cancel, notificações sem sessão, identidade lógica e RejectProposal antes de Propose. Guardas
redundantes de dispatch e checks defensivos inalcançáveis pelas entradas públicas normais não
foram exercitados artificialmente. O check de fila duplicada, por exemplo, protege uma condição
já impedida pela FSM/partição na interface pública. Não se reivindica cobertura de 100%.
O relatório de cobertura desabilita otimização e inclui harnesses; seu percentual agregado não
mede a segurança do core nem serve como evidência de gas. Consulte `coverage-final.txt` e
`coverage.lcov` (esta última captura a inspeção que orientou os testes adicionais).

## Verificação sobre bytecode e limites das provas

Halmos **0.3.3**, Z3 **4.12.6**, Solidity **0.8.26**, optimizer 200, sem via-IR, Cancun.
As [capacidades do Halmos](https://github.com/a16z/halmos) foram usadas em harnesses que implantam
os contratos reais e executam o bytecode, sem substituir código de produção por um modelo abstrato.
Configuração: limite de loop 4; timeout de asserção 30 s; nenhum loop truncado nos resultados finais.
Todos os caminhos finais das 11 obrigações encerraram sem erro de solver ou estado bloqueado:

- Request: autenticação nativa/relay para caller e identidade lógica simbólicos; peer/token e
  isolamento de uma segunda sessão; conjunto permitido de atos após Requested para todo uint8.
- Contract Net: somente o participante convidado pode propor; mensagem para outro ID não altera
  a conversação existente.
- Subscribe: apenas o token do cancelamento confirma seu término; falha de entrega preserva
  ambos os estados para todos os atos do enum; falha de cancelamento em Pending restaura Pending.
- Fila: conclusão prematura rejeitada; desistência limpa a fila; entrega para peer não pendente
  não muda contagem ou sessão.

São **propriedades simbólicas do bytecode para estados iniciais e sequências definidos no harness**,
não uma prova indutiva de todos os históricos, liveness global, código arbitrário de terceiros,
consenso, reorgs, mempool ou semântica econômica das aplicações. Endereços/tokens simbólicos são
quantificados nas funções correspondentes; estrutura/tamanho das mensagens são fixados pelos
harnesses. Ausência de limites atingidos nesses caminhos não estende a prova a sequências ausentes.

O controle negativo removeu a checagem de correlação Request em **cópia temporária**. Halmos encontrou
um contraexemplo e reprovou `check_peerTokenIsolation`; `halmos-negative-control.json/.txt` preservam
o modelo. Isso confirma sensibilidade a esse defeito e não é falha da árvore final. Os arquivos
`halmos-final.json/.txt` e `halmos-final-artifact-hashes.json` registram a execução positiva.
Artefatos simbólicos são recompilados em diretórios isolados: uma tentativa inicial revelou avisos
por cache compartilhado sem AST; ela foi substituída por compilação limpa, preservando seus logs.

SMTChecker/CHC/BMC com Z3 4.12.2 foram reexecutados: uma asserção local solver-safe e sete não
estabelecidas, com as mesmas limitações de custom errors e aliasing. Isso continua separado dos
11 resultados Halmos. Replays concretos dos candidatos anteriores continuam passando; warnings
do SMTChecker não foram classificados como vulnerabilidades sem reprodução.

## Contract Net: garantias, recuperação e recomendação

A implementação síncrona mantém atomicidade da avaliação e entrega de todas as decisões na mesma
transação. Um destinatário que reverte ou esgota gas pode impedir a avaliação inteira. Callbacks
válidos de conclusão são suportados; callbacks com transição indevida são rejeitados. O atacante
que recusa toda decisão ou nunca reporta após aceitação continua impedindo cleanup global.

A fila separa decisão e entrega: permite progresso de um participante honesto após falha de outro,
consulta pública da decisão e retry de entrega. Há estado persistente, autorização de avaliação,
mais transações e um intervalo em que manager e participante têm fases diferentes. A entrega é
atômica individualmente; falha restaura a entrada. Reentrar na mesma entrega encontra a entrada
removida; conclusão durante callback é válida. Se uma aplicação agrupar entregas, reintroduz o
acoplamento por rollback dessa transação. Não se promete isolamento entre callbacks arbitrários
que a própria aplicação decida agrupar.

Limitações reproduzidas: CFP ainda pode reverter tudo; rejeitado que recusa decisão mantém fila
pendente e bloqueia reutilização do ID; aceito que não conclui mantém sessão viva; não há garbage
collection unilateral nem timeout de aceitos. Silenciosos CFPED podem expirar no participante,
mas isso não elimina automaticamente o slot do manager. Consulta da decisão sozinha não altera
estado do participante. A recuperação desses casos exige nova política de aplicação/protocolo.

**Recomendação:** manter o core síncrono como padrão e a fila como **alternativa experimental
opcional**, sem integração automática na API padrão. A fila é útil quando progresso individual
justifica custos e pendências; não justifica uma mudança global de arquitetura com estes dados.

**Limitação de correlação Contract Net:** o core associa identidade nativa, ID e slot, sem nonce
por instância. Um peer autorizado que envia um Propose com token antigo em um ID reutilizado é
aceito (`test_contractNetSamePeerStaleTokenNotEnforcedOnReusedId`). Não é uma falsificação de caller:
é uma mensagem do peer autorizado, mas não há proteção de instância equivalente à de Request.
Para fluxos sujeitos a mensagens atrasadas, as aplicações devem usar IDs novos. Impor tokens
obrigatórios mudaria os envelopes/contratos existentes e foi deliberadamente excluído desta
correção compatível. Essa ausência deve aparecer no artigo, nunca como garantia implementada.

A autorização de **admissão** de novas conversações pertence a `_authorizeInbound`; a política
default é permissiva. Os wrappers de teste não devem ser implantados como serviços com controle
de acesso. Políticas de estoque são demonstrações reativas sem ativos financeiros, não uma
aplicação econômica segura para produção.

## Gas: comparação controlada e resultados

Ambiente exclusivamente local. Foundry/Anvil/Cast 1.7.1; Solidity 0.8.26; Cancun explícito;
optimizer 200, sem via-IR. Dez cenários em Anvil, cadeia 31337, estado restaurado por snapshots,
endereços determinísticos, timestamps fixados por transação, entradas e ordem registradas.
`txgas.json` contém calldata, recibos, status e hashes de bytecode. A repetição dos dez cenários confirmou gasUsed, calldata e hashes de bytecode idênticos
à primeira execução bem-sucedida (`txgas-first.json` versus `txgas.json`). Deployments são registrados
separadamente e excluídos dos totais de operação abaixo. Não há preços, ETH/USD, testnets ou L2.

Três referências: commit original; árvore experimental preservada da rodada anterior; árvore final.
Request e Contract Net síncrono foram medidos no commit original e nas duas árvores. Subscribe/fila
não existiam no commit original e só são comparados entre a árvore anterior e a final.

**Recibos de transações (`gasUsed`, incluindo intrinsic gas e efeitos de refunds):**

- Request, duas chamadas: **253.266 → 253.266**, delta **0 (0%)**. Primeira chamada 133.473;
  seguinte 119.793. Cada chamada é uma transação nova, com contas frias no início.
- Ciclo Contract Net síncrono, cinco transações: **392.297 → 392.413**, delta **+116 (+0,0296%)**.
  CFP para dois participantes e avaliação acresceram 58 gas cada; propostas/Inform não mudaram.
- Ciclo com fila, sete transações: **517.904 → 525.208**, delta **+7.304 (+1,4103%)**.
- Subscribe completo, cinco transações: **354.028 → 484.919**, delta **+130.891 (+36,9719%)**.
  Cancel em particular: **53.824 → 148.764**, delta **+94.940 (+176,3897%)**. O custo aumenta
  por nonce e estado de correlação/restauração; não é apresentado como otimização de gas.
- Fila final versus síncrono final, mesmo resultado honesto: **+132.795 (+33,8406%)**, com duas
  transações extras. A equivalência é do resultado após todas as entregas, não de atomicidade.

**Gas de execução por `gasleft`, sem intrinsic gas/refund líquido:** Request manteve os valores
anteriores. No novo harness comum, CFP Contract Net 150.993→151.051; avaliação 30.849→30.907.
Subscribe: abertura 126.616→135.915; Agree 16.825→17.810; notificação 15.013→15.958;
Cancel 14.875→96.915; confirmação 15.213→16.816. Valores absolutos, deltas e percentuais completos
estão em `gas-comparison.json`.

O microbenchmark antigo da fila mostra avaliação 81.845→77.845 e total 105.623→101.681.
**Isso não é uma melhoria demonstrada do custo total:** a nova checagem consulta `pending`
durante as propostas, aquecendo slots antes do intervalo medido. As propostas estão fora desse
intervalo no harness. Nos recibos, avaliação permanece 114.429 e o ciclo ficou mais caro.
Esta discrepância é explicitada em vez de selecionar apenas o número favorável.

A seleção antiga de `ExampleParticipant` por nome curto era ambígua entre dois arquivos.
O manifesto histórico não deve ser usado para identificar esse artefato isoladamente; os testes
de gas importavam a classe correta. Os scripts atuais selecionam arquivo e nome completos.
A nova campanha guarda runtime efetivamente implantado e evita essa ambiguidade.

## Reprodução e arquivos

Dependências: Foundry 1.7.1 e solc 0.8.26 em cache; Python 3.12. Halmos e suas dependências estão
fixados em `evidence/jaamas-final/halmos-requirements.txt`; use venv separado. O cache obrigatório
`~/.halmos/solvers` deve existir. Z3 do Halmos é 4.12.6; o SMTChecker usa a biblioteca 4.12.2.

Executar da raiz de `blade`, **sequencialmente**, sem concorrência de builds:

```sh
python3 scripts/jaamas_validate.py
HALMOS=/tmp/blade-halmos/bin/halmos HALMOS_Z3=/tmp/blade-halmos/bin/z3 \
  python3 scripts/jaamas_symbolic.py
python3 scripts/jaamas_txgas.py
SOLC="$HOME/.local/share/svm/0.8.26/solc-0.8.26" \
Z3_LIB_DIR=/tmp/blade-jaamas-z3/z3/lib python3 scripts/jaamas_evidence.py
python3 scripts/jaamas_manifest.py
```

O script de recibos abre apenas `127.0.0.1:18547` e encerra o Anvil ao finalizar ou falhar.
A primeira execução precisou corrigir a espera pelo recibo e a seleção de artefatos homônimos;
esses erros de infraestrutura não são resultados científicos positivos. Logs preservados.
O script antigo de evidências agora escreve por padrão em `jaamas-final/reproduction`, mantendo
`evidence/jaamas` intacto. Backups/arquivos temporários não envolvem commits.

Arquivos funcionais novos/alterados em relação ao commit: `SubscribeAgent.sol`, dois enums,
`ContractNetParticipant.sol`, `SolidityPolicyExample.sol` e `QueuedContractNetManager.sol`.
Testes/harnesses: `test/jaamas/*`, `test/symbolic/ProtocolSymbolic.t.sol`, `formal/RequestProperties.sol`.
Automação: `scripts/jaamas_*.py`. Relatórios: este documento e `JAAMAS_RESPONSES.md`.
`manifest-final.json` lista hashes completos; `changes-vs-prior.json` distingue correções desta
rodada de implementações anteriores. As fontes históricas preservadas permitem reconstruir a
comparação sem depender de um commit da árvore experimental.

A revisão final do diff não encontrou alteração da branch principal, publicação, mudança de
layout do core existente ou modificação de resultados antigos. O próximo passo é a revisão
científica e técnica pelo autor; não há ação de publicação implícita nesta classificação.
