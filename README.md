# BLADE

**BLADE** (BLockchain Agent DEvelopment framework) is an experimental framework for blockchain-resident agents on EVM-compatible networks.

It implements **selected FIPA interaction semantics**. It does not claim complete FIPA compliance.

## Core

| Type | Role |
|---|---|
| `Message` | Compact on-chain ACL message |
| `Agent` / `IAgent` | Inbound `handle`; outbound `_send` / `_reply` |
| `RequestAgent` | Request protocol (`_startRequest`) |
| `ContractNetManager` / `ContractNetParticipant` | Contract Net (`_cfp`, `_evaluate`, `_respond`) |

Application contracts inherit these types and expose their own external methods around the internal primitives. Protocol selection is an application concern.

`Agent.handle` authenticates the caller, then calls `_authorizeInbound` (default: allow all) **before** any Request or Contract Net state mutation. Applications may override that hook; the Core does not impose an owner.

Protocol role types are abstract capabilities. A leaf agent initializes `Agent` once. One blockchain-resident contract may compose Request, Contract Net manager, and Contract Net participant by inheriting all three and routing inbound messages through the capability handlers (see `examples/CompositeExample.sol`). The composed leaf does not copy protocol FSMs; it only chooses which handler owns the message, then `Agent._reply` runs once.

Request and Contract Net maintain independent protocol-state namespaces, so protocol state does not collide even if identifiers coincide. Applications should nevertheless use distinct conversation identifiers for distinct interactions.

Being Contract Net **manager and participant of the same Contract Net conversation** is unsupported and is not dual-routed: opening a manager CFP while a participant session exists for that id reverts; inbound CN on a live manager conversation is handled only as manager (a colliding participant CFP reverts). Internal revert selectors on invalid composed paths are not claimed equivalent to every standalone role.

Minimal patterns: `examples/RequestExample.sol`, `examples/ContractNetExample.sol`, `examples/CompositeExample.sol`.

## Experimental Behavior runtime

Post-snapshot development in `src/behavior/` adds an **opt-in reactive application-behavior runtime**.
It does not change every `Agent` and does not claim a JADE cooperative scheduler.

Current product path:

```text
Message / authorized Explicit transaction
        -> Agent-authored BehaviorContext
        -> BehaviorEngine step
        -> bounded STATICCALL to an installed stateless strategy
        -> validated Action
```

The engine supports agent-local installations, OneShot lifetime by default, opt-in Cyclic
re-eligibility across later triggers, bounded walk/at-most dispatch, per-step gas partitioning,
bounded returndata, and an optional immutable external-executor gate. `Action` currently exposes
only `None`; application-effect dispatch is intentionally a later slice. Protocol-role Behavior
adapters are also later work.

The matched embedded locus used for architectural comparison is a **test/research baseline** under
`test/baselines/`, not a second production runtime.

Behavior code remains transaction-driven: contracts do not wake themselves, and time-based wake
requires a later external transaction source.

## Requirements

Solidity **0.8.26** and [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test
forge fmt --check
```

## License

[MIT](LICENSE)
