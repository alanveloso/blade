# BLADE

**BLADE** (BLockchain Agent DEvelopment framework) is an experimental framework for blockchain-resident agents on EVM-compatible networks.

It implements **selected FIPA interaction semantics**. It does not claim complete FIPA compliance.

## Core

| Type | Role |
|---|---|
| `Message` | Compact on-chain ACL message |
| `Agent` | Inbound `handle`; outbound `reply` |
| `RequestAgent` | Request protocol |
| `ContractNetManager` / `ContractNetParticipant` | Contract Net protocol |

## Requirements

Solidity **0.8.26** and [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test
forge fmt --check
```

## License

[MIT](LICENSE)
