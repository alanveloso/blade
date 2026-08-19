// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Action} from "../../src/behavior/Action.sol";
import {BehaviorContext, ContextLib} from "../../src/behavior/Context.sol";
import {BehaviorMembership} from "../../src/behavior/BehaviorMembership.sol";
import {BehaviorActionDispatcher} from "../../src/behavior/BehaviorActionDispatcher.sol";

/// @title Paired in-process application decision baseline (ADR locus A).
/// @dev Not a product engine. Not an autonomous scheduler. Does not inherit `Agent`.
/// @dev Same Context, Action, validate, and apply as the external path; only the decide locus differs.
/// @dev Hook reverts propagate naturally — not wrapped as `BehaviorExecutionFailed`.
abstract contract EmbeddedApplicationBehaviorHost is BehaviorMembership, BehaviorActionDispatcher {
    mapping(bytes32 localId => bool installed) internal _embedded;

    event EmbeddedBehaviorInstalled(bytes32 indexed localId);
    event EmbeddedBehaviorUninstalled(bytes32 indexed localId);

    function embeddedBehaviorInstalled(bytes32 localId) public view returns (bool) {
        return _embedded[localId];
    }

    function _installEmbeddedBehavior(bytes32 localId) internal {
        if (localId == bytes32(0)) {
            revert InvalidLocalId();
        }
        if (_embedded[localId]) {
            revert AlreadyInstalled();
        }
        _embedded[localId] = true;
        emit EmbeddedBehaviorInstalled(localId);
    }

    function _uninstallEmbeddedBehavior(bytes32 localId) internal {
        if (!_embedded[localId]) {
            revert NotInstalled();
        }
        delete _embedded[localId];
        emit EmbeddedBehaviorUninstalled(localId);
    }

    /// @dev In-process decide. Override per application. Must stay `view` so the matched
    ///      decision remains read-only like external `decide`.
    function _embeddedDecide(bytes32 localId, BehaviorContext memory ctx)
        internal
        view
        virtual
        returns (Action memory);

    /// @dev Same post-decision frontier as external: validated apply. No gasBudget.
    function _runEmbeddedBehavior(bytes32 localId, BehaviorContext memory ctx) internal {
        if (!_embedded[localId]) {
            revert NotInstalled();
        }
        ContextLib.validate(ctx);
        if (ctx.agent != address(this)) {
            revert ContextAgentMismatch();
        }
        Action memory proposed = _embeddedDecide(localId, ctx);
        _dispatchBehaviorAction(localId, ctx, proposed);
    }
}
