pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {
    AutoCompleteParticipant,
    BatchingContractNetManager,
    ExposedContractNetManager,
    ExposedContractNetParticipant,
    GasBurnerParticipant,
    RevertOnAcceptParticipant,
    RevertOnDecisionParticipant
} from "./ContractNetActors.sol";

/// @dev Progress (liveness) under non-cooperative participants. These tests reproduce the
/// limitations documented in `docs/SECURITY.md`; they assert current behaviour, not a fix.
contract ContractNetLivenessTest is Test {
    ExposedContractNetManager internal manager;
    ExposedContractNetParticipant internal p1;
    ExposedContractNetParticipant internal p2;

    function setUp() public {
        manager = new ExposedContractNetManager(address(0));
        p1 = new ExposedContractNetParticipant(address(0));
        p2 = new ExposedContractNetParticipant(address(0));
        vm.warp(1_700_000_000);
    }

    function _cfp(bytes32 id, uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        m.replyWith = keccak256(abi.encodePacked(id, "rw"));
        m.replyBy = replyBy;
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

    function _empty() internal pure returns (address[] memory a) {}

    function _one(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _two(address x, address y) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = x;
        a[1] = y;
    }

    function _three(address x, address y, address z) internal pure returns (address[] memory a) {
        a = new address[](3);
        a[0] = x;
        a[1] = y;
        a[2] = z;
    }

    function _pack(bytes32 id, address[] memory parts) internal view returns (bytes32 h) {
        h = keccak256(abi.encode(manager.conversation(id)));
        for (uint256 i = 0; i < parts.length; i++) {
            h = keccak256(abi.encode(h, manager.slotOf(id, parts[i])));
            h = keccak256(abi.encode(h, ExposedContractNetParticipant(parts[i]).session(id).phase));
        }
    }

    /// @dev Opens `id` with `parts`, has each of them propose, and closes the window.
    function _proposeAll(bytes32 id, address[] memory parts) internal returns (Message memory cfp) {
        uint64 by = uint64(block.timestamp + 100);
        cfp = _cfp(id, by);
        manager.cfp(parts, cfp);
        for (uint256 i = 0; i < parts.length; i++) {
            ExposedContractNetParticipant(parts[i])
                .respond(cfp, address(manager), _out(cfp, Performative.Propose));
        }
        vm.warp(uint256(by) + 1);
    }

    // --- Revert on AcceptProposal ---

    function test_live_revertOnAcceptBlocksEvaluateForAll() public {
        RevertOnAcceptParticipant bad = new RevertOnAcceptParticipant();
        bytes32 id = keccak256("lv-revert-accept");
        address[] memory parts = _two(address(p1), address(bad));
        _proposeAll(id, parts);
        bytes32 before = _pack(id, parts);
        vm.expectRevert(bytes("accept-handle-revert"));
        manager.evaluate(id, parts, _empty(), _empty());
        assertEq(_pack(id, parts), before, "honest participant affected by rollback");
    }

    /// @dev Existing recovery path: the manager can route the griefer to `reject`.
    function test_live_revertOnAcceptRecoverableByRejecting() public {
        RevertOnAcceptParticipant bad = new RevertOnAcceptParticipant();
        bytes32 id = keccak256("lv-revert-accept-recover");
        _proposeAll(id, _two(address(p1), address(bad)));
        vm.expectRevert(bytes("accept-handle-revert"));
        manager.evaluate(id, _one(address(bad)), _one(address(p1)), _empty());
        manager.evaluate(id, _one(address(p1)), _one(address(bad)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(id, address(bad)), ContractNetLib.SLOT_NONE);
        assertEq(manager.conversation(id).live, 1);
    }

    /// @dev LIMITATION: a proposer that reverts on every decision makes every admissible
    /// partition revert; the manager conversation can never be evaluated or cleared.
    function test_live_revertOnEveryDecisionStallsConversation() public {
        RevertOnDecisionParticipant bad = new RevertOnDecisionParticipant();
        bytes32 id = keccak256("lv-stall");
        address[] memory parts = _two(address(p1), address(bad));
        Message memory cfp = _proposeAll(id, parts);
        bytes32 before = _pack(id, parts);

        vm.expectRevert(bytes("decision-revert"));
        manager.evaluate(id, _one(address(bad)), _one(address(p1)), _empty());
        vm.expectRevert(bytes("decision-revert"));
        manager.evaluate(id, _one(address(p1)), _one(address(bad)), _empty());
        vm.expectRevert(bytes("decision-revert"));
        manager.evaluate(id, _empty(), parts, _empty());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _one(address(bad)));
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(_pack(id, parts), before);

        // The id cannot be reused while the stalled conversation is live.
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.cfp(_one(address(p2)), _cfp(id, uint64(block.timestamp + 100)));

        // The honest participant cannot `expire` a PROPOSED session, but it can withdraw with
        // not-understood, which the manager accepts from any slot.
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        p1.respond(cfp, address(manager), _out(cfp, Performative.NotUnderstood));
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(manager.conversation(id).live, 1);

        // The griefer still blocks the manager side.
        vm.expectRevert(bytes("decision-revert"));
        manager.evaluate(id, _empty(), _one(address(bad)), _empty());
        assertEq(manager.slotOf(id, address(bad)), ContractNetLib.SLOT_PROPOSED);
    }

    // --- Gas consumption on AcceptProposal ---

    /// @dev Unbounded loop: every forwarded gas unit is burnt, the callee runs out of gas, and
    /// the failure propagates; no gas limit lets the evaluation through.
    function test_live_unboundedGasBurnerBlocksEvaluate() public {
        GasBurnerParticipant burner = new GasBurnerParticipant(0);
        bytes32 id = keccak256("lv-burn-unbounded");
        address[] memory parts = _two(address(p1), address(burner));
        _proposeAll(id, parts);
        bytes32 before = _pack(id, parts);
        uint256[2] memory limits = [uint256(2_000_000), uint256(25_000_000)];
        for (uint256 i = 0; i < limits.length; i++) {
            (bool ok,) = address(manager).call{gas: limits[i]}(
                abi.encodeCall(manager.evaluate, (id, parts, _empty(), _empty()))
            );
            assertFalse(ok);
            assertEq(_pack(id, parts), before);
        }
        // Same recovery as for a reverting participant: reject (no gas burnt on reject).
        manager.evaluate(id, _one(address(p1)), _one(address(burner)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    /// @dev Bounded burner returns normally after consuming ~63/64 of the forwarded gas
    /// (EIP-150). Whether the evaluation completes depends on the caller's gas limit and on the
    /// work queued after the burner; the evaluator pays for the burnt gas in every case.
    function test_live_boundedGasBurnerGriefsEvaluator() public {
        GasBurnerParticipant burner = new GasBurnerParticipant(30_000);
        AutoCompleteParticipant a1 = new AutoCompleteParticipant(uint8(Performative.Inform));
        AutoCompleteParticipant a2 = new AutoCompleteParticipant(uint8(Performative.Inform));
        bytes32 id = keccak256("lv-burn-bounded");
        address[] memory parts = _three(address(burner), address(a1), address(a2));
        _proposeAll(id, parts);
        bytes32 before = _pack(id, parts);
        bytes memory call_ = abi.encodeCall(manager.evaluate, (id, parts, _empty(), _empty()));

        (bool okLow,) = address(manager).call{gas: 1_000_000}(call_);
        assertFalse(okLow, "1/64 residue should not cover the honest tail");
        assertEq(_pack(id, parts), before);

        uint256 g0 = gasleft();
        (bool okHigh,) = address(manager).call{gas: 20_000_000}(call_);
        uint256 used = g0 - gasleft();
        assertTrue(okHigh);
        assertGt(used, 19_000_000, "burner should consume most of the budget");
        emit log_named_uint("evaluate gas with bounded burner (limit 20M)", used);
        assertEq(manager.slotOf(id, address(burner)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(id, address(a1)), ContractNetLib.SLOT_NONE);
        assertEq(manager.slotOf(id, address(a2)), ContractNetLib.SLOT_NONE);
    }

    // --- Several conversations in one transaction ---

    function test_live_batchedEvaluationRevertsAllConversations() public {
        BatchingContractNetManager batch = new BatchingContractNetManager();
        RevertOnAcceptParticipant bad = new RevertOnAcceptParticipant();
        bytes32 a = keccak256("lv-batch-a");
        bytes32 b = keccak256("lv-batch-b");
        uint64 by = uint64(block.timestamp + 100);
        Message memory cfpA = _cfp(a, by);
        Message memory cfpB = _cfp(b, by);
        batch.cfp(_one(address(p1)), cfpA);
        batch.cfp(_one(address(bad)), cfpB);
        p1.respond(cfpA, address(batch), _out(cfpA, Performative.Propose));
        bad.respond(cfpB, address(batch), _out(cfpB, Performative.Propose));
        vm.warp(uint256(by) + 1);

        vm.expectRevert(bytes("accept-handle-revert"));
        batch.evaluateTwo(a, _one(address(p1)), b, _one(address(bad)));
        assertFalse(batch.conversation(a).evaluated, "honest conversation rolled back");
        assertEq(batch.slotOf(a, address(p1)), ContractNetLib.SLOT_PROPOSED);

        // Separate transactions isolate the failure.
        batch.evaluate(a, _one(address(p1)), _empty(), _empty());
        assertEq(batch.slotOf(a, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        vm.expectRevert(bytes("accept-handle-revert"));
        batch.evaluate(b, _one(address(bad)), _empty(), _empty());
    }

    function test_live_participantGriefingInOneConversationDoesNotBlockAnother() public {
        RevertOnDecisionParticipant bad = new RevertOnDecisionParticipant();
        bytes32 a = keccak256("lv-iso-a");
        bytes32 b = keccak256("lv-iso-b");
        _proposeAll(a, _two(address(p1), address(bad)));
        Message memory cfpB = _cfp(b, uint64(block.timestamp + 100));
        manager.cfp(_two(address(p1), address(p2)), cfpB);
        p1.respond(cfpB, address(manager), _out(cfpB, Performative.Propose));
        p2.respond(cfpB, address(manager), _out(cfpB, Performative.Propose));
        vm.warp(block.timestamp + 101);
        vm.expectRevert(bytes("decision-revert"));
        manager.evaluate(a, _one(address(p1)), _one(address(bad)), _empty());
        manager.evaluate(b, _one(address(p1)), _one(address(p2)), _empty());
        assertEq(manager.slotOf(b, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(a, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    // --- Abandoned sessions ---

    function test_live_managerNeverEvaluates() public {
        bytes32 id = keccak256("lv-abandon-mgr");
        address[] memory parts = _two(address(p1), address(p2));
        uint64 by = uint64(block.timestamp + 100);
        Message memory cfp = _cfp(id, by);
        manager.cfp(parts, cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 365 days);

        // CFPED participant: permissionless expiry.
        vm.prank(address(0xCAFE));
        p2.expire(id);
        assertEq(p2.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_INVITED);

        // PROPOSED participant: no expiry; only a not-understood withdrawal.
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        p1.respond(cfp, address(manager), _out(cfp, Performative.NotUnderstood));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);

        // Manager side remains live (p2 never answered) until someone evaluates.
        assertEq(manager.conversation(id).live, 1);
        manager.evaluate(id, _empty(), _empty(), _one(address(p2)));
        assertEq(manager.conversation(id).live, 0);
    }

    /// @dev LIMITATION: the manager has no timeout for ACCEPTED participants that never report.
    function test_live_acceptedParticipantNeverReports() public {
        bytes32 id = keccak256("lv-abandon-acc");
        _proposeAll(id, _one(address(p1)));
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        vm.warp(block.timestamp + 365 days);
        assertEq(manager.conversation(id).live, 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _empty(), _empty(), _empty());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.cfp(_one(address(p2)), _cfp(id, uint64(block.timestamp + 10)));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }
}
