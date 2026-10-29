# BLADE Core — security model, trust assumptions and known limitations

This document records what the Core enforces on-chain, what it assumes, and what it does not
protect. Every statement below is backed by a test; the test names are given in brackets.

## 1. Request: message correlation (changed in the JAAMAS revision)

### Problem (reviewer 3)

The receiver checked the peer identity and the protocol phase, but never compared `inReplyTo`
with the token of the live session. The initiator accepted any `inReplyTo`; the participant only
compared `inReplyTo` with the application-supplied `inbound` argument of `_reply`, not with
session state. After cleanup, a reused `conversationId` accepted replies produced for the previous
instance.

### Design

* **Session token.** The `replyWith` of the opening Request is the session token. It is stored in
  `Status.replyWith` on both sides while the session is live and deleted with the session.
* **Direction rule.** Participant acts (Agree, Refuse, Inform, Failure, NotUnderstood) must carry
  the token in `inReplyTo`. Initiator continuations (NotUnderstood) must keep it in `replyWith`.
  The rule is enforced on inbound (`_handleRequestInbound`) and outbound (`_handleRequestReply`)
  against the stored session, after the peer and transition checks and before any state change.
* **Core-assigned, single-use tokens.** `_startRequest` derives the token as
  `keccak256(chainid, address(this), conversationId, ++_requestNonce)` and writes it back into the
  caller's `outbound` memory struct. An application-chosen `replyWith` is rejected
  (`ReplyWithAssignedByCore`), so the contract — not a convention — guarantees that reusing a
  `conversationId` never reuses a token.
* **Token required.** An inbound Request without `replyWith` is rejected (`MissingReplyWith`).

Alternatives considered: a registry of used `(conversationId, token)` pairs (one permanent slot per
Request ever opened) and forbidding `conversationId` reuse (one permanent slot per id). Both give
the same guarantee at higher permanent storage cost; the nonce costs one slot per agent.

### Interface and storage changes

| Item | Change |
|---|---|
| `RequestAgent.Status` | new field `bytes32 replyWith` (third slot); `requestStatus` returns it |
| `RequestAgent._requestNonce` | new `uint256` state variable (persistent, one slot per agent) |
| `_startRequest` | requires `outbound.replyWith == 0`; assigns the token in place |
| Errors | `MissingReplyWith()`, `ReplyWithAssignedByCore()`; mismatches reuse `Agent.ReplyWithMismatch()` |
| Inbound Request | must carry a non-zero `replyWith` |
| Replies | must carry the session token (see direction rule) |

Storage layout: in leaves that inherit `RequestAgent` before other capabilities (e.g.
`CompositeAgent`), later state variables shift by one slot. No upgradeable deployment exists.

Cleanup: the per-session token slot is deleted by the terminal act like the rest of `Status`
(`_assertCleared`, invariant R-I2 checks all three raw slots). The nonce is the only persistent
addition.

### Gas (forge 1.7.1, solc 0.8.26, optimizer 200; `--isolate`, refunds included)

| Operation | Before | After | Δ |
|---|---:|---:|---:|
| `startRequest` (nonce already non-zero) | 86,675 | 136,331 | +49,656 |
| terminal participant reply (`respond`) | 46,457 | 53,957 | +7,500 |
| `ExampleRequester.request` (Request → Inform in one tx) | 79,549 | 120,091 | +40,542 |

Execution gas without refunds (`test/GasRequest.t.sol`): `startRequest` 62,139 → 106,995;
Agree/Inform/Refuse ≈ +1,000 each. The first Request of an agent pays an extra ≈ 20,000 to
initialise the nonce. The increase comes from two new zero→non-zero slots (initiator and
participant token) and the nonce update. Possible optimisation, not applied for simplicity: store
the initiator's nonce packed in `Status` slot 0 and recompute the token (≈ −20,000 per Request).

Contract Net code is unchanged; its gas is unchanged.

### Guarantees and residual limitations

* Replies of a previous instance (same or other `conversationId`), wrong tokens and missing tokens
  are rejected at both ends with no state change [`test_corr_*`, invariant R-C1..R-C5].
* **Limitation — relay replay.** A participant cannot distinguish a fresh relayed Request from a
  replay of a closed one; freshness on the relay path is the relay's responsibility
  [`test_limitation_relayReplayOfClosedRequestReopensParticipant`].
* **Limitation — non-BLADE initiators** choose their own tokens; uniqueness is guaranteed only for
  Requests opened through `_startRequest`.

## 2. Contract Net: reentrancy

`_evaluate` applies all effects (slots, `live`, `evaluated`, cleanup) before delivering decisions.
A participant that, on AcceptProposal, calls `manager.handle` directly (bypassing its own FSM)
reaches the manager and is rejected by the manager's slot checks; acts that are valid from
ACCEPTED (Inform, Failure, NotUnderstood) are accepted and leave the conversation consistent.
Reentrant `evaluate` and `cfp` on the same live id are rejected. No defect was found and no
production change was made [`test_reentry_*`, mutation-checked].

The previous test (`MaliciousReentrantParticipant`) only exercises the participant's own FSM: it
still passes when the manager's check is removed. It is kept as a participant-side regression.

## 3. Contract Net: progress under non-cooperative participants (limitations)

Decisions are delivered by synchronous calls inside `_evaluate`, and a failed delivery reverts the
whole evaluation (atomic semantics).

| Behaviour | Effect | Recovery |
|---|---|---|
| Reverts on AcceptProposal | evaluation with it in `accept` reverts for all | put it in `reject` |
| Unbounded gas loop on AcceptProposal | same as revert, at any gas limit | put it in `reject` |
| Bounded gas burn on AcceptProposal | evaluator pays ≈ 63/64 of the gas limit; may revert if the residue cannot finish the remaining deliveries | raise gas limit or reject |
| Reverts on every decision | **conversation can never be evaluated or cleared; id cannot be reused** | honest participants can withdraw with NotUnderstood; manager side has none |
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

## 4. Blockchain-specific properties

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

Not provided by the Core (depend on incentives, privacy or external behaviour):

* **Timestamp manipulation.** A block producer can shift `block.timestamp` within the chain's
  drift bound; only proposals within that window of `replyBy` can change outcome. Applications
  choose deadline margins.
* **Front-running and confidentiality.** Proposals are public (calldata and the `Received`
  event). There is no commit-reveal; the Core does not prevent front-running or proposal copying.
* **Conversation-id squatting.** Sessions are keyed by `conversationId` only. A third agent that
  learns a pending id can open it first at a participant, making the honest Request/CFP revert.
  Mitigations are application-level (`_authorizeInbound`, unpredictable ids).
* **Caller authorization of `_cfp` / `_evaluate`.** The primitives are caller-agnostic; a
  permissive wrapper lets anyone choose winners. Wrappers must gate them
  (`OwnerGatedContractNetManager` in the tests).
