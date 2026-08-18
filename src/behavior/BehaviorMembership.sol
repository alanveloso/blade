// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Shared membership/authorship errors for application-behavior mixins.
/// @dev Not a unified product API. External and embedded remain distinct trust loci.
abstract contract BehaviorMembership {
    error InvalidLocalId();
    error AlreadyInstalled();
    error NotInstalled();
    error ContextAgentMismatch();
}
