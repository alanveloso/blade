pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RequestHandler} from "./RequestHandler.sol";

contract RequestInvariantTest is Test {
    RequestHandler internal handler;

    function setUp() public {
        handler = new RequestHandler();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](6);
        sels[0] = RequestHandler.openAliceToBob.selector;
        sels[1] = RequestHandler.openBobToAlice.selector;
        sels[2] = RequestHandler.participantRespond.selector;
        sels[3] = RequestHandler.wrongPeerHandle.selector;
        sels[4] = RequestHandler.accWrongLogical.selector;
        sels[5] = RequestHandler.nativeLogicalSpoof.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_requestPhasesAndIsolation() public view {
        handler.assertRequestInvariants();
    }
}
