// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExternalApplicationBehaviorHost} from "./ExternalApplicationBehaviorHost.sol";
import {BehaviorContext, BehaviorFilter, FilterLib, ContextLib} from "./Context.sol";

/// @title Reactive application-behavior step (v0).
/// @dev Not an autonomous scheduler. Not a protocol-role runtime. Does not inherit `Agent`.
/// @dev Default selection is still the full pool (any-filter). An installation may restrict
///      trigger, protocol, and/or performative; ineligible ids are not called.
/// @dev `stepGas` is the aggregate requested STATICCALL ceiling for strategies, not transaction gas.
/// @dev v0 lifetimes are per installation, not per strategy address: `_installBehavior` is
///      OneShot; `_installCyclicBehavior` stays in the pool across explicit steps.
///      After a fully successful step, each snapshot id is uninstalled iff
///      `_completesAfterSuccess(id)` (`!_cyclic[id]`). Trusted engine policy, not strategy `done()`.
abstract contract BehaviorEngine is ExternalApplicationBehaviorHost {
    /// @dev Operational walk/storage cap for this engine. Not a semantic maximum of the agent model.
    uint256 internal constant MAX_INSTALLED_APPLICATION_BEHAVIORS = 8;
    /// @dev Defensive loop reserve so the engine can finish or emit a BLADE error. Not scheduling policy.
    uint256 internal constant ENGINE_OVERHEAD = 80_000;

    bytes32[] internal _orderedBehaviorIds;
    /// @dev Installation lifetime. Absent/false = OneShot. Not a property of the strategy.
    mapping(bytes32 localId => bool cyclic) internal _cyclic;
    mapping(bytes32 localId => BehaviorFilter filter) internal _filters;
    /// @dev Resume for `_runBehaviorStepAtMost` when k < n. Unused by walk-all.
    uint256 internal _resumeIndex;

    error TooManyBehaviors();
    error InvalidStepGas();
    error InvalidBehaviorIndex();
    error InvalidMaxToRun();

    function installedBehaviorCount() public view returns (uint256) {
        return _orderedBehaviorIds.length;
    }

    function installedBehaviorAt(uint256 index) public view returns (bytes32) {
        if (index >= _orderedBehaviorIds.length) {
            revert InvalidBehaviorIndex();
        }
        return _orderedBehaviorIds[index];
    }

    function behaviorFilter(bytes32 localId) public view returns (BehaviorFilter memory) {
        return _filters[localId];
    }

    function _installBehavior(bytes32 localId, address implementation) internal virtual override {
        _installFilteredBehavior(localId, implementation, FilterLib.anyFilter());
    }

    function _installFilteredBehavior(
        bytes32 localId,
        address implementation,
        BehaviorFilter memory filter
    ) internal {
        FilterLib.validate(filter);
        if (_orderedBehaviorIds.length >= MAX_INSTALLED_APPLICATION_BEHAVIORS) {
            revert TooManyBehaviors();
        }
        super._installBehavior(localId, implementation);
        _filters[localId] = filter;
        _orderedBehaviorIds.push(localId);
    }

    function _uninstallBehavior(bytes32 localId) internal virtual override {
        _clearBehaviorRecord(localId);
        _removePreservingOrder(localId);
    }

    /// @dev Same per-id cleanup as explicit uninstall (implementation mapping, event, `_cyclic`).
    ///      Does not touch `_orderedBehaviorIds`. Step completion uses this plus one compact pass.
    function _clearBehaviorRecord(bytes32 localId) private {
        super._uninstallBehavior(localId);
        delete _cyclic[localId];
        delete _filters[localId];
    }

    /// @dev Opt-in stay-in-pool lifetime. Reuses membership/cap/order from `_installBehavior`.
    function _installCyclicBehavior(bytes32 localId, address implementation) internal {
        _installCyclicBehavior(localId, implementation, FilterLib.anyFilter());
    }

    function _installCyclicBehavior(
        bytes32 localId,
        address implementation,
        BehaviorFilter memory filter
    ) internal {
        _installFilteredBehavior(localId, implementation, filter);
        _cyclic[localId] = true;
    }

    /// @dev Trusted engine lifetime policy. Not strategy `done()`.
    function _completesAfterSuccess(bytes32 localId) internal view virtual returns (bool) {
        return !_cyclic[localId];
    }

    /// @dev One trigger. Does not dispatch from `handle`. Fail-fast; never `gas()`.
    ///      Only filter-eligible installations run. Empty eligible set is a no-op.
    function _runBehaviorStep(BehaviorContext memory ctx, uint256 stepGas) internal {
        if (_orderedBehaviorIds.length > 0) {
            ContextLib.validate(ctx);
        }
        _runSelected(ctx, _eligibleFrom(ctx, 0), stepGas);
    }

    /// @dev Bounded window on an already-triggered step. Not `handle` dispatch. Not a JADE scheduler.
    ///      Empty pool is a no-op. `maxToRun == 0` with `n > 0` reverts `InvalidMaxToRun`.
    ///      Window size is among **eligible** ids. `maxToRun >= eligible` is filtered walk-all
    ///      and does not move `_resumeIndex`.
    function _runBehaviorStepAtMost(BehaviorContext memory ctx, uint256 stepGas, uint256 maxToRun)
        internal
    {
        uint256 n = _orderedBehaviorIds.length;
        if (n == 0) {
            return;
        }
        if (maxToRun == 0) {
            revert InvalidMaxToRun();
        }
        ContextLib.validate(ctx);
        uint256 start = _resumeIndex % n;
        bytes32[] memory eligible = _eligibleFrom(ctx, start);
        uint256 e = eligible.length;
        if (e == 0) {
            return;
        }
        if (maxToRun >= e) {
            _runSelected(ctx, eligible, stepGas);
            return;
        }

        bytes32[] memory selected = new bytes32[](maxToRun);
        for (uint256 i = 0; i < maxToRun; ++i) {
            selected[i] = eligible[i];
        }
        bytes32 nextId = eligible[maxToRun];
        _runSelected(ctx, selected, stepGas);
        _resumeIndex = _indexOfInstalled(nextId);
    }

    function _runSelected(BehaviorContext memory ctx, bytes32[] memory selected, uint256 stepGas)
        private
    {
        uint256 n = selected.length;
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

        for (uint256 i = 0; i < n; ++i) {
            _runExternalBehavior(selected[i], ctx, per);
        }

        _compactCompletedSelected(selected);
    }

    /// @dev Eligible ids in pool order, starting at `start` and wrapping.
    function _eligibleFrom(BehaviorContext memory ctx, uint256 start)
        private
        view
        returns (bytes32[] memory selected)
    {
        uint256 n = _orderedBehaviorIds.length;
        if (n == 0) {
            return selected;
        }
        bytes32[] memory buf = new bytes32[](n);
        uint256 m;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 localId = _orderedBehaviorIds[(start + i) % n];
            if (FilterLib.matches(_filters[localId], ctx)) {
                buf[m] = localId;
                ++m;
            }
        }
        selected = new bytes32[](m);
        for (uint256 i = 0; i < m; ++i) {
            selected[i] = buf[i];
        }
    }

    /// @dev Compact the **full** pool, removing only selected ids that complete after this step.
    ///      Unselected members stay, even OneShots. Preserves relative order of survivors.
    ///      If no selected id completes, the ordered array is left untouched.
    function _compactCompletedSelected(bytes32[] memory selected) private {
        bool anyCompletes;
        for (uint256 i = 0; i < selected.length; ++i) {
            if (_completesAfterSuccess(selected[i])) {
                anyCompletes = true;
                break;
            }
        }
        if (!anyCompletes) {
            return;
        }

        uint256 writeIndex;
        uint256 n = _orderedBehaviorIds.length;
        bool allSelected = selected.length == n;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 localId = _orderedBehaviorIds[i];
            if ((allSelected || _isSelected(localId, selected)) && _completesAfterSuccess(localId))
            {
                _clearBehaviorRecord(localId);
            } else {
                if (writeIndex != i) {
                    _orderedBehaviorIds[writeIndex] = localId;
                }
                ++writeIndex;
            }
        }
        while (_orderedBehaviorIds.length > writeIndex) {
            _orderedBehaviorIds.pop();
        }
    }

    function _isSelected(bytes32 localId, bytes32[] memory selected) private pure returns (bool) {
        for (uint256 i = 0; i < selected.length; ++i) {
            if (selected[i] == localId) {
                return true;
            }
        }
        return false;
    }

    function _indexOfInstalled(bytes32 localId) private view returns (uint256) {
        uint256 n = _orderedBehaviorIds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_orderedBehaviorIds[i] == localId) {
                return i;
            }
        }
        revert InvalidBehaviorIndex();
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
