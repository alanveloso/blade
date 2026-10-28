pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ExampleParticipant, ExampleRequester} from "../../examples/RequestExample.sol";
import {
    ExampleManager,
    ExampleParticipant as ExampleCnParticipant
} from "../../examples/ContractNetExample.sol";
import {RequestPhase} from "../../src/core/RequestAgent.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";

contract ExampleTest is Test {
    function test_requestExampleInformDone() public {
        ExampleRequester requester = new ExampleRequester(address(0));
        ExampleParticipant participant = new ExampleParticipant(address(0));
        bytes32 id = keccak256("ex-req");
        requester.request(address(participant), id, hex"01");
        assertEq(uint8(requester.requestStatus(id).phase), uint8(RequestPhase.None));
        assertEq(uint8(participant.requestStatus(id).phase), uint8(RequestPhase.None));
    }

    function test_contractNetExampleProposeAcceptInform() public {
        ExampleManager manager = new ExampleManager(address(0));
        ExampleCnParticipant p = new ExampleCnParticipant(address(0));
        address[] memory parts = new address[](1);
        parts[0] = address(p);
        bytes32 id = keccak256("ex-cn");
        uint64 by = uint64(block.timestamp + 10);
        manager.cfp(parts, id, by);
        Message memory cfp;
        cfp.performative = uint8(Performative.Cfp);
        cfp.protocol = uint8(Protocol.FipaContractNet);
        cfp.conversationId = id;
        cfp.replyBy = by;
        p.propose(cfp, address(manager));
        vm.warp(by + 1);
        address[] memory accept = new address[](1);
        accept[0] = address(p);
        address[] memory none = new address[](0);
        manager.evaluate(id, accept, none, none);
        Message memory acceptMsg;
        acceptMsg.performative = uint8(Performative.AcceptProposal);
        acceptMsg.protocol = uint8(Protocol.FipaContractNet);
        acceptMsg.conversationId = id;
        acceptMsg.replyBy = by;
        p.informDone(acceptMsg, address(manager));
        assertEq(p.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.conversation(id).live, 0);
    }
}
