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

Application contracts inherit these types and expose their own external methods around the internal primitives. Protocol selection and authorization are application concerns, not Core.

Minimal patterns: `examples/RequestExample.sol`, `examples/ContractNetExample.sol`.

## Requirements

Solidity **0.8.26** and [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test
forge fmt --check
```

## License

[MIT](LICENSE)
