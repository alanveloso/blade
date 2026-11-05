# BLADE

**BLADE** (BLockchain Agent DEvelopment framework) is an experimental framework for blockchain-resident agents on EVM-compatible networks.

It implements **selected FIPA interaction semantics**. It does not claim complete FIPA compliance.

## On-chain types

| Type | Role |
|---|---|
| `Message` | Compact on-chain ACL message |
| `Agent` / `IAgent` | Inbound `handle`; outbound `_send` / `_reply` |
| `RequestAgent` | Request protocol (`_startRequest`) |
| `ContractNetManager` / `ContractNetParticipant` | Contract Net (`_cfp`, `_evaluate`, `_respond`) |
| `SubscribeAgent` | Experimental Subscribe subset |

Application contracts inherit these types and expose their own external methods around the internal primitives. Protocol selection is an application concern.

`Agent.handle` authenticates the caller, then calls `_authorizeInbound` (default: allow all) **before** any Request or Contract Net state mutation. Applications may override that hook; BLADE does not impose an owner.

Protocol role types are abstract capabilities. A leaf agent initializes `Agent` once. One blockchain-resident contract may compose Request, Contract Net manager, and Contract Net participant by inheriting all three and routing inbound messages through the capability handlers (see `examples/CompositeExample.sol`). The composed leaf does not copy protocol FSMs; it only chooses which handler owns the message, then `Agent._reply` runs once.

Request and Contract Net maintain independent protocol-state namespaces. Request still uses
application-chosen `conversationId` values; Contract Net opening assigns the id in BLADE.

Being Contract Net **manager and participant of the same Contract Net conversation** is unsupported
and is not dual-routed. Internal revert selectors on invalid composed paths are not claimed
equivalent to every standalone role.

Request correlation: `_startRequest` assigns a single-use `replyWith` token (leave it zero); every
later act must carry it (`inReplyTo` from the participant, `replyWith` from the initiator).
Contract Net opening: pass `conversationId == 0` to `_cfp`; BLADE assigns and returns
`keccak256(chainId, address(this), ++nonce)`. Trust assumptions and limitations:
[`docs/SECURITY.md`](docs/SECURITY.md).

Minimal patterns: `examples/RequestExample.sol`, `examples/ContractNetExample.sol`, `examples/CompositeExample.sol`, `examples/SolidityPolicyExample.sol`.

## Behavior Runtime

BLADE includes an opt-in reactive Behavior runtime with external
read-only strategies, OneShot and Cyclic lifetimes, Message and
Explicit triggers, bounded execution, and application-owned Action dispatch.
Installations may restrict which trigger, protocol, and performative they
accept; unmatched behaviors are not executed.

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
