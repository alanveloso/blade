// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ScriptedRequestAgent} from "../Request.t.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {NetFixture} from "./Fixtures.sol";
import {RequestPhase} from "../../src/core/RequestAgent.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";

contract RequestInterleavingTest is Test {
    ScriptedRequestAgent alice;
    ScriptedRequestAgent bob;

    function setUp() public {
        alice = new ScriptedRequestAgent(address(0));
        bob = new ScriptedRequestAgent(address(0));
    }

    function _requestAt(bytes32 id) internal pure returns (Message memory m) {
        m.protocol = uint8(Protocol.FipaRequest);
        m.performative = uint8(Performative.Request);
        m.conversationId = id;
    }

    function _open(Message memory m) internal returns (Message memory) {
        alice.startRequest(address(bob), m);
        m.replyWith = alice.requestStatus(m.conversationId).replyWith;
        return m;
    }

    function _assertCleared(ScriptedRequestAgent actor, bytes32 id) internal view {
        assertEq(uint8(actor.requestStatus(id).phase), uint8(RequestPhase.None));
    }

    /// @dev 6 linear extensions of two independent Agree -> Inform chains, exhaustively.
    function test_allSixTwoSessionSchedules() public {
        uint8[4][6] memory schedules = [
            [uint8(0), 0, 1, 1],
            [uint8(0), 1, 0, 1],
            [uint8(0), 1, 1, 0],
            [uint8(1), 0, 0, 1],
            [uint8(1), 0, 1, 0],
            [uint8(1), 1, 0, 0]
        ];
        for (uint256 k; k < 6; ++k) {
            Message[2] memory reqs;
            reqs[0] = _open(_requestAt(bytes32(uint256(1))));
            reqs[1] = _open(_requestAt(bytes32(uint256(2))));
            uint8[2] memory steps;
            for (uint256 j; j < 4; ++j) {
                uint8 index = schedules[k][j];
                Message memory out;
                out.protocol = reqs[index].protocol;
                out.conversationId = reqs[index].conversationId;
                out.inReplyTo = reqs[index].replyWith;
                out.performative =
                    uint8(steps[index]++ == 0 ? Performative.Agree : Performative.Inform);
                bob.respond(reqs[index], address(alice), out);
                uint8 other = 1 - index;
                assertEq(
                    uint8(alice.requestStatus(reqs[other].conversationId).phase),
                    uint8(
                        steps[other] == 0
                            ? RequestPhase.Requested
                            : steps[other] == 1 ? RequestPhase.Agreed : RequestPhase.None
                    )
                );
            }
            _assertCleared(alice, reqs[0].conversationId);
            _assertCleared(bob, reqs[1].conversationId);
        }
    }
}

contract ContractNetInterleavingTest is NetFixture {
    function testFuzz_proposalOrderIndependent(bool reverse) public {
        (bytes32 id, Message memory cfp) =
            _open(_two(address(p1), address(p2)), uint64(block.timestamp + 100));
        if (reverse) {
            p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
            p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        } else {
            p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
            p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        }
        vm.warp(block.timestamp + 101);
        manager.evaluate(id, _one(address(p1)), _one(address(p2)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_NONE);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
        assertEq(manager.conversation(id).live, 0);
    }

    function test_deadlineOrderChangesOutcome() public {
        uint64 deadline = uint64(block.timestamp + 100);
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), deadline);
        uint256 snapshot = vm.snapshotState();
        vm.warp(deadline);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(uint256(deadline) + 1);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
    }
}
