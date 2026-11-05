# Protocol revision

Single entry point for the protocol-layer revision of BLADE: scope, Core changes,
how to reproduce tests, and known limits.

## Scope

Work targets BLADE's **interaction-protocol layer** (Request, Contract Net, experimental
Subscribe). It does not claim full FIPA compliance, production security, unrestricted
autonomy, or superiority over other frameworks.

**Behavior Runtime** (`src/behavior/`) is a separate line of work and is **not** part of
this `main` release.

## Core changes (on `main`)

| Change | Role |
|---|---|
| Request correlation (E2) | Single-use session token; see [`SECURITY.md`](SECURITY.md) |
| `SubscribeAgent` | Experimental native FIPA Subscribe subset |
| `Performative.Subscribe` / `Protocol.FipaSubscribe` | Enum extensions |
| Contract Net native-only guard | Opening/inbound CN with `logicalSender != 0` reverts (`UnexpectedPeer`) |

Application examples: `examples/SolidityPolicyExample.sol`. Experimental alternatives
(not Core): `experiments/QueuedContractNetManager.sol`,
`experiments/audit/ContractNetAlternatives.sol`. Formal harness:
`formal/RequestProperties.sol`.

## Tests

```sh
forge test --fuzz-seed 0x42
forge test --match-path 'test/protocol/*' --fuzz-seed 0x42 -vv
forge test --match-path 'test/audit/*' --fuzz-seed 0x42 -vv
```

Optional reproduction helpers: `scripts/protocol_*.py` (offline; no paid APIs).

## Known limitations (must not be omitted)

- **Contract Net** still lacks Request-style instance protection when `conversationId` is
  reused: a prior envelope from the authorized peer can be accepted on a new instance.
  Reproduced in `test/audit/CorrelationAudit.t.sol`. Alternatives were measured in
  `experiments/audit/` and were **not** adopted as Core.
- Subscribe has no relay support and no on-chain timers/scheduling.
- Interleaving tests cover fixed EVM call schedules, not mempool/consensus/MEV.

## Evidence location

Run logs, manifests, symbolic dumps and comparative tables for this revision are kept in
the **blade-evaluation** repository under `revision/evidence/protocol/`.
