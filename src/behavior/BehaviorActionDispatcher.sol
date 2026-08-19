// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Action, ActionLib, Kind} from "./Action.sol";
import {BehaviorContext} from "./Context.sol";

/// @title Trusted Agent-owned dispatch boundary for validated Behavior proposals.
/// @dev The untrusted strategy can only *propose* an Action while executing under STATICCALL.
///      Storage effects happen later in the Agent/runtime through this trusted boundary.
/// @dev `Application` is deliberately not a protocol-role instruction. A leaf that wants to
///      bridge application decisions into a protocol kernel must do so through a dedicated,
///      separately-reviewed adapter rather than redefining protocol legality here.
/// @dev In an engine step, accepted effects are applied immediately in selected behavior order.
///      A later failure still reverts all earlier effects because the whole trigger transaction fails.
abstract contract BehaviorActionDispatcher {
    error UnsupportedApplicationAction();

    /// @dev Validation is framework-owned and runs before any application effect.
    ///      `None` stays a true no-op. Any application hook revert is fail-fast and rolls back
    ///      the whole behavior step/trigger transaction.
    function _dispatchBehaviorAction(
        bytes32 localId,
        BehaviorContext memory ctx,
        Action memory action
    ) internal {
        ActionLib.validate(action);
        if (action.kind == uint8(Kind.None)) {
            return;
        }
        _onApplicationAction(localId, ctx, action.data);
    }

    /// @dev Trusted leaf policy. Default-deny so an application Action cannot be accepted silently.
    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory) internal virtual {
        revert UnsupportedApplicationAction();
    }
}
