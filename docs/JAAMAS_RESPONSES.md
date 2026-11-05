# Suggested manuscript changes and reviewer responses

These drafts map the reviewer identifiers and topics supplied by the author. The full reviews
and manuscript were not provided; no quotation of a reviewer or manuscript line is implied.
Final section/page numbers and the author's assessment remain to be supplied during editing.
All claims below concern BLADE's **interaction-protocol layer**, within a blockchain-agent
framework. They do not establish novelty, superiority, unrestricted autonomy or full FIPA compliance.

## R1.6 — Message interleaving (partially addressed)

Problem: deterministic EVM execution can be confused with independence from transaction order.
Change: enumerate all six interleavings of two Request Agree→Inform chains; add cross-session,
deadline, stateful and adversarial properties. Experiments: Foundry campaigns with two seeds,
1,024 fuzz cases, 128×64 invariant budgets; symbolic isolation checks; limited-inventory demo.
Result: the defined independent-session schedules preserve isolation; changing buyer order can
change resource allocation. All final tests passed. Limits: no mempool, consensus/reorg simulation,
exhaustive arbitrary histories or claim of order-independent application outcomes.

Suggested response: “We distinguish deterministic execution for fixed state, inputs and transaction
order from the effects of selecting a different order. The revised evaluation enumerates six
legal schedules of two Request sessions and checks stateful adversarial sequences. A Solidity
inventory example demonstrates an order-dependent application outcome. These experiments support
the tested isolation properties; they do not imply independence from transaction ordering.”

## R2.3 — Third protocol and extensibility (partially addressed)

Problem: two protocols alone provide limited evidence that the layer can be extended.
Change: add experimental native Subscribe using Agent transport, authentication, authorization hook,
Message and events; append enum values; introduce subscription state, session/cancellation tokens,
optional agreement and cancellation acknowledgement. Experiments: positive/negative paths,
concurrency, reuse, delayed acknowledgements, nested callbacks, rollback and Request composition.
Result: the defined subset passes and composes without rewriting the shared core. A cancellation
correlation defect in the first prototype was reproduced and corrected. Limits: no logical relay,
content-language semantics, notification sequencing or complete FIPA conformance.

Suggested manuscript text: “The Subscribe experiment adds a protocol capability while reusing the
shared endpoint and message envelope. Explicit or implicit agreement activates notifications;
cancellation uses a separate correlation token and restores the preceding phase on failure. This
is evidence of extensibility for a stated subset, rather than a complete FIPA implementation.”

## R1.1 — Solidity agents (addressed for the requested demonstration)

Problem: application decisions delegated outside the chain would not demonstrate Solidity policies.
Change: InventoryAgent accepts/refuses according to stock; ReorderAgent calculates a deficit and
sends Request. Experiments: fuzzed stock/target values, refusal, successful fulfillment, repeated
ticks and competition between buyers. Result: decisions and state changes occur in Solidity through
BLADE interactions; Python only runs measurement infrastructure. Limits: this is a small reactive
policy example without payments, production access policy, learning or generalized planning.

Suggested response: “We added an executable example in which both application policies are Solidity
contracts. One computes a replenishment quantity and the other decides whether available inventory
permits fulfillment. The example exercises BLADE Request and does not use Python to make application
decisions. We describe its limited policy and trust model explicitly.”

## R2.1 — Meaning of autonomy (addressed by the revised claim, subject to manuscript editing)

Problem: contracts cannot initiate their own EVM execution.
Change: explicit external tick trigger and a test advancing time/blocks without triggering decisions.
Experiments: automatic reaction within the triggered call versus no activity without transactions.
Result: no self-scheduling; externally triggered decisions execute internally. Limits: no proof of
a general philosophical notion of autonomy; external callers are required for future activation.

Suggested manuscript text: “The policies are blockchain-resident and make application decisions
when activated. Execution remains reactive: an external transaction triggers the EVM, and the
contracts do not schedule their own future execution. We therefore separate policy location and
decision logic from autonomous temporal activation.”

## R2.5 — Formal verification (partially addressed)

Problem: SMTChecker custom-error/aliasing abstractions prevented several source-level claims.
Change: add Halmos checks over real deployed bytecode and an isolated mutation control.
Experiments: 11 symbolic obligations, no bounded-loop truncation in these paths; CHC/BMC rerun;
concrete replay of earlier SMT candidates; mutant without Request correlation check.
Result: all 11 bytecode obligations passed; the mutant failed as expected. CHC/BMC still report
one local safe assertion and seven not established. Limits: fixed setups and finite call sequences,
not inductive verification of the full implementation or global liveness. Failed solver abstractions
are not reported as concrete implementation vulnerabilities.

Suggested response: “We added bytecode-level symbolic checks for authorization, correlation,
transitions, isolation and rollback, with explicit harness assumptions and bounds. Eleven obligations
passed, and a negative control lacking the Request token check produced a counterexample. These
results are reported separately from Foundry tests and the inconclusive SMTChecker obligations.
We do not claim formal verification of all protocol executions.”

## R2.6 — Contract Net failure recovery (partially addressed)

Problem: a recipient can prevent atomic decision delivery and global progress.
Change: preserve the synchronous core and evaluate an optional queued-decision manager. Correct
premature completion and obsolete pending acceptance after withdrawal in that prototype.
Experiments: decision reverts, gas exhaustion, individual honest completion, pending cleanup,
reentrant delivery, CFP revert and late/abandoned sessions. Result: individual honest progress is
possible with separate deliveries; global termination remains conditional. Limits: failed CFP,
uncooperative rejected recipients and silent accepted participants have no universal recovery.

Suggested response: “We retain atomic synchronous delivery as the default and compare it with an
experimental queue. Separating delivery enables honest participants to progress despite another
recipient's failed decision handler, at the cost of additional state and transactions. It does not
guarantee global termination. We document the remaining uncollectable or unfinished states.”

## R3.4 — Robustness and adversarial participants (partially addressed)

Problem: an honest-path evaluation does not expose denial of service, rollback or reentrancy behavior.
Change: retain and reexecute the malicious-participant suite, add queue reentrancy/withdrawal checks,
and reject unsupported logical CFP identities before state mutation.
Experiments: unbounded gas consumption with 2M/25M limits, bounded consumption with 1M/20M limits,
reverts on decisions, repeated deliveries, early completion and nested Subscribe callbacks.
Result: atomic rollback and tested individual isolation are reproduced; four demonstrated defects
were fixed. Limits: no guarantee against arbitrary hostile application code. Contract Net has no
per-instance token enforcement; fresh conversation IDs are required when delayed-message separation
is needed. The queue remains experimental and does not replace the synchronous core.

Suggested manuscript text: “Robustness is evaluated as separate safety and progress properties.
Atomic rollback preserves state after failed synchronous calls but can prevent collective progress.
Queued delivery changes that tradeoff; it isolates individual deliveries without solving every
abandonment or cleanup case. We state these limitations as protocol/application assumptions.”

## R1.4 — Gas methodology (addressed for the controlled local evaluation)

Problem: monetary prices, network variation and unequal state/bytecode confound execution costs.
Change: fix solc 0.8.26, optimizer 200, no via-IR, Cancun; record bytecode, calldata, timestamps,
initial-state restoration, execution slices and local transaction receipts separately.
Experiments: original commit, preserved experimental tree and final tree; 10 Anvil scenarios and
repeatability check; common execution benchmarks. Result: Request unchanged; synchronous Contract
Net cycle +116 gas (+0.0296%); queued cycle +7,304 (+1.4103%) versus the previous queue; Subscribe
cycle +130,891 (+36.9719%). The final queue uses 33.8406% more receipt gas than final synchronous
Contract Net in the specified honest case, and two additional transactions.
Limits: these are specified small scenarios, not scaling curves or an efficiency superiority claim.
Deployment is recorded separately. The microbenchmark's apparent queue saving comes from warmed
slots outside its measured interval and is not claimed as an end-to-end improvement.

Suggested response: “The primary gas evaluation is fully local and reproducible under Cancun.
We report execution gas separately from transaction receipt gas and do not use ETH prices, testnets
or L2 fee assumptions. Corrections increase Subscribe and queue costs; these regressions are disclosed
with absolute and relative values. Functional outcome equivalence in the honest case does not imply
equivalent atomicity of synchronous and queued implementations.”

## Submission checklist for the author

Use the final report and manifest as the evidence source, rather than mixing figures from the
previous exploratory report. Insert the stated subsets, trust assumptions and proof scope alongside
the claims they limit. Link the released artifact only after the author reviews and commits it.
No manuscript text has been published and no PR has been opened.
