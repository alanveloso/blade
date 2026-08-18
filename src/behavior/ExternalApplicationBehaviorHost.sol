// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Action, ActionLib} from "./Action.sol";
import {BehaviorContext, ContextLib} from "./Context.sol";
import {IExternalApplicationStrategy} from "./IExternalApplicationStrategy.sol";

/// @title Opt-in local installation of reusable external application strategies.
/// @dev Capability mixin: does not inherit `Agent`. A concrete agent composes both.
/// @dev Application-external only. Not a protocol-role registry. `S` is not an AID.
/// @dev Map presence is membership (installed), not runnable/eligible. No progress store.
/// @dev `_runExternalBehavior` uses explicit STATICCALL. Strategy revert data is not bubbled.
abstract contract ExternalApplicationBehaviorHost {
    /// @dev `address(0)` means not installed. Occupied ids must be uninstalled before reuse.
    mapping(bytes32 localId => address implementation) internal _behaviors;

    error InvalidLocalId();
    error InvalidImplementation();
    error AlreadyInstalled();
    error NotInstalled();
    error NoStrategyCode();
    error ContextAgentMismatch();
    error InvalidStrategyReturn();
    error BehaviorExecutionFailed(bytes32 localId, address implementation);

    event BehaviorInstalled(bytes32 indexed localId, address implementation);
    event BehaviorUninstalled(bytes32 indexed localId, address implementation);

    function behaviorImplementation(bytes32 localId) public view returns (address) {
        return _behaviors[localId];
    }

    function _installBehavior(bytes32 localId, address implementation) internal {
        if (localId == bytes32(0)) {
            revert InvalidLocalId();
        }
        if (implementation == address(0)) {
            revert InvalidImplementation();
        }
        if (_behaviors[localId] != address(0)) {
            revert AlreadyInstalled();
        }
        _behaviors[localId] = implementation;
        emit BehaviorInstalled(localId, implementation);
    }

    function _uninstallBehavior(bytes32 localId) internal {
        address implementation = _behaviors[localId];
        if (implementation == address(0)) {
            revert NotInstalled();
        }
        delete _behaviors[localId];
        emit BehaviorUninstalled(localId, implementation);
    }

    /// @dev One local installation per call. Not an engine. Does not decode `Message`.
    /// @dev `ContextLib.validate` is shape only; `ctx.agent` must be this contract.
    /// @dev Not `view`: `applyAction` is a no-op today but is the mutation path for later kinds.
    function _runExternalBehavior(bytes32 localId, BehaviorContext memory ctx) internal {
        address implementation = _behaviors[localId];
        if (implementation == address(0)) {
            revert NotInstalled();
        }
        if (implementation.code.length == 0) {
            revert NoStrategyCode();
        }
        ContextLib.validate(ctx);
        if (ctx.agent != address(this)) {
            revert ContextAgentMismatch();
        }

        bytes memory payload = abi.encodeCall(IExternalApplicationStrategy.decide, (ctx));
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), implementation, add(payload, 0x20), mload(payload), 0, 0)
        }
        if (!ok) {
            revert BehaviorExecutionFailed(localId, implementation);
        }

        uint256 size;
        assembly ("memory-safe") {
            size := returndatasize()
        }
        if (size == 0) {
            revert InvalidStrategyReturn();
        }
        bytes memory ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0, size)
        }

        Action memory proposed = abi.decode(ret, (Action));
        ActionLib.applyAction(proposed);
    }
}
