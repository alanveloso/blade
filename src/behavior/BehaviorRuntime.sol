// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "../core/Agent.sol";
import {Message} from "../core/Message.sol";
import {BehaviorEngine} from "./BehaviorEngine.sol";
import {ContextLib} from "./Context.sol";

/// @title Opt-in trigger runtime: authenticated Message / Explicit → Agent-authored Context → step.
/// @dev Not a scheduler. Not protocol-role dispatch. Does not change snapshot `Agent.handle`.
/// @dev No message filtering or per-behavior eligibility: every installed id is selected for every
///      accepted trigger (`installed == selected`). Restrict callers with `_authorizeInbound`.
/// @dev `_dispatchExplicitTrigger` is internal. Public Explicit exposure is `ExplicitExecutorGate`.
abstract contract BehaviorRuntime is Agent, BehaviorEngine {
    /// @dev Leaf budget for a behavior step (Message inbound and authorized Explicit). No hidden default.
    ///      Engine splits; host applies. Callers do not pass `stepGas`.
    function _behaviorStepGas() internal view virtual returns (uint256);

    function _onReceive(Message calldata inbound) internal virtual override {
        super._onReceive(inbound);
        _runBehaviorStep(
            ContextLib.messageTrigger(address(this), msg.sender, inbound), _behaviorStepGas()
        );
    }

    /// @dev Explicit extra-tx trigger. Authors Context from `msg.sender`. Not a public endpoint.
    function _dispatchExplicitTrigger(uint256 stepGas) internal {
        _runBehaviorStep(ContextLib.explicitTrigger(address(this), msg.sender), stepGas);
    }
}
