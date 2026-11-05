pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {IAgent} from "../src/core/IAgent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {
    AutoCompleteParticipant,
    BareContractNetManager,
    BareContractNetParticipant,
    DecisionRecordingParticipant,
    DirectReentrantParticipant,
    ExposedContractNetManager,
    ExposedContractNetParticipant,
    MaliciousReentrantParticipant,
    RevertOnAcceptParticipant,
    RevertOnCfpParticipant
} from "./ContractNetActors.sol";

contract ContractNetRobustnessTest is Test {
    ExposedContractNetManager internal manager;
    ExposedContractNetParticipant internal p1;
    ExposedContractNetParticipant internal p2;
    ExposedContractNetParticipant internal p3;
    AutoCompleteParticipant internal autoInform;
    AutoCompleteParticipant internal autoFail;
    RevertOnAcceptParticipant internal revertAccept;
    RevertOnCfpParticipant internal revertCfp;
    MaliciousReentrantParticipant internal malicious;
    DecisionRecordingParticipant internal recorder;

    bytes internal constant UNIQUE =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    function setUp() public {
        manager = new ExposedContractNetManager(address(0));
        p1 = new ExposedContractNetParticipant(address(0));
        p2 = new ExposedContractNetParticipant(address(0));
        p3 = new ExposedContractNetParticipant(address(0));
        autoInform = new AutoCompleteParticipant(uint8(Performative.Inform));
        autoFail = new AutoCompleteParticipant(uint8(Performative.Failure));
        revertAccept = new RevertOnAcceptParticipant();
        revertCfp = new RevertOnCfpParticipant();
        malicious = new MaliciousReentrantParticipant();
        recorder = new DecisionRecordingParticipant();
        vm.warp(1_700_000_000);
    }

    function _cfp(uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = bytes32(0);
        m.replyWith = keccak256("cn-rw");
        m.replyBy = replyBy;
        m.content = UNIQUE;
    }

    function _open(address[] memory peers, uint64 by)
        internal
        returns (bytes32 id, Message memory cfp)
    {
        cfp = _cfp(by);
        id = manager.cfp(peers, cfp);
        cfp.conversationId = id;
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

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 100);
    }

    function test_managerDecisionDoesNotReuseCfpReplyBy() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(recorder)), _deadline());
        recorder.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(recorder)), _empty(), _empty());
        assertEq(recorder.lastDecision(), uint8(Performative.AcceptProposal));
        assertEq(recorder.lastDecisionReplyBy(), 0);
    }

    function test_lateProposalRejectionDoesNotReuseCfpReplyBy() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(recorder)), _deadline());
        vm.warp(uint256(by) + 1);
        recorder.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(recorder.lastDecision(), uint8(Performative.RejectProposal));
        assertEq(recorder.lastDecisionReplyBy(), 0);
    }

    function _empty() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _one(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _two(address x, address y) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = x;
        a[1] = y;
    }

    function _assertNoContent(address target) internal view {
        bytes32 needle = bytes32(UNIQUE);
        for (uint256 i = 0; i < 16; i++) {
            assertTrue(vm.load(target, bytes32(i)) != needle);
        }
    }

    function _assertNetGone(bytes32 id) internal view {
        assertEq(manager.conversation(id).invited, 0);
        assertEq(manager.conversation(id).live, 0);
        assertFalse(manager.conversation(id).evaluated);
        assertEq(manager.conversation(id).replyBy, 0);
    }

    // --- M30 regression ---

    function test_evaluateAcceptImmediateInform() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(autoInform)), _deadline());
        autoInform.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(autoInform)), _empty(), _empty());
        _assertNetGone(id);
        assertEq(autoInform.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.slotOf(id, address(autoInform)), ContractNetLib.SLOT_NONE);
        _assertNoContent(address(manager));
    }

    function test_evaluateAcceptImmediateFailure() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(autoFail)), _deadline());
        autoFail.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(autoFail)), _empty(), _empty());
        _assertNetGone(id);
        assertEq(autoFail.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_evaluateOneImmediateInformOtherRemainsAccepted() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) =
            _open(_two(address(autoInform), address(p1)), _deadline());
        autoInform.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _two(address(autoInform), address(p1)), _empty(), _empty());
        assertEq(manager.conversation(id).live, 1);
        assertEq(manager.slotOf(id, address(autoInform)), ContractNetLib.SLOT_NONE);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(p1.session(id).phase, ContractNetLib.PART_ACCEPTED);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
        _assertNetGone(id);
    }

    function test_evaluateAllAcceptedCompleteSynchronously() public {
        AutoCompleteParticipant a2 = new AutoCompleteParticipant(uint8(Performative.Inform));
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) =
            _open(_two(address(autoInform), address(a2)), _deadline());
        autoInform.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        a2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _two(address(autoInform), address(a2)), _empty(), _empty());
        _assertNetGone(id);
        assertEq(autoInform.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(a2.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_evaluateMixedAcceptRejectSilentWithSyncComplete() public {
        uint64 by = _deadline();
        address[] memory parts = new address[](3);
        parts[0] = address(autoInform);
        parts[1] = address(p1);
        parts[2] = address(p2);
        (bytes32 id, Message memory cfp) = _open(parts, by);
        autoInform.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(autoInform)), _one(address(p1)), _one(address(p2)));
        _assertNetGone(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(p2.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(autoInform.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_evaluateSyncCompleteDoesNotCorruptOtherConversation() public {
        uint64 by = _deadline();
        (bytes32 keep, Message memory cfpKeep) = _open(_one(address(p1)), by);
        (bytes32 drop, Message memory cfpDrop) = _open(_one(address(autoInform)), by);
        p1.respond(cfpKeep, address(manager), _out(cfpKeep, Performative.Propose));
        autoInform.respond(cfpDrop, address(manager), _out(cfpDrop, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(drop, _one(address(autoInform)), _empty(), _empty());
        _assertNetGone(drop);
        assertEq(manager.conversation(keep).live, 1);
        assertEq(manager.slotOf(keep, address(p1)), ContractNetLib.SLOT_PROPOSED);
        manager.evaluate(keep, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(keep, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    // --- Deadline ---

    function test_deadlineLtReplyByProposeOkEvaluateReverts() public {
        uint64 by = uint64(block.timestamp + 50);
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), uint64(block.timestamp + 50));
        vm.warp(uint256(by) - 1);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
    }

    function test_deadlineEqReplyByProposeOkEvaluateReverts() public {
        uint64 by = uint64(block.timestamp + 50);
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), uint64(block.timestamp + 50));
        vm.warp(uint256(by));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
    }

    function test_deadlineGtReplyByProposeLateEvaluateOk() public {
        uint64 by = uint64(block.timestamp + 50);
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), uint64(block.timestamp + 50));
        vm.warp(uint256(by) + 1);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        _assertNetGone(id);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _empty(), _empty(), _empty());
    }

    function test_deadlineGtReplyByEvaluateAfterTimelyPropose() public {
        uint64 by = uint64(block.timestamp + 50);
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), uint64(block.timestamp + 50));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    // --- CFP negatives / current behaviour ---

    function test_cfpEmptyParticipantsReverts() public {
        vm.expectRevert(ContractNetLib.EmptyParticipants.selector);
        manager.cfp(_empty(), _cfp(_deadline()));
    }

    function test_cfpDuplicateParticipantsReverts() public {
        vm.expectRevert(ContractNetLib.DuplicateParticipant.selector);
        manager.cfp(_two(address(p1), address(p1)), _cfp(_deadline()));
    }

    function test_cfpAddressZeroRevertsEntireTransaction() public {
        vm.expectRevert(
            abi.encodeWithSelector(ContractNetLib.InvalidParticipant.selector, address(0))
        );
        manager.cfp(_one(address(0)), _cfp(_deadline()));
    }

    function test_cfpEoaRevertsEntireTransaction() public {
        address eoa = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(ContractNetLib.InvalidParticipant.selector, eoa));
        manager.cfp(_one(eoa), _cfp(_deadline()));
        assertEq(manager.slotOf(bytes32(0), eoa), ContractNetLib.SLOT_NONE);
    }

    function test_cfpInvalidAmongValidRevertsNoPartialState() public {
        address eoa = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(ContractNetLib.InvalidParticipant.selector, eoa));
        manager.cfp(_two(address(p1), eoa), _cfp(_deadline()));
        assertEq(p1.session(bytes32(0)).phase, ContractNetLib.PART_NONE);
    }

    function test_cfpDeployedParticipantOk() public {
        (bytes32 id,) = _open(_one(address(p1)), _deadline());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
    }

    function test_cfpManagerInParticipantListReverts() public {
        Message memory cfp = _cfp(_deadline());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.cfp(_one(address(manager)), cfp);
    }

    function test_cfpReplyByMaxNeverLateEvaluateReverts() public {
        uint64 by = type(uint64).max;
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), type(uint64).max);
        vm.warp(uint256(type(uint64).max));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
    }

    function test_alreadyExpiredCfpAllowsLateProposeReject() public {
        uint64 by = uint64(block.timestamp - 1);
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), uint64(block.timestamp - 1));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        _assertNetGone(id);
    }

    function test_acceptProposalWithoutProposeReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        Message memory acc;
        acc.performative = uint8(Performative.AcceptProposal);
        acc.protocol = uint8(Protocol.FipaContractNet);
        acc.conversationId = id;
        acc.replyBy = by;
        vm.prank(address(manager));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.handle(acc);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_outOfEnumPerformativeOnCnReverts() public {
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        Message memory bad = _out(cfp, Performative.Propose);
        bad.performative = 255;
        vm.prank(address(p1));
        vm.expectRevert();
        manager.handle(bad);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_cfpSameIdWhileActiveReverts() public {
        (bytes32 id1,) = _open(_one(address(p1)), _deadline());
        (bytes32 id2,) = _open(_one(address(p2)), _deadline());
        assertNotEq(id1, id2);
        assertEq(manager.conversation(id1).live, 1);
        assertEq(manager.conversation(id2).live, 1);
    }

    function test_nonZeroOpeningConversationIdReverts() public {
        Message memory cfp = _cfp(_deadline());
        cfp.conversationId = keccak256("forced-id");
        vm.expectRevert(ContractNetManager.ConversationIdAssignedByBlade.selector);
        manager.cfp(_one(address(p1)), cfp);
    }

    function test_cfpAtomicRevertLeavesNoState() public {
        Message memory cfp = _cfp(_deadline());
        vm.expectRevert(bytes("cfp-handle-revert"));
        manager.cfp(_two(address(p1), address(revertCfp)), cfp);
        assertEq(p1.session(cfp.conversationId).phase, ContractNetLib.PART_NONE);
        (bytes32 okId,) = _open(_one(address(p1)), _deadline());
        assertEq(p1.session(okId).phase, ContractNetLib.PART_CFPED);
    }

    function test_cfpPublicCallerCurrentlyAllowed() public {
        vm.prank(address(0x1111));
        (bytes32 id,) = _open(_one(address(p1)), _deadline());
        assertEq(manager.conversation(id).live, 1);
    }

    function test_reuseConversationIdAfterCleanup() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), by);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        _assertNetGone(id);
        Message memory reopen = _cfp(by);
        bytes32 id2 = manager.cfp(_one(address(p2)), reopen);
        reopen.conversationId = id2;
        assertNotEq(id2, id);
        assertEq(manager.conversation(id2).live, 1);
        assertEq(manager.slotOf(id2, address(p2)), ContractNetLib.SLOT_INVITED);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        Message memory forced = _cfp(by);
        forced.conversationId = id;
        vm.expectRevert(ContractNetManager.ConversationIdAssignedByBlade.selector);
        manager.cfp(_one(address(p2)), forced);
    }

    // --- Response negatives ---

    function test_proposeThenRefuseReverts() public {
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_refuseThenProposeReverts() public {
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        _assertNetGone(id);
    }

    function test_responseOnWrongConversationDoesNotMutateOther() public {
        (bytes32 a, Message memory cfpA) = _open(_one(address(p1)), _deadline());
        (bytes32 b, Message memory cfpB) = _open(_one(address(p2)), _deadline());
        vm.prank(address(p1));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        manager.handle(_out(cfpB, Performative.Propose));
        assertEq(manager.slotOf(a, address(p1)), ContractNetLib.SLOT_INVITED);
        assertEq(manager.slotOf(b, address(p2)), ContractNetLib.SLOT_INVITED);
    }

    function test_sameParticipantTwoConversations() public {
        (bytes32 a, Message memory cfpA) = _open(_one(address(p1)), _deadline());
        (bytes32 b, Message memory cfpB) = _open(_one(address(p1)), _deadline());
        p1.respond(cfpA, address(manager), _out(cfpA, Performative.Propose));
        assertEq(p1.session(a).phase, ContractNetLib.PART_PROPOSED);
        assertEq(p1.session(b).phase, ContractNetLib.PART_CFPED);
    }

    function test_rejectProposalWhileOnlyCfpedRevertsPreservesSession() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        Message memory rej;
        rej.performative = uint8(Performative.RejectProposal);
        rej.protocol = uint8(Protocol.FipaContractNet);
        rej.conversationId = id;
        rej.replyBy = by;
        vm.prank(address(manager));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.handle(rej);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_duplicateCfpOnActiveParticipantReverts() public {
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        vm.prank(address(p2));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        p1.handle(cfp);
        assertEq(p1.session(id).manager, address(manager));
    }

    function test_respondPublicCallerCurrentlyAllowed() public {
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        vm.prank(address(0x2222));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    // --- Evaluate negatives ---

    function test_evaluateDuplicateInAcceptReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _two(address(p1), address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateDuplicateInRejectReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_two(address(p1), address(p2)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _empty(), _two(address(p1), address(p1)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateDuplicateInSilentReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _empty(), _empty(), _two(address(p1), address(p1)));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_evaluateOverlapAcceptRejectReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_two(address(p1), address(p2)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p1)), _one(address(p1)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateUnknownParticipantReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p3)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p3)), ContractNetLib.SLOT_NONE);
    }

    function test_evaluateOmitProposedReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_two(address(p1), address(p2)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateTwiceReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    function test_evaluatePublicCallerCurrentlyAllowed() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.prank(address(0x3333));
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    // --- Reentrancy / rollback ---

    /// @dev Participant-side guard only: the act is rejected by the reentrant participant's own
    /// FSM and never reaches the manager. Manager-side reentry is covered by `test_reentry_*`.
    function test_maliciousReentrantProposeOnAcceptRevertsEvaluate() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(malicious)), _deadline());
        malicious.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(malicious)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(malicious)), ContractNetLib.SLOT_PROPOSED);
        assertFalse(manager.conversation(id).evaluated);
    }

    // --- Direct manager reentry: the adversary bypasses its own FSM ---

    function _cnAct(bytes32 id, Performative act) internal view returns (Message memory m) {
        m.performative = uint8(act);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        if (act == Performative.Cfp) {
            m.replyBy = _deadline();
        }
    }

    function _handleCall(Message memory m) internal pure returns (bytes memory) {
        return abi.encodeCall(IAgent.handle, (m));
    }

    function _openProposed(DirectReentrantParticipant adv)
        internal
        returns (bytes32 id, uint64 by)
    {
        by = _deadline();
        Message memory cfp;
        (id, cfp) = _open(_one(address(adv)), by);
        adv.respond(cfp, address(manager), _out(cfp, Performative.Propose));
    }

    function test_reentry_directProposeReachesManagerAndIsRejected() public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        (bytes32 id, uint64 by) = _openProposed(adv);
        Message memory m = _cnAct(id, Performative.Propose);
        adv.arm(uint8(Performative.AcceptProposal), address(manager), _handleCall(m), false);
        vm.warp(uint256(by) + 1);

        vm.expectCall(address(manager), _handleCall(m), 1);
        manager.evaluate(id, _one(address(adv)), _empty(), _empty());

        assertTrue(adv.attempted(), "reentry not attempted");
        assertFalse(adv.reentrySucceeded());
        // Raised by the manager's slot check (ACCEPTED is not INVITED). The adversary's own FSM
        // would have raised InvalidTransition, and it was not consulted (its phase is untouched).
        assertEq(
            adv.reentryReturnData(), abi.encodeWithSelector(ContractNetLib.UnexpectedPeer.selector)
        );
        assertEq(adv.slotSeenDuringReentry(), ContractNetLib.SLOT_ACCEPTED);
        assertTrue(adv.evaluatedSeenDuringReentry(), "effects not applied before interaction");

        assertEq(manager.slotOf(id, address(adv)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.conversation(id).live, 1);
        assertTrue(manager.conversation(id).evaluated);
        assertEq(adv.session(id).phase, ContractNetLib.PART_ACCEPTED);
    }

    function test_reentry_directProposeBubbledRollsBackEvaluate() public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        (bytes32 id, uint64 by) = _openProposed(adv);
        adv.arm(
            uint8(Performative.AcceptProposal),
            address(manager),
            _handleCall(_cnAct(id, Performative.Propose)),
            true
        );
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        manager.evaluate(id, _one(address(adv)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(adv)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.conversation(id).live, 1);
        assertFalse(manager.conversation(id).evaluated);
        assertEq(adv.session(id).phase, ContractNetLib.PART_PROPOSED);
    }

    function test_reentry_directInvalidActsRejectedByManager() public {
        Performative[8] memory acts = [
            Performative.Propose,
            Performative.Refuse,
            Performative.Cfp,
            Performative.AcceptProposal,
            Performative.RejectProposal,
            Performative.Request,
            Performative.Agree,
            Performative.Cancel
        ];
        for (uint256 i = 0; i < acts.length; i++) {
            DirectReentrantParticipant adv = new DirectReentrantParticipant();
            (bytes32 id, uint64 by) = _openProposed(adv);
            Message memory m = _cnAct(id, acts[i]);
            adv.arm(uint8(Performative.AcceptProposal), address(manager), _handleCall(m), false);
            vm.warp(uint256(by) + 1);
            vm.expectCall(address(manager), _handleCall(m), 1);
            manager.evaluate(id, _one(address(adv)), _empty(), _empty());
            bytes4 expected = acts[i] == Performative.Propose
                ? ContractNetLib.UnexpectedPeer.selector
                : ContractNetLib.InvalidTransition.selector;
            assertFalse(adv.reentrySucceeded());
            assertEq(adv.reentryReturnData(), abi.encodeWithSelector(expected));
            assertEq(manager.slotOf(id, address(adv)), ContractNetLib.SLOT_ACCEPTED);
            assertEq(manager.conversation(id).live, 1);
            assertTrue(manager.conversation(id).evaluated);
        }
    }

    /// @dev Inform/Failure/NotUnderstood from an ACCEPTED slot are valid manager transitions; a
    /// reentrant delivery is equivalent to the synchronous completion already supported (M30).
    function test_reentry_directCompletionActsAreValidAndConsistent() public {
        Performative[3] memory acts =
            [Performative.Inform, Performative.Failure, Performative.NotUnderstood];
        for (uint256 i = 0; i < acts.length; i++) {
            DirectReentrantParticipant adv = new DirectReentrantParticipant();
            ExposedContractNetParticipant honest = new ExposedContractNetParticipant(address(0));
            uint64 by = _deadline();
            (bytes32 id, Message memory cfp) = _open(_two(address(adv), address(honest)), by);
            adv.respond(cfp, address(manager), _out(cfp, Performative.Propose));
            honest.respond(cfp, address(manager), _out(cfp, Performative.Propose));
            adv.arm(
                uint8(Performative.AcceptProposal),
                address(manager),
                _handleCall(_cnAct(id, acts[i])),
                false
            );
            vm.warp(uint256(by) + 1);
            manager.evaluate(id, _two(address(adv), address(honest)), _empty(), _empty());
            assertTrue(adv.reentrySucceeded());
            assertEq(manager.slotOf(id, address(adv)), ContractNetLib.SLOT_NONE);
            assertEq(manager.slotOf(id, address(honest)), ContractNetLib.SLOT_ACCEPTED);
            assertEq(manager.conversation(id).live, 1);
            assertEq(honest.session(id).phase, ContractNetLib.PART_ACCEPTED);
            honest.respond(cfp, address(manager), _out(cfp, Performative.Inform));
            _assertNetGone(id);
        }
    }

    function test_reentry_evaluateSameConversationRejected() public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        (bytes32 id, uint64 by) = _openProposed(adv);
        bytes memory call_ = abi.encodeCall(
            ExposedContractNetManager.evaluate, (id, _one(address(adv)), _empty(), _empty())
        );
        adv.arm(uint8(Performative.AcceptProposal), address(manager), call_, false);
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(adv)), _empty(), _empty());
        assertEq(
            adv.reentryReturnData(),
            abi.encodeWithSelector(ContractNetLib.InvalidTransition.selector)
        );
        assertEq(manager.slotOf(id, address(adv)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.conversation(id).live, 1);
    }

    function test_reentry_cfpSameLiveConversationRejected() public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        (bytes32 id, uint64 by) = _openProposed(adv);
        bytes memory call_ =
            abi.encodeCall(ExposedContractNetManager.cfp, (_one(address(p2)), _cfp(by + 100)));
        adv.arm(uint8(Performative.AcceptProposal), address(manager), call_, false);
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(adv)), _empty(), _empty());
        assertTrue(adv.reentrySucceeded());
        bytes32 reentryId = keccak256(abi.encode(block.chainid, address(manager), uint256(2)));
        assertNotEq(reentryId, id);
        assertEq(manager.conversation(id).live, 1);
        assertEq(manager.slotOf(reentryId, address(p2)), ContractNetLib.SLOT_INVITED);
        assertEq(p2.session(reentryId).phase, ContractNetLib.PART_CFPED);
    }

    /// @dev All-reject evaluation clears the conversation before delivering decisions; a reentrant
    /// CFP during reject opens a fresh BLADE-assigned id (not the cleared instance).
    function test_reentry_cfpSameIdAfterSynchronousClearIsConsistent() public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        (bytes32 id, uint64 by) = _openProposed(adv);
        uint64 by2 = by + 1000;
        bytes memory call_ =
            abi.encodeCall(ExposedContractNetManager.cfp, (_one(address(p2)), _cfp(by2)));
        adv.arm(uint8(Performative.RejectProposal), address(manager), call_, false);
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _empty(), _one(address(adv)), _empty());
        assertTrue(adv.reentrySucceeded());
        assertEq(manager.conversation(id).live, 0);
        bytes32 reentryId = keccak256(abi.encode(block.chainid, address(manager), uint256(2)));
        assertEq(manager.slotOf(reentryId, address(p2)), ContractNetLib.SLOT_INVITED);
        assertEq(p2.session(reentryId).phase, ContractNetLib.PART_CFPED);
        assertEq(manager.conversation(reentryId).replyBy, by2);
    }

    function test_reentry_otherConversations() public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        (bytes32 a, uint64 by) = _openProposed(adv);
        (bytes32 b,) = _open(_one(address(adv)), by + 1000);
        (bytes32 c,) = _open(_one(address(p1)), by + 1000);
        bytes32 cBefore = keccak256(
            abi.encode(manager.conversation(c), manager.slotOf(c, address(p1)), p1.session(c))
        );

        adv.arm(
            uint8(Performative.AcceptProposal),
            address(manager),
            _handleCall(_cnAct(c, Performative.Propose)),
            false
        );
        vm.warp(uint256(by) + 1);
        manager.evaluate(a, _one(address(adv)), _empty(), _empty());
        assertEq(
            adv.reentryReturnData(), abi.encodeWithSelector(ContractNetLib.UnexpectedPeer.selector)
        );
        assertEq(
            keccak256(
                abi.encode(manager.conversation(c), manager.slotOf(c, address(p1)), p1.session(c))
            ),
            cBefore
        );
        assertEq(manager.slotOf(a, address(adv)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(b, address(adv)), ContractNetLib.SLOT_INVITED);

        DirectReentrantParticipant adv2 = new DirectReentrantParticipant();
        (bytes32 a2, uint64 byA2) = _openProposed(adv2);
        (bytes32 b2,) = _open(_one(address(adv2)), byA2 + 1000);
        adv2.arm(
            uint8(Performative.AcceptProposal),
            address(manager),
            _handleCall(_cnAct(b2, Performative.Propose)),
            false
        );
        vm.warp(uint256(byA2) + 1);
        manager.evaluate(a2, _one(address(adv2)), _empty(), _empty());
        assertTrue(adv2.reentrySucceeded());
        assertEq(manager.slotOf(b2, address(adv2)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(a2, address(adv2)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.conversation(a2).live, 1);
        assertTrue(manager.conversation(a2).evaluated);
        assertFalse(manager.conversation(b2).evaluated);
    }

    function testFuzz_reentry_anyActKeepsManagerConsistent(uint8 act) public {
        DirectReentrantParticipant adv = new DirectReentrantParticipant();
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_two(address(adv), address(p1)), _deadline());
        adv.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        Message memory m;
        m.performative = act;
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        adv.arm(uint8(Performative.AcceptProposal), address(manager), _handleCall(m), false);
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _two(address(adv), address(p1)), _empty(), _empty());

        uint8 slot = manager.slotOf(id, address(adv));
        bool completion = act == uint8(Performative.Inform) || act == uint8(Performative.Failure)
            || act == uint8(Performative.NotUnderstood);
        assertEq(adv.reentrySucceeded(), completion);
        assertEq(slot, completion ? ContractNetLib.SLOT_NONE : ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        uint32 counted = (slot == ContractNetLib.SLOT_NONE ? 0 : 1) + 1;
        assertEq(manager.conversation(id).live, counted);
        assertTrue(manager.conversation(id).evaluated);
    }

    function test_acceptHandleRevertRollsBackEvaluate() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) =
            _open(_two(address(p1), address(revertAccept)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        revertAccept.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(bytes("accept-handle-revert"));
        manager.evaluate(id, _two(address(p1), address(revertAccept)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(revertAccept)), ContractNetLib.SLOT_PROPOSED);
        assertFalse(manager.conversation(id).evaluated);
        assertEq(manager.conversation(id).live, 2);
    }

    function test_maliciousRevertDoesNotCorruptOtherConversation() public {
        uint64 by = _deadline();
        (bytes32 keep, Message memory cfpKeep) = _open(_one(address(p1)), by);
        (bytes32 bad, Message memory cfpBad) = _open(_one(address(revertAccept)), by);
        p1.respond(cfpKeep, address(manager), _out(cfpKeep, Performative.Propose));
        revertAccept.respond(cfpBad, address(manager), _out(cfpBad, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(bytes("accept-handle-revert"));
        manager.evaluate(bad, _one(address(revertAccept)), _empty(), _empty());
        assertEq(manager.slotOf(keep, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.conversation(keep).live, 1);
    }

    function test_evaluateRefusedAddressRevertsWithoutMutatingSibling() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_two(address(p1), address(p2)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.conversation(id).live, 1);
    }

    function test_bareManagerDecisionSelectorsAbsent() public {
        BareContractNetManager bare = new BareContractNetManager(address(0));
        address[] memory parts = _one(address(p1));
        Message memory m = _cfp(_deadline());
        (bool okCfp,) = address(bare)
            .call(
                abi.encodeWithSignature(
                    "cfp(address[],(uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes))",
                    parts,
                    m
                )
            );
        (bool okEv,) = address(bare)
            .call(
                abi.encodeWithSignature(
                    "evaluate(bytes32,address[],address[],address[])",
                    m.conversationId,
                    _empty(),
                    _empty(),
                    _empty()
                )
            );
        assertFalse(okCfp);
        assertFalse(okEv);
        _assertNetGone(m.conversationId);
    }

    function test_bareParticipantRespondSelectorAbsent() public {
        BareContractNetParticipant bare = new BareContractNetParticipant(address(0));
        Message memory m = _cfp(_deadline());
        (bool ok,) = address(bare)
            .call(
                abi.encodeWithSignature(
                    "respond((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,(uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes))",
                    m,
                    address(manager),
                    _out(m, Performative.Propose)
                )
            );
        assertFalse(ok);
    }

    function test_expireCfpedBeforeAndAtReplyByReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        vm.warp(uint256(by));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
    }

    function test_expireCfpedAfterReplyByDeletes() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        vm.warp(uint256(by) + 1);
        vm.prank(address(0x9999));
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_expireProposedAfterDeadlineReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_PROPOSED);
    }

    function test_expireAcceptedReverts() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_ACCEPTED);
    }

    function test_expireDoesNotAffectOtherConversation() public {
        uint64 by = _deadline();
        (bytes32 a,) = _open(_one(address(p1)), by);
        (bytes32 b,) = _open(_one(address(p1)), by);
        vm.warp(uint256(by) + 1);
        p1.expire(a);
        assertEq(p1.session(a).phase, ContractNetLib.PART_NONE);
        assertEq(p1.session(b).phase, ContractNetLib.PART_CFPED);
    }

    function test_reuseAfterExpireNoTombstone() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), _deadline());
        vm.warp(uint256(by) + 1);
        p1.expire(id);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        manager.evaluate(id, _empty(), _empty(), _one(address(p1)));
        _assertNetGone(id);
        (bytes32 id2,) = _open(_one(address(p1)), uint64(block.timestamp + 50));
        assertNotEq(id2, id);
        assertEq(p1.session(id2).phase, ContractNetLib.PART_CFPED);
    }

    function test_snapshot_expire() public {
        uint64 by = _deadline();
        (bytes32 id, Message memory cfp) = _open(_one(address(p1)), by);
        vm.warp(uint256(by) + 1);
        p1.expire(id);
    }
}
