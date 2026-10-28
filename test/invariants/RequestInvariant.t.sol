pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RequestHandler} from "./RequestHandler.sol";

contract RequestInvariantTest is Test {
    RequestHandler internal handler;

    function setUp() public {
        handler = new RequestHandler();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = RequestHandler.openAliceToBob.selector;
        sels[1] = RequestHandler.openBobToAlice.selector;
        sels[2] = RequestHandler.participantRespond.selector;
        sels[3] = RequestHandler.wrongPeerHandle.selector;
        sels[4] = RequestHandler.relayWrongLogical.selector;
        sels[5] = RequestHandler.nativeLogicalSpoof.selector;
        sels[6] = RequestHandler.staleTokenReply.selector;
        sels[7] = RequestHandler.wrongTokenReply.selector;
        sels[8] = RequestHandler.forgedInboundRespond.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_requestPhasesAndIsolation() public view {
        handler.assertRequestInvariants();
    }

    /// @dev Guards against a silently neutered campaign: the handler's happy path must mutate.
    function test_handlerHappyPathMutates() public {
        handler.openAliceToBob(0);
        handler.participantRespond(0, 0);
        handler.participantRespond(0, 2);
        handler.openAliceToBob(0);
        handler.staleTokenReply(0, 2, 0);
        handler.wrongTokenReply(0, 2, keccak256("w"));
        handler.forgedInboundRespond(0, 2, keccak256("f"));
        assertEq(handler.successfulMutations(), 4);
        handler.assertRequestInvariants();
    }
}
