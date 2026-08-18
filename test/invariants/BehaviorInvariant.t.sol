pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BehaviorHandler} from "./BehaviorHandler.sol";

contract BehaviorInvariantTest is Test {
    BehaviorHandler internal handler;

    function setUp() public {
        handler = new BehaviorHandler();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](7);
        sels[0] = BehaviorHandler.installOneShot.selector;
        sels[1] = BehaviorHandler.installCyclic.selector;
        sels[2] = BehaviorHandler.uninstall.selector;
        sels[3] = BehaviorHandler.authorizedExplicit.selector;
        sels[4] = BehaviorHandler.unauthorizedExplicit.selector;
        sels[5] = BehaviorHandler.messageTrigger.selector;
        sels[6] = BehaviorHandler.boundedStep.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_behaviorMembershipLifetimeAndRollback() public view {
        handler.assertBehaviorInvariants();
    }
}
