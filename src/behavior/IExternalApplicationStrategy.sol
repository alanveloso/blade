// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Action} from "./Action.sol";
import {BehaviorContext} from "./Context.sol";

/// @dev Untrusted, reusable, stateless application strategy. Not a protocol-role API. Not an AID.
interface IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory);
}
