// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BehaviorRuntime} from "./BehaviorRuntime.sol";

/// @title Opt-in authorized exposure of Explicit extra-tx triggers.
/// @dev Not a waker. Not a scheduler. Does not change `BehaviorRuntime` (Explicit stays internal there).
/// @dev `explicitExecutor` is application/leaf authority, not `trustedRelay` and not a Core owner.
///      `address(0)` denies every caller. Redeploy (or a later specialization) to change the executor.
/// @dev The executor chooses *when* to provoke a step, not `stepGas`. Budget is `_behaviorStepGas()`.
/// @dev Authorization uses `msg.sender` only, never `tx.origin`.
abstract contract ExplicitExecutorGate is BehaviorRuntime {
    address public immutable explicitExecutor;

    error UnauthorizedExplicitTrigger();

    constructor(address explicitExecutor_) {
        explicitExecutor = explicitExecutor_;
    }

    /// @dev Default: sole immutable executor. Override later for an allowlist; do not default-allow.
    function _authorizeExplicitTrigger(address caller) internal view virtual {
        if (explicitExecutor == address(0) || caller != explicitExecutor) {
            revert UnauthorizedExplicitTrigger();
        }
    }

    function dispatchExplicitTrigger() external {
        _authorizeExplicitTrigger(msg.sender);
        _dispatchExplicitTrigger(_behaviorStepGas());
    }
}
