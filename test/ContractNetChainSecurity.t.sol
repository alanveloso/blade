pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Agent} from "../src/core/Agent.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {
    ExposedContractNetManager,
    ExposedContractNetParticipant,
    OwnerGatedContractNetManager
} from "./ContractNetActors.sol";

/// @dev Blockchain-specific properties of Contract Net: ordering, deadlines, `block.timestamp`,
/// third-party calls, completed conversations, isolation, and what the Core does *not* protect
/// (front-running, proposal confidentiality).
contract ContractNetChainSecurityTest is Test {
    ExposedContractNetManager internal manager;
    ExposedContractNetParticipant[3] internal ps;

    uint64 internal constant WINDOW = 1_000;

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new ExposedContractNetManager(address(0));
        for (uint256 i = 0; i < 3; i++) {
            ps[i] = new ExposedContractNetParticipant(address(0));
        }
    }

    function _cfp(bytes32 id, uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        m.replyWith = keccak256(abi.encodePacked(id, "rw"));
        m.replyBy = replyBy;
        m.content = hex"0b1d";
    }

    function _out(Message memory inbound, Performative act)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(act);
        m.protocol = inbound.protocol;
        m.conversationId = inbound.conversationId;
        m.inReplyTo = inbound.replyWith;
    }

    function _raw(bytes32 id, uint8 act) internal pure returns (Message memory m) {
        m.performative = act;
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
    }

    function _empty() internal pure returns (address[] memory a) {}

    function _one(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _all() internal view returns (address[] memory a) {
        a = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            a[i] = address(ps[i]);
        }
    }

    function _pack(bytes32 id) internal view returns (bytes32 h) {
        h = keccak256(abi.encode(manager.conversation(id)));
        for (uint256 i = 0; i < 3; i++) {
            h = keccak256(abi.encode(h, manager.slotOf(id, address(ps[i])), ps[i].session(id)));
        }
    }

    function _slots(bytes32 id) internal view returns (uint8[3] memory s) {
        for (uint256 i = 0; i < 3; i++) {
            s[i] = manager.slotOf(id, address(ps[i]));
        }
    }

    // --- Ordering of proposals ---

    /// @dev The Core FSM is order-independent: the same set of responses in any order yields the
    /// same manager state. (Selection among proposals is application policy, not Core.)
    function testFuzz_order_responsesCommute(uint256 seed) public {
        bytes32 idA = keccak256("ord-a");
        bytes32 idB = keccak256("ord-b");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfpA = _cfp(idA, by);
        Message memory cfpB = _cfp(idB, by);
        manager.cfp(_all(), cfpA);
        manager.cfp(_all(), cfpB);

        Performative[3] memory acts;
        for (uint256 i = 0; i < 3; i++) {
            acts[i] = (seed >> i) & 1 == 0 ? Performative.Propose : Performative.Refuse;
        }
        uint256[3] memory order = [uint256(0), 1, 2];
        uint256 r = seed >> 8;
        for (uint256 i = 2; i > 0; i--) {
            uint256 j = r % (i + 1);
            r /= 3;
            (order[i], order[j]) = (order[j], order[i]);
        }
        for (uint256 i = 0; i < 3; i++) {
            ps[i].respond(cfpA, address(manager), _out(cfpA, acts[i]));
        }
        for (uint256 k = 0; k < 3; k++) {
            uint256 i = order[k];
            ps[i].respond(cfpB, address(manager), _out(cfpB, acts[i]));
        }
        assertEq(abi.encode(_slots(idA)), abi.encode(_slots(idB)));
        assertEq(manager.conversation(idA).live, manager.conversation(idB).live);
    }

    // --- Deadline boundary ---

    function testFuzz_deadline_proposalTimelyIffNotAfterReplyBy(uint16 delta, bool after_) public {
        bytes32 id = keccak256("dl-fuzz");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(ps[0])), cfp);
        uint256 t = after_ ? uint256(by) + 1 + uint256(delta) : uint256(by) - (delta % WINDOW);
        vm.warp(t);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        if (t <= by) {
            assertEq(manager.slotOf(id, address(ps[0])), ContractNetLib.SLOT_PROPOSED);
            assertEq(ps[0].session(id).phase, ContractNetLib.PART_PROPOSED);
        } else {
            assertEq(manager.slotOf(id, address(ps[0])), ContractNetLib.SLOT_NONE);
            assertEq(ps[0].session(id).phase, ContractNetLib.PART_NONE);
            assertEq(manager.conversation(id).live, 0);
        }
    }

    /// @dev Within one block (one `block.timestamp`) a proposal can be accepted as timely or the
    /// evaluation can run, never both: block-internal ordering cannot slip a proposal past an
    /// evaluation or evaluate before a timely proposal lands.
    function testFuzz_deadline_timelyProposalAndEvaluationMutuallyExclusive(uint16 offset) public {
        bytes32 id = keccak256("dl-excl");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_all(), cfp);
        ps[1].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        uint256 t = uint256(by) - WINDOW + 1 + (uint256(offset) % (2 * WINDOW));
        vm.warp(t);

        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        bool timely = manager.slotOf(id, address(ps[0])) == ContractNetLib.SLOT_PROPOSED;

        address[] memory accept = new address[](timely ? 2 : 1);
        accept[0] = address(ps[1]);
        if (timely) {
            accept[1] = address(ps[0]);
        }
        (bool evaluated,) = address(manager)
            .call(abi.encodeCall(manager.evaluate, (id, accept, _empty(), _one(address(ps[2])))));
        assertTrue(timely != evaluated, "timely proposal and evaluation in the same block");
        assertEq(timely, t <= by);
    }

    /// @dev Validator timestamp choice. With a drift bound D (chain-specific), a proposal whose
    /// honest inclusion time t satisfies |t - replyBy| > D has the same outcome for every
    /// timestamp in [t - D, t + D]; only proposals inside the D-window around the deadline can be
    /// flipped. The Core cannot prevent such flips; applications choose deadline margins.
    function testFuzz_timestamp_manipulationOnlyAffectsDriftWindow(uint16 rawT, uint8 rawD) public {
        uint64 by = uint64(block.timestamp + WINDOW);
        uint256 d = uint256(rawD) % 31;
        uint256 t = uint256(by) - WINDOW + 1 + (uint256(rawT) % (2 * WINDOW));
        bool[3] memory outcome;
        uint256[3] memory times = [t - d, t, t + d];
        for (uint256 k = 0; k < 3; k++) {
            uint256 snap = vm.snapshotState();
            bytes32 id = keccak256("ts-manip");
            Message memory cfp = _cfp(id, by);
            manager.cfp(_one(address(ps[0])), cfp);
            vm.warp(times[k]);
            ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
            outcome[k] = manager.slotOf(id, address(ps[0])) == ContractNetLib.SLOT_PROPOSED;
            vm.revertToState(snap);
        }
        if (t + d <= by || (t > d && t - d > by)) {
            assertEq(outcome[0], outcome[1]);
            assertEq(outcome[1], outcome[2]);
        }
        for (uint256 k = 0; k < 3; k++) {
            assertEq(outcome[k], times[k] <= by);
        }
    }

    function test_timestamp_boundaryFlipByOneSecond() public {
        bytes32 id = keccak256("ts-flip");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(ps[0])), cfp);
        uint256 snap = vm.snapshotState();
        vm.warp(by);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(ps[0])), ContractNetLib.SLOT_PROPOSED);
        vm.revertToState(snap);
        vm.warp(uint256(by) + 1);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(ps[0])), ContractNetLib.SLOT_NONE);
    }

    // --- Evaluation not executed after the deadline ---

    function test_noEvaluate_lateProposalsKeepBeingRejected() public {
        bytes32 id = keccak256("ne-late");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_all(), cfp);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 30 days);
        ps[1].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(ps[1])), ContractNetLib.SLOT_NONE);
        assertEq(manager.slotOf(id, address(ps[0])), ContractNetLib.SLOT_PROPOSED);
        assertFalse(manager.conversation(id).evaluated);
        assertEq(manager.conversation(id).live, 2);
        manager.evaluate(id, _one(address(ps[0])), _empty(), _one(address(ps[2])));
        assertEq(manager.slotOf(id, address(ps[0])), ContractNetLib.SLOT_ACCEPTED);
    }

    // --- Third-party calls ---

    /// @dev `_evaluate` is caller-agnostic by design. A permissive wrapper lets any account pick
    /// the winners; authorization is an application obligation.
    function test_thirdParty_permissiveWrapperLetsAnyonePickWinners() public {
        bytes32 id = keccak256("tp-open");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_all(), cfp);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        ps[1].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.prank(address(0xBAD));
        manager.evaluate(id, _one(address(ps[1])), _one(address(ps[0])), _one(address(ps[2])));
        assertEq(manager.slotOf(id, address(ps[1])), ContractNetLib.SLOT_ACCEPTED);
    }

    function test_thirdParty_gatedWrapperRejectsThirdParty() public {
        OwnerGatedContractNetManager gated = new OwnerGatedContractNetManager();
        bytes32 id = keccak256("tp-gated");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        vm.prank(address(0xBAD));
        vm.expectRevert(OwnerGatedContractNetManager.NotOwner.selector);
        gated.cfp(_one(address(ps[0])), cfp);
        gated.cfp(_one(address(ps[0])), cfp);
        ps[0].respond(cfp, address(gated), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.prank(address(0xBAD));
        vm.expectRevert(OwnerGatedContractNetManager.NotOwner.selector);
        gated.evaluate(id, _one(address(ps[0])), _empty(), _empty());
        assertFalse(gated.conversation(id).evaluated);
        gated.evaluate(id, _one(address(ps[0])), _empty(), _empty());
        assertEq(gated.slotOf(id, address(ps[0])), ContractNetLib.SLOT_ACCEPTED);
    }

    function testFuzz_thirdParty_cannotActForParticipants(address caller, uint8 act) public {
        vm.assume(caller != address(ps[0]) && caller != address(ps[1]) && caller != address(ps[2]));
        bytes32 id = keccak256("tp-impersonate");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_all(), cfp);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        bytes32 before = _pack(id);
        vm.prank(caller);
        (bool ok,) = address(manager).call(abi.encodeCall(manager.handle, (_raw(id, act))));
        assertFalse(ok);
        assertEq(_pack(id), before);
    }

    // --- Completed conversations ---

    function test_completed_noActModifiesFinishedConversation() public {
        bytes32 id = keccak256("done");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_all(), cfp);
        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        ps[1].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(ps[0])), _one(address(ps[1])), _one(address(ps[2])));

        // Evaluated, still live for the accepted participant: others cannot act.
        bytes32 live = _pack(id);
        for (uint8 act = 0; act <= uint8(Performative.RejectProposal); act++) {
            for (uint256 i = 1; i < 3; i++) {
                vm.prank(address(ps[i]));
                (bool ok,) = address(manager).call(abi.encodeCall(manager.handle, (_raw(id, act))));
                assertFalse(ok);
            }
        }
        assertEq(_pack(id), live);
        // The silent participant (still CFPED locally) cannot propose after evaluation.
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        ps[2].respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(ps[2].session(id).phase, ContractNetLib.PART_CFPED);

        ps[0].respond(cfp, address(manager), _out(cfp, Performative.Inform));
        assertEq(manager.conversation(id).live, 0);

        bytes32 done = _pack(id);
        for (uint8 act = 0; act <= uint8(Performative.RejectProposal); act++) {
            for (uint256 i = 0; i < 3; i++) {
                vm.prank(address(ps[i]));
                vm.expectRevert(ContractNetLib.InvalidTransition.selector);
                manager.handle(_raw(id, act));
            }
        }
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _empty(), _empty(), _empty());
        assertEq(_pack(id), done);
    }

    // --- Isolation between simultaneous conversations ---

    function testFuzz_isolation_actionsOnOneConversationLeaveOtherUntouched(uint256 seed) public {
        bytes32 a = keccak256("iso-a");
        bytes32 b = keccak256("iso-b");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfpA = _cfp(a, by);
        Message memory cfpB = _cfp(b, by);
        manager.cfp(_all(), cfpA);
        manager.cfp(_all(), cfpB);
        ps[0].respond(cfpB, address(manager), _out(cfpB, Performative.Propose));
        bytes32 beforeB = _pack(b);
        for (uint256 step = 0; step < 12; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 who = r % 3;
            uint256 kind = (r >> 8) % 6;
            if (kind == 0) {
                vm.warp(block.timestamp + ((r >> 16) % (WINDOW / 2)));
            } else if (kind == 5) {
                vm.prank(address(ps[who]));
                (bool ok,) = address(manager)
                    .call(abi.encodeCall(manager.handle, (_raw(a, uint8((r >> 24) % 11)))));
                ok;
            } else {
                Performative act = [
                    Performative.Propose,
                    Performative.Refuse,
                    Performative.NotUnderstood,
                    Performative.Inform
                ][kind - 1];
                (bool ok,) = address(ps[who])
                    .call(
                        abi.encodeCall(ps[who].respond, (cfpA, address(manager), _out(cfpA, act)))
                    );
                ok;
            }
            assertEq(_pack(b), beforeB, "sibling conversation mutated");
        }
    }

    // --- Not protected by the Core (documented limitations) ---

    /// @dev LIMITATION: participant sessions are keyed by `conversationId` only. A third contract
    /// that learns a pending id can CFP the participant first; the honest CFP then reverts as a
    /// whole. Mitigations are application-level (`_authorizeInbound`, unpredictable ids).
    function test_frontrun_cfpSquattingBlocksHonestManager() public {
        ExposedContractNetManager eve = new ExposedContractNetManager(address(0));
        bytes32 id = keccak256("squat");
        uint64 by = uint64(block.timestamp + WINDOW);
        eve.cfp(_one(address(ps[0])), _cfp(id, by));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        manager.cfp(_all(), _cfp(id, by));
        assertEq(manager.conversation(id).live, 0);
        assertEq(ps[1].session(id).phase, ContractNetLib.PART_NONE);
    }

    /// @dev LIMITATION: proposals are public. Content travels in calldata and in the `Received`
    /// event; the Core implements no commit-reveal, so it does not prevent front-running or
    /// copying of proposals.
    function test_privacy_proposalContentIsPublic() public {
        bytes32 id = keccak256("public");
        uint64 by = uint64(block.timestamp + WINDOW);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(ps[0])), cfp);
        Message memory prop = _out(cfp, Performative.Propose);
        prop.content = hex"5ec2e7";
        vm.expectEmit(true, true, false, true, address(manager));
        emit Agent.Received(
            address(ps[0]),
            id,
            bytes32(0),
            prop.performative,
            prop.protocol,
            prop.replyWith,
            prop.inReplyTo,
            prop.replyBy,
            hex"5ec2e7"
        );
        ps[0].respond(cfp, address(manager), prop);
    }
}
