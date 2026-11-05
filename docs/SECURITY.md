# BLADE — security model, trust assumptions and known limitations

This document records what BLADE enforces on-chain, what it assumes, and what it does not
protect. Every statement below is backed by a test; the test names are given in brackets.

## 1. Request: message correlation

### Threat

Without a session token bound to the live Request, peer and phase checks alone are not enough:
an initiator may accept any `inReplyTo`, and a participant may validate `inReplyTo` only against
an application-supplied inbound envelope. After cleanup, reusing a `conversationId` can accept
replies produced for a previous instance.

### Design

* **Session token.** The `replyWith` of the opening Request is the session token. It is stored in
  `Status.replyWith` on both sides while the session is live and deleted with the session.
* **Direction rule.** Participant acts (Agree, Refuse, Inform, Failure, NotUnderstood) must carry
  the token in `inReplyTo`. Initiator continuations (NotUnderstood) must keep it in `replyWith`.
  The rule is enforced on inbound (`_handleRequestInbound`) and outbound (`_handleRequestReply`)
  against the stored session, after the peer and transition checks and before any state change.
* **BLADE-assigned, single-use tokens.** `_startRequest` derives the token as
  `keccak256(chainid, address(this), conversationId, ++_requestNonce)` and writes it back into the
  caller's `outbound` memory struct. An application-chosen `replyWith` is rejected
  (`ReplyWithAssignedByBlade`), so reusing a `conversationId` never reuses a token.
* **Token required.** An inbound Request without `replyWith` is rejected (`MissingReplyWith`).

Alternatives considered and not adopted: a permanent registry of used `(conversationId, token)`
pairs, and forbidding `conversationId` reuse. Both give the same guarantee at higher permanent
storage cost; the nonce costs one slot per agent.

### Interface

| Item | Role |
|---|---|
| `RequestAgent.Status.replyWith` | Live session token; returned by `requestStatus` |
| `RequestAgent._requestNonce` | Persistent per-agent counter used in token derivation |
| `_startRequest` | Requires `outbound.replyWith == 0`; assigns the token in place |
| Errors | `MissingReplyWith()`, `ReplyWithAssignedByBlade()`; mismatches reuse `Agent.ReplyWithMismatch()` |

Cleanup deletes the per-session token with the rest of `Status` (`_assertCleared`, invariant R-I2).
The nonce is the only persistent addition. Leaves that inherit `RequestAgent` before other
capabilities shift later storage by one slot.

### Gas (forge 1.7.1, solc 0.8.26, optimizer 200; `--isolate`, refunds included)

| Operation | Gas |
|---|---:|
| `startRequest` (nonce already non-zero) | 136,331 |
| terminal participant reply (`respond`) | 53,957 |
| `ExampleRequester.request` (Request → Inform in one tx) | 120,091 |

Execution gas without refunds (`test/GasRequest.t.sol`): `startRequest` ≈ 106,995;
Agree/Inform/Refuse carry a small per-act overhead. The first Request of an agent pays an extra
≈ 20,000 to initialise the nonce. Cost drivers: two zero→non-zero token slots and the nonce
update. Optional packing of the initiator nonce into `Status` slot 0 (recompute token on read)
was not applied.

### Guarantees and residual limitations

* Replies of a previous instance (same or other `conversationId`), wrong tokens and missing tokens
  are rejected at both ends with no state change [`test_corr_*`, invariant R-C1..R-C5].
* **Limitation — relay replay.** A participant cannot distinguish a fresh relayed Request from a
  replay of a closed one; freshness on the relay path is the relay's responsibility
  [`test_limitation_relayReplayOfClosedRequestReopensParticipant`].
* **Limitation — non-BLADE initiators** choose their own tokens; uniqueness is guaranteed only for
  Requests opened through `_startRequest`.

## 2. Contract Net: conversation identifiers

### Threat

If the application chooses `conversationId` at CFP opening, a prior envelope from an authorized
peer can be accepted on a later instance that reuses the same id after cleanup
[`test/audit/CorrelationAudit.t.sol`].

### Design

* **BLADE-assigned ids.** `_cfp` requires `message.conversationId == 0`, assigns
  `keccak256(abi.encode(block.chainid, address(this), ++_conversationNonce))`, writes it into the
  opening message, returns it, and emits `ConversationOpened`. A non-zero external id reverts
  `ConversationIdAssignedByBlade`.
* **No per-instance tokens.** Continuation correlation stays slot/FSM based. Token prototypes
  measured under `experiments/audit/` are not part of BLADE.

Audit comparators may override `_openConversationId` to study alternate policies; production
wrappers must not.

### Guarantees and residual limitations

* Under the default manager, a new opening cannot reuse a previous id, so stale Propose/Inform
  from a prior instance do not attach to a fresh conversation.
* **Limitation — squatting at participants.** A third party that learns a pending id can still
  open a conflicting session at a participant for Request (app-chosen ids) or for a CN id after it
  has been assigned and observed. Mitigations remain application-level (`_authorizeInbound`).

## 3. Contract Net: reentrancy

`_evaluate` applies all effects (slots, `live`, `evaluated`, cleanup) before delivering decisions.
A participant that, on AcceptProposal, calls `manager.handle` directly (bypassing its own FSM)
reaches the manager and is rejected by the manager's slot checks; acts that are valid from
ACCEPTED (Inform, Failure, NotUnderstood) are accepted and leave the conversation consistent.
Reentrant `evaluate` and `cfp` on the same live id are rejected [`test_reentry_*`].

`MaliciousReentrantParticipant` only exercises the participant's own FSM and is kept as a
participant-side regression.

## 4. Contract Net: progress under non-cooperative participants (limitations)

Decisions are delivered by synchronous calls inside `_evaluate`, and a failed delivery reverts the
whole evaluation (atomic semantics).

| Behaviour | Effect | Recovery |
|---|---|---|
| Reverts on AcceptProposal | evaluation with it in `accept` reverts for all | put it in `reject` |
| Unbounded gas loop on AcceptProposal | same as revert, at any gas limit | put it in `reject` |
| Bounded gas burn on AcceptProposal | evaluator pays ≈ 63/64 of the gas limit; may revert if the residue cannot finish the remaining deliveries | raise gas limit or reject |
| Reverts on every decision | **conversation can never be evaluated or cleared** | honest participants can withdraw with NotUnderstood; manager side has none |
| Several conversations evaluated in one tx | one failure reverts all | evaluate in separate transactions |
| Manager never evaluates | CFPED participants `expire`; PROPOSED participants only via NotUnderstood | — |
| Accepted participant never reports | manager conversation stays live; no manager timeout | — |

Tests: `test/ContractNetLiveness.t.sol`.

Candidate mitigations evaluated and **not** applied, because each changes protocol semantics:

1. `try/catch` around decision delivery (treat failure as Failure): breaks atomic evaluation,
   bypasses the overridable `_send`, and needs a gas cap that also constrains honest synchronous
   completion.
2. Allow PROPOSED participants in `silent` (drop without a message): small code change, but omits
   the reject-proposal FIPA obligation and leaves the dropped participant in PROPOSED with no
   expiry.
3. Pull-based decisions or a manager-side timeout: architectural change (asynchronous delivery).

Trust assumption: the Contract Net manager assumes invited participants accept decision delivery.
Applications that cannot assume this should invite only vetted participants.

## 5. Blockchain-specific properties

Verified by the contract (tests in `test/ContractNetChainSecurity.t.sol`, invariants in
`test/invariants/`):

* Order independence of responses: the same set of responses in any order yields the same state.
* Deadline: a proposal is timely iff `block.timestamp <= replyBy`; evaluation requires
  `block.timestamp > replyBy`. In a single block, a timely proposal and an evaluation are mutually
  exclusive.
* After evaluation or completion, no act from non-members, rejected, silent or finished
  participants changes state; completed conversations reject every act.
* Third parties cannot act for participants (transport identity is `msg.sender`).
* Conversations are isolated; rejected messages and reverted calls leave state unchanged; manager
  slots only move forward along the FSM.

Not provided by BLADE (depend on incentives, privacy or external behaviour):

* **Timestamp manipulation.** A block producer can shift `block.timestamp` within the chain's
  drift bound; only proposals within that window of `replyBy` can change outcome. Applications
  choose deadline margins.
* **Front-running and confidentiality.** Proposals are public (calldata and the `Received`
  event). There is no commit-reveal; BLADE does not prevent front-running or proposal copying.
* **Caller authorization of `_cfp` / `_evaluate`.** The primitives are caller-agnostic; a
  permissive wrapper lets anyone choose winners. Wrappers must gate them
  (`OwnerGatedContractNetManager` in the tests).
