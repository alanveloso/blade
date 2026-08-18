// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Opt-in local installation of reusable external application strategies.
/// @dev Capability mixin: does not inherit `Agent`. A concrete agent composes both.
/// @dev Application-external only. Not a protocol-role registry. `S` is not an AID.
/// @dev Map presence is membership (installed), not runnable/eligible. No progress store.
abstract contract ExternalApplicationBehaviorHost {
    /// @dev `address(0)` means not installed. Occupied ids must be uninstalled before reuse.
    mapping(bytes32 localId => address implementation) internal _behaviors;

    error InvalidLocalId();
    error InvalidImplementation();
    error AlreadyInstalled();
    error NotInstalled();

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
}
