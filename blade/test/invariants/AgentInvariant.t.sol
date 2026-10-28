pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentHandler} from "./AgentHandler.sol";

contract AgentInvariantTest is Test {
    AgentHandler internal handler;

    function setUp() public {
        handler = new AgentHandler();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = AgentHandler.handleNative.selector;
        sels[1] = AgentHandler.handleWithRelay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_logicalSenderAndPayload() public view {
        handler.assertAgentInvariants();
    }
}
