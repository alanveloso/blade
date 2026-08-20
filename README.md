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

## Behavior Runtime

BLADE includes an opt-in reactive Behavior runtime with external
read-only strategies, OneShot and Cyclic lifetimes, Message and
Explicit triggers, bounded execution, and application-owned Action dispatch.

Behavior v1 snapshot: `e88ab37f754c2313d97f48184944624b1ab5d03d`.

This runtime is reactive and does not implement autonomous scheduling
or the complete JADE Behaviour model.

## Requirements

Solidity **0.8.26** and [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test
forge fmt --check
```

## License

[MIT](LICENSE)
