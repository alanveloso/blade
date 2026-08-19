// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Action} from "./Action.sol";
import {BehaviorContext, ContextLib} from "./Context.sol";
import {IExternalApplicationStrategy} from "./IExternalApplicationStrategy.sol";
import {BehaviorMembership} from "./BehaviorMembership.sol";
import {BehaviorActionDispatcher} from "./BehaviorActionDispatcher.sol";

/// @title Opt-in local installation of reusable external application strategies.
/// @dev Capability mixin: does not inherit `Agent`. A concrete agent composes both.
/// @dev `_runExternalBehavior` uses explicit STATICCALL with a caller-supplied gas ceiling
///      (EIP-150 may deliver less than requested). Strategy revert data is not bubbled.
/// @dev `MAX_STRATEGY_RETURN` bounds the external execution copy; it is not a semantic
///      maximum for `Action.data`.
abstract contract ExternalApplicationBehaviorHost is BehaviorMembership, BehaviorActionDispatcher {
    /// @dev Operational cap on success returndata copied from an untrusted STATICCALL.
    uint256 internal constant MAX_STRATEGY_RETURN = 1024;
    /// @dev Defensive host reserve so a drained stipend still yields a BLADE error.
    ///      Not scheduling policy.
    uint256 internal constant POST_CALL_OVERHEAD = 50_000;

    mapping(bytes32 localId => address implementation) internal _behaviors;

    error InvalidImplementation();
    error NoStrategyCode();
    error InvalidGasBudget();
    error InvalidStrategyReturn();
    error StrategyReturnTooLarge();
    error BehaviorExecutionFailed(bytes32 localId, address implementation);

    event BehaviorInstalled(bytes32 indexed localId, address implementation);
    event BehaviorUninstalled(bytes32 indexed localId, address implementation);

    function behaviorImplementation(bytes32 localId) public view returns (address) {
        return _behaviors[localId];
    }

    function _installBehavior(bytes32 localId, address implementation) internal virtual {
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

    function _uninstallBehavior(bytes32 localId) internal virtual {
        address implementation = _behaviors[localId];
        if (implementation == address(0)) {
            revert NotInstalled();
        }
        delete _behaviors[localId];
        emit BehaviorUninstalled(localId, implementation);
    }

    /// @dev `gasBudget` is a requested STATICCALL ceiling, not an exact inner `gasleft()`.
    ///      The strategy never receives more than `gasBudget`; EIP-150 may deliver less.
    function _runExternalBehavior(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        internal
    {
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
        uint256 remaining = gasleft();
        if (
            gasBudget == 0 || remaining <= POST_CALL_OVERHEAD
                || gasBudget > remaining - POST_CALL_OVERHEAD
        ) {
            revert InvalidGasBudget();
        }

        bytes memory payload = abi.encodeCall(IExternalApplicationStrategy.decide, (ctx));
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gasBudget, implementation, add(payload, 0x20), mload(payload), 0, 0)
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
        if (size > MAX_STRATEGY_RETURN) {
            revert StrategyReturnTooLarge();
        }

        bytes memory ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0, size)
        }

        _dispatchBehaviorAction(localId, ctx, _decodeAction(ret));
    }

    /// @dev Canonical ABI for `returns (Action)` is `abi.encode(Action)`: outer offset 32,
    ///      then kind, data offset 64 relative to the tuple, length, padded data.
    ///      Size is `128 + pad32(len)`. Rejects truncated/odd encodings without `abi.decode`
    ///      (the decoder can Panic; try/catch cannot wrap it).
    function _decodeAction(bytes memory ret) private pure returns (Action memory a) {
        uint256 size = ret.length;
        if (size < 128) {
            revert InvalidStrategyReturn();
        }
        uint256 outer;
        uint256 kindWord;
        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            outer := mload(add(ret, 32))
            kindWord := mload(add(ret, 64))
            offset := mload(add(ret, 96))
            len := mload(add(ret, 128))
        }
        if (outer != 32 || kindWord > type(uint8).max || offset != 64) {
            revert InvalidStrategyReturn();
        }
        if (len > size - 128) {
            revert InvalidStrategyReturn();
        }
        uint256 padded = (len + 31) & ~uint256(31);
        if (size != 128 + padded) {
            revert InvalidStrategyReturn();
        }
        // kindWord was bounded to uint8 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.kind = uint8(kindWord);
        if (len == 0) {
            return a;
        }
        bytes memory data = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(data, 32), add(ret, 160), len)
        }
        a.data = data;
    }
}
