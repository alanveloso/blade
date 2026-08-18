// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExternalApplicationBehaviorHost} from "./ExternalApplicationBehaviorHost.sol";
import {BehaviorContext} from "./Context.sol";

/// @title Reactive application-behavior step (v0).
/// @dev Not an autonomous scheduler. Not a protocol-role runtime. Does not inherit `Agent`.
/// @dev v0 selection is `installed == selected` (insertion order). Not a general BLADE claim.
/// @dev `stepGas` is the aggregate requested STATICCALL ceiling for strategies, not transaction gas.
/// @dev v0 lifetime is one-shot: after a fully successful step, each snapshot id is
///      uninstalled iff `_completesAfterSuccess(id)` (default `true`). Trusted engine
///      policy, not strategy `done()`.
abstract contract BehaviorEngine is ExternalApplicationBehaviorHost {
    /// @dev Operational walk/storage cap for this engine. Not a semantic maximum of the agent model.
    uint256 internal constant MAX_INSTALLED_APPLICATION_BEHAVIORS = 8;
    /// @dev Defensive loop reserve so the engine can finish or emit a BLADE error. Not scheduling policy.
    uint256 internal constant ENGINE_OVERHEAD = 80_000;

    bytes32[] internal _orderedBehaviorIds;

    error TooManyBehaviors();
    error InvalidStepGas();
    error InvalidBehaviorIndex();

    function installedBehaviorCount() public view returns (uint256) {
        return _orderedBehaviorIds.length;
    }

    function installedBehaviorAt(uint256 index) public view returns (bytes32) {
        if (index >= _orderedBehaviorIds.length) {
            revert InvalidBehaviorIndex();
        }
        return _orderedBehaviorIds[index];
    }

    function _installBehavior(bytes32 localId, address implementation) internal virtual override {
        if (_orderedBehaviorIds.length >= MAX_INSTALLED_APPLICATION_BEHAVIORS) {
            revert TooManyBehaviors();
        }
        super._installBehavior(localId, implementation);
        _orderedBehaviorIds.push(localId);
    }

    function _uninstallBehavior(bytes32 localId) internal virtual override {
        super._uninstallBehavior(localId);
        _removePreservingOrder(localId);
    }

    /// @dev Trusted engine lifetime policy. Not strategy `done()`. This slice: all true.
    function _completesAfterSuccess(bytes32) internal view virtual returns (bool) {
        return true;
    }

    /// @dev One explicit trigger. Does not dispatch from `handle`. Fail-fast; never `gas()`.
    function _runBehaviorStep(BehaviorContext memory ctx, uint256 stepGas) internal {
        uint256 n = _orderedBehaviorIds.length;
        if (n == 0) {
            return;
        }
        if (stepGas == 0) {
            revert InvalidStepGas();
        }
        uint256 per = stepGas / n;
        if (per == 0) {
            revert InvalidStepGas();
        }

        uint256 remaining = gasleft();
        if (remaining <= ENGINE_OVERHEAD) {
            revert InvalidStepGas();
        }
        uint256 usable = remaining - ENGINE_OVERHEAD;
        if (POST_CALL_OVERHEAD > type(uint256).max / n) {
            revert InvalidStepGas();
        }
        uint256 hostReserve = n * POST_CALL_OVERHEAD;
        if (usable <= hostReserve || stepGas > usable - hostReserve) {
            revert InvalidStepGas();
        }

        bytes32[] memory snapshot = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            snapshot[i] = _orderedBehaviorIds[i];
        }

        for (uint256 i = 0; i < n; ++i) {
            _runExternalBehavior(snapshot[i], ctx, per);
        }

        for (uint256 i = 0; i < n; ++i) {
            if (_completesAfterSuccess(snapshot[i])) {
                _uninstallBehavior(snapshot[i]);
            }
        }
    }

    function _removePreservingOrder(bytes32 localId) private {
        uint256 n = _orderedBehaviorIds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_orderedBehaviorIds[i] == localId) {
                for (uint256 j = i; j + 1 < n; ++j) {
                    _orderedBehaviorIds[j] = _orderedBehaviorIds[j + 1];
                }
                _orderedBehaviorIds.pop();
                return;
            }
        }
    }
}
