pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetHandler} from "./ContractNetHandler.sol";

contract ContractNetInvariantTest is Test {
    ContractNetHandler internal handler;

    function setUp() public {
        handler = new ContractNetHandler();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](8);
        sels[0] = ContractNetHandler.cfp.selector;
        sels[1] = ContractNetHandler.respond.selector;
        sels[2] = ContractNetHandler.warpAroundDeadline.selector;
        sels[3] = ContractNetHandler.evaluate.selector;
        sels[4] = ContractNetHandler.strangerPropose.selector;
        sels[5] = ContractNetHandler.expire.selector;
        sels[6] = ContractNetHandler.tryInvalidParticipants.selector;
        sels[7] = ContractNetHandler.rogueDirectHandle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_contractNetLiveSlotsAndIsolation() public view {
        handler.assertContractNetInvariants();
    }

    /// @dev Guards against a silently neutered campaign: the handler's happy path must mutate.
    function test_handlerHappyPathMutates() public {
        handler.cfp(0, 15);
        handler.respond(0, 0, 0);
        handler.rogueDirectHandle(0, 2);
        handler.warpAroundDeadline(0, 2);
        handler.evaluate(0, 0);
        assertEq(handler.successfulMutations(), 4);
        handler.assertContractNetInvariants();
    }
}
