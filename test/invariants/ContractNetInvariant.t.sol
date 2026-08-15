pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetHandler} from "./ContractNetHandler.sol";

contract ContractNetInvariantTest is Test {
    ContractNetHandler internal handler;

    function setUp() public {
        handler = new ContractNetHandler();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](7);
        sels[0] = ContractNetHandler.cfp.selector;
        sels[1] = ContractNetHandler.respond.selector;
        sels[2] = ContractNetHandler.warpAroundDeadline.selector;
        sels[3] = ContractNetHandler.evaluate.selector;
        sels[4] = ContractNetHandler.strangerPropose.selector;
        sels[5] = ContractNetHandler.expire.selector;
        sels[6] = ContractNetHandler.tryInvalidParticipants.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_contractNetLiveSlotsAndIsolation() public view {
        handler.assertContractNetInvariants();
    }
}
