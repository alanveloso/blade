# Encerramento da auditoria técnica — BLADE / JAAMAS

**Conclusão: tecnicamente pronto para consolidação no artigo, no escopo e sob as hipóteses
explicitadas neste relatório.** Não há autorização de publicação. A versão atual **não oferece
proteção de instância em Contract Net quando `conversationId` é reutilizado**. Essa limitação
foi reproduzida, teve seu impacto ampliado e suas alternativas foram medidas. Não pode ser
omitida nem substituída por uma alegação de segurança geral do protocolo.

Branch: `revision/jaamas-protocol-evidence`. HEAD:
`6642b2f41ab0c89e8114e464fa4790a69985d4ad`. Sem commit, push, PR ou merge.
O escopo continua sendo a camada de protocolos de interação do BLADE, integrante de um framework
de agentes na blockchain. Não se reivindica superioridade, pioneirismo ou autonomia de execução.

## 1. Correlação Contract Net: reprodução e impacto

Os novos testes `CorrelationAudit.t.sol` executam o seguinte sem `vm.prank` nos dois casos de
reprodução principal: abrem uma conversação, encerram-na, reutilizam o ID e entregam um envelope
da instância anterior através de `ExposedContractNetParticipant.respond` e do manager real.

- Uma proposta antiga é aceita na nova instância quando o slot está Invited. Ambos os endpoints
  avançam para Proposed, mesmo com outro `replyWith` na abertura nova.
- Depois de uma nova proposta ser aceita, um Inform antigo é aceito e apaga os estados de ambas
  as pontas, encerrando prematuramente a nova instância.

Portanto, o impacto não se limita a mensagens de diagnóstico: conteúdo antigo pode alimentar a
política de seleção e um resultado antigo pode sinalizar conclusão de um trabalho novo. Os testes
comprovam transições/cleanup indevidos em relação à intenção de separar instâncias; não mediram
perda financeira nem pressupõem uma política de pagamento inexistente no experimento.

Não se trata de replay de uma transação Ethereum assinada, nem falsificação de `msg.sender`.
É reenvio de um **envelope de aplicação** por um participante autorizado, em uma nova chamada.
Os checks atuais de identidade, ID e fase passam porque esses valores voltaram a ser válidos.
Um atacante sem a identidade do participante continua bloqueado. Um participante malicioso que
conhece o ID/token atual também pode mentir no conteúdo; nenhuma das alternativas autentica a
veracidade semântica do resultado da aplicação.

## 2. Alternativas avaliadas antes de qualquer mudança definitiva

Foi criado somente um conjunto isolado de comparadores em
`experiments/audit/ContractNetAlternatives.sol`. Não foi integrado ao core, à fila ou aos exemplos.
Todos os managers comparados têm a mesma política de owner. As alternativas não são apresentadas
como implementações de produção nem como resultados de otimização máxima.

**Tokens por instância.** `AuditTokenManager` gera um token usando chain ID, endereço, ID e nonce.
O participante guarda o token; continuações do participante usam `inReplyTo`, decisões do manager
usam `replyWith`. São verificados recebimento e envio, incluindo tentativas diretas de contornar
o wrapper do participante. O teste reutiliza o ID e rejeita tokens antigos/errados em ambas as
direções. O fluxo honesto Propose→Accept→Inform conclui e limpa os tokens.

A migração não é transparente: o manager atual aceita `replyWith` escolhido pela aplicação e
não gera tokens; suas decisões não carregam o token original. Participantes, wrappers, callbacks,
agentes externos, testes e resultados guardados precisariam mudar. Exigir token apenas em uma
ponta deixa a outra vulnerável. Aceitar automaticamente mensagens sem token preservaria uma via
sem proteção, portanto não equivale à correção estrita.

O protótipo também demonstra trabalho de integração adicional: preserva o token durante callbacks
de avaliação com um marcador `busy`, restringindo reabertura reentrante do mesmo ID. A expiração
herdada do participante limpa `_cn`, mas não o mapping auxiliar de tokens; um teste preserva e
expõe esse resíduo. Uma implementação integrada precisaria de um hook de cleanup/alteração da
expiração. Na fila, tokens teriam de acompanhar cada decisão pendente, inclusive após cleanup
no manager; simplesmente copiar a solução síncrona não basta. Esses pontos impedem promover o
protótipo como correção definitiva nesta rodada.

**IDs externos com proibição de reutilização.** `AuditUniqueManager` guarda `used[id]` antes do
CFP e nunca o apaga. A tentativa de reutilização reverte; envelopes destinados ao ID encerrado
não afetam o próximo ID. Não muda o envelope nem o participante. Custa um slot permanente por
ID usado, exige namespace que evite colisões entre managers e muda o comportamento de aberturas
que antes aceitavam reutilização. Uma convenção escrita, sem enforcement na aplicação, não tem
a mesma garantia desse wrapper.

**IDs gerados por nonce.** `AuditGeneratedIdManager` deriva um ID novo de chain ID, endereço do
manager e contador monotônico. O estado de unicidade é um único contador persistente; não há
um tombstone por conversa. A abertura retorna/emite o ID escolhido e não permite contornar a
política passando um ID próprio. Os participantes e envelopes do core permanecem iguais, mas a
API e o fluxo da aplicação para descobrir o ID mudam. A unicidade pressupõe resistência a colisões
do hash e execução no domínio da implantação/cadeia considerada, não todos os históricos de forks.

A especificação [FIPA Contract Net SC00029H, §1.1, linhas 86–89](https://www.eecis.udel.edu/~decker/courses/886f04/pubs/FIPA-ips.pdf)
prevê conversation-id não nulo e globalmente único atribuído pelo iniciador. Usar uma nova
identidade de conversação para cada instância é, portanto, coerente com esse modelo; isso não
implica conformidade integral do restante da implementação.

**Recomendação:** para novas integrações, preferir IDs gerados por nonce na folha de aplicação,
separando um eventual identificador de negócio do identificador da conversação. Para APIs que
precisam de IDs escolhidos externamente, impor não reutilização com namespace adequado. Reservar
uma versão com tokens estritos para o requisito real de reutilizar o mesmo conversationId,
mediante migração explícita das duas pontas e da fila.

**Decisão sobre o core:** nenhuma dessas alternativas satisfaz simultaneamente proteção estrita
e compatibilidade transparente com toda a semântica existente. Conforme o pedido de avaliar antes
de alterar a implementação definitiva, **não modifiquei o core nesta rodada**. Isso não significa
que o problema foi corrigido no modo legado: ele permanece, sob a pré-condição de não reutilizar
IDs quando se exige separação de mensagens atrasadas. Os protótipos são evidência comparativa,
não uma mudança silenciosa de protocolo.

## 3. Auditoria das demais alterações

O diff e as fontes da árvore anterior foram confrontados com seus hashes preservados.
`RequestAgent` não foi alterado durante esta revisão JAAMAS; sua proteção de tokens já estava
no commit usado como baseline. Essa proteção foi testada/verificada, não deve ser creditada como
uma implementação nova desta rodada. As quatro correções da rodada anterior continuam válidas:
token próprio de cancelamento Subscribe; rejeição de CFP lógico incompatível; bloqueio de conclusão
antes da entrega na fila; retirada da aceitação pendente após NotUnderstood.

- **Request:** peer/token, transições, nonce, cleanup e rollback mantidos; sem novo defeito
  demonstrado. A proteção de correlação não é prova da honestidade do conteúdo do peer.
- **Contract Net:** checks nativos e fases mantidos; a ausência de separação entre instâncias
  reutilizadas é confirmada, não resolvida por autenticação de caller nem pelo deadline.
- **Subscribe:** abertura implícita/explícita, token separado de cancelamento, restauração de
  Pending/Active e ordem efeitos→chamadas revisadas. As provas e testes existentes foram repetidos.
  Não há deduplicação de todas as notificações, relay lógico ou agendamento automático.
- **Políticas Solidity:** decisões continuam inteiramente em contratos e reativas a transações.
  Estoque é uma demonstração permissiva sem pagamentos. Não é um sistema econômico auditado;
  o fornecedor fixo e a política de admissão são hipóteses de aplicação.
- **Fila experimental:** a entrada é removida antes da entrega e restaurada em caso de revert;
  conclusão durante callback permanece válida. Persistem CFP síncrono vulnerável a revert,
  rejeitados que deixam decisões pendentes e aceitos que nunca concluem. Agrupar entregas novamente
  acopla rollback. Não há motivo demonstrado para substituir o core síncrono.
- **Composição:** dispatch e overrides mantidos; namespaces de estado separados. Wrappers de
  teste permissivos não substituem `_authorizeInbound`/controle de comandos nas aplicações.

Não foram introduzidas funcionalidades adicionais de produção. As adições desta rodada são
reproduções, comparadores, obrigações simbólicas e infraestrutura de evidência. A análise de
cobertura priorizou caminhos de segurança e os novos cenários, não um percentual agregado.

## 4. Reprodução de encerramento

Duas campanhas completas: **497 testes aprovados em cada campanha, zero falhas e zero skips**
(44 suites), seeds `0x42` e `0x1234`. Fuzzing: 1.024 casos por propriedade; invariantes: 128 runs,
profundidade 64. Nove testes foram acrescentados aos 488 anteriores. Testes que confirmam uma
limitação conhecida usam assertions dessa limitação: seu PASS não significa que ela foi corrigida.
Coverage executada separadamente, com otimização desabilitada pelo Foundry; não usada para gas.

**Halmos: 14 obrigações aprovadas**, as 11 anteriores e três novas: proibição de reabrir ID usado
no wrapper único, rejeição de token errado pelo participante estrito e pelo manager estrito.
São verificações sobre bytecode real em setups/seqüências delimitados, com entradas simbólicas.
Nenhum caminho bloqueado ou limite de loop atingido foi reportado nos resultados finais. O controle
negativo em cópia temporária sem a guarda de token Request continuou produzindo um contraexemplo.
Não se somam esses checks à contagem Foundry nem se infere prova indutiva de todos os históricos,
progresso global, conteúdo honesto, protocolos externos ou toda a implementação dos protótipos.

SMTChecker CHC/BMC foram reexecutados: uma asserção local solver-safe e sete não estabelecidas,
com limitações de custom errors/aliasing. Isso permanece distinto das provas sobre bytecode;
warnings do SMT não foram convertidos em defeitos concretos sem reprodução.

Versões: Forge/Anvil/Cast 1.7.1; solc 0.8.26+commit.8a97fa7a; optimizer 200, sem via-IR;
EVM Cancun. Halmos 0.3.3/Z3 4.12.6 para bytecode; Z3 4.12.2 para SMTChecker.
As versões, configurações e hashes ficam em `evidence/jaamas-close/`.

## 5. Gas atualizado

Recibos locais Anvil, chain ID 31337, snapshots de estado, timestamps controlados e calldata
registrada. Foram executados e repetidos 12 cenários com gas, calldata e hashes de bytecode idênticos: quatro anteriores, quatro atuais equivalentes e quatro
alternativas. Deployments ficam fora dos totais operacionais. Cada ciclo das alternativas possui
um participante e quatro transações (CFP, Propose, Evaluate, Inform); os cenários antigos com fila
usam dois participantes e **não** são comparados numericamente com esse ciclo de um participante.

Os quatro cenários existentes mantiveram exatamente os resultados da rodada anterior: Request,
duas chamadas, **253.266 gas**; Contract Net síncrono, cinco transações, **392.413**; fila, sete
transações, **525.208**; Subscribe, cinco transações, **484.919**. Delta desta rodada: **0 (0%)**.
Isso corresponde à decisão de não alterar a implementação definitiva.

Alternativas, `gasUsed` total por ciclo, primeiro → segundo ciclo:

- Nativo sem política adicional: **264.186 → 264.254**.
- IDs externos não reutilizáveis: **286.545 → 286.612**. Incrementos **22.359 (8,4634%)** e
  **22.358 (8,4608%)** sobre o nativo correspondente; armazenamento cresce por ID.
- IDs gerados por nonce: **287.606 → 270.506**. Incrementos **23.420 (8,8650%)** e
  **6.252 (2,3659%)**; o contador já inicializado reduz o custo do segundo ciclo.
- Tokens estritos: **368.363 → 351.370**. Incrementos **104.177 (39,4332%)** e
  **87.116 (32,9668%)**; incluem o estado extra e as proteções do protótipo por herança.

Esses custos são dos **protótipos medidos**, não um limite inferior para toda implementação com
tokens. A versão com tokens muda as garantias e os envelopes, portanto a equivalência é somente
do resultado honesto após conclusão. IDs/token gerados obrigam diferenças na calldata; ela está
registrada. Para chamadas sem criação e sem access list, o relatório separa intrinsic gas
(21.000 mais 4/16 por byte de calldata) de `gasUsed - intrinsic`, que ainda é execução **líquida
de refunds**, não execução bruta. Deployments não usam essa fórmula simplificada.

Os microbenchmarks `gasleft` também foram repetidos: nativo 138.060/135.570; não reutilização
157.914/157.924; geração de ID 161.519/137.129; tokens 255.320/233.430. São chamadas em um único
teste, com aquecimento, overhead do harness e sem intrinsic gas/refund líquido. Não misturar esses
valores com recibos. Não foram usados preços monetários, testnets ou características de L2.

## 6. Evidências e relação com os revisores

- **R1.6:** intercalamento, isolamento e agora duas reproduções reais de mensagem antiga em ID
  reutilizado. Atendido parcialmente; determinismo não implica independência da ordem nem
  proteção de instância no Contract Net legado. Evidência: suites originais e `CorrelationAuditTest`.
- **R2.3:** Subscribe e composição permanecem executados; subconjunto e restrições continuam
  explícitos. Atendido parcialmente, sem conformidade FIPA completa.
- **R1.1/R2.1:** políticas Solidity e ativação externa revalidadas. Demonstração atendida no seu
  escopo; não reivindicar autoagendamento. Evidência: `SolidityPolicyTest`.
- **R2.5:** 14 obrigações Halmos e controle negativo; SMT inconclusivo separado. Atendido parcialmente,
  sem prova completa da implementação nem liveness universal.
- **R2.6/R3.4:** falhas/reentrância da fila e core reexecutadas; impacto da correlação ampliado;
  recuperação global ainda condicional. Atendido parcialmente.
- **R1.4:** cenário local fixado, recibos e execução separados, comparadores e deltas medidos.
  Atendido para estes cenários; não implica curva de escala ou superioridade geral.

Para o manuscrito: substituir qualquer alegação de proteção de instância Contract Net por uma
hipótese explícita de IDs novos; explicar o contraexemplo de Inform antigo; apresentar a geração
por nonce como alternativa avaliada, não já incorporada ao core; conservar as limitações da fila
e as condições das provas. As respostas sugeridas em `JAAMAS_RESPONSES.md` devem incorporar
este adendo, em particular R1.6/R2.5/R3.4 e os novos números.

## 7. Artefatos, comandos e decisão final

Fontes novas: `experiments/audit/ContractNetAlternatives.sol`, `test/audit/CorrelationAudit.t.sol`,
`test/symbolic/CorrelationPolicySymbolic.t.sol`. Scripts novos: `jaamas_close_validate.py`,
`jaamas_close_symbolic.py`, `jaamas_close_txgas.py`, `jaamas_close_manifest.py`.
Resultados: `evidence/jaamas-close/`. As fontes, documentos, scripts e resultados anteriores
foram preservados em `prior-work.tar.gz` e comparados contra `prior-hashes.json`.
O manifesto de encerramento verificou **177 arquivos anteriores idênticos**; não apenas
os resultados resumidos. Nenhum relatório antigo foi reescrito para fazer parecer que esta
rodada já havia sido executada.

Da raiz de `blade`, executar sequencialmente com as ferramentas instaladas:

```sh
python3 scripts/jaamas_close_validate.py
HALMOS=/tmp/blade-halmos/bin/halmos HALMOS_Z3=/tmp/blade-halmos/bin/z3 \
  python3 scripts/jaamas_close_symbolic.py
python3 scripts/jaamas_close_txgas.py
python3 scripts/jaamas_close_manifest.py
```

O script Anvil usa somente `127.0.0.1:18547` e encerra o processo. Builds de validação e Halmos
usam diretórios temporários isolados. O manifesto registra repetições de gas, configurações,
propriedades, fontes e integridade histórica. Os comandos CHC/BMC e seus resultados também são
registrados nos artefatos de encerramento.

**Pronto para consolidar os resultados científicos descritos, não para afirmar que o core legado
resolve reutilização de IDs ou que o protótipo de tokens está pronto para implantação.** A solução
recomendada para novas aplicações é unicidade por instância, preferencialmente geração por nonce.
Uma mudança obrigatória do core exigiria uma decisão explícita de migração de API/semântica,
que não foi tomada silenciosamente nesta auditoria. A publicação continua sob decisão do autor.
