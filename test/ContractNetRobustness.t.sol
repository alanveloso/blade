pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {ContractNetParticipant} from "../src/core/ContractNetParticipant.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {
    AutoCompleteParticipant,
    DecisionRecordingParticipant,
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

    function _cfp(bytes32 id, uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        m.replyWith = keccak256(abi.encodePacked(id, "rw"));
        m.replyBy = replyBy;
        m.content = UNIQUE;
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
        bytes32 id = keccak256("decision-replyby-zero");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(recorder)), cfp);
        recorder.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(recorder)), _empty(), _empty());
        assertEq(recorder.lastDecision(), uint8(Performative.AcceptProposal));
        assertEq(recorder.lastDecisionReplyBy(), 0);
    }

    function test_lateProposalRejectionDoesNotReuseCfpReplyBy() public {
        bytes32 id = keccak256("late-reject-replyby-zero");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(recorder)), cfp);
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
        bytes32 id = keccak256("m30-inform");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(autoInform)), cfp);
        autoInform.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(autoInform)), _empty(), _empty());
        _assertNetGone(id);
        assertEq(autoInform.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.slotOf(id, address(autoInform)), ContractNetLib.SLOT_NONE);
        _assertNoContent(address(manager));
    }

    function test_evaluateAcceptImmediateFailure() public {
        bytes32 id = keccak256("m30-fail");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(autoFail)), cfp);
        autoFail.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(autoFail)), _empty(), _empty());
        _assertNetGone(id);
        assertEq(autoFail.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_evaluateOneImmediateInformOtherRemainsAccepted() public {
        bytes32 id = keccak256("m30-mixed");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(autoInform), address(p1)), cfp);
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
        bytes32 id = keccak256("m30-all");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(autoInform), address(a2)), cfp);
        autoInform.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        a2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _two(address(autoInform), address(a2)), _empty(), _empty());
        _assertNetGone(id);
        assertEq(autoInform.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(a2.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_evaluateMixedAcceptRejectSilentWithSyncComplete() public {
        bytes32 id = keccak256("m30-ars");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        address[] memory parts = new address[](3);
        parts[0] = address(autoInform);
        parts[1] = address(p1);
        parts[2] = address(p2);
        manager.cfp(parts, cfp);
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
        bytes32 keep = keccak256("keep");
        bytes32 drop = keccak256("drop");
        uint64 by = _deadline();
        Message memory cfpKeep = _cfp(keep, by);
        Message memory cfpDrop = _cfp(drop, by);
        manager.cfp(_one(address(p1)), cfpKeep);
        manager.cfp(_one(address(autoInform)), cfpDrop);
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
        bytes32 id = keccak256("dl-lt");
        uint64 by = uint64(block.timestamp + 50);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(by) - 1);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
    }

    function test_deadlineEqReplyByProposeOkEvaluateReverts() public {
        bytes32 id = keccak256("dl-eq");
        uint64 by = uint64(block.timestamp + 50);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(by));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
    }

    function test_deadlineGtReplyByProposeLateEvaluateOk() public {
        bytes32 id = keccak256("dl-gt");
        uint64 by = uint64(block.timestamp + 50);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(by) + 1);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        _assertNetGone(id);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _empty(), _empty(), _empty());
    }

    function test_deadlineGtReplyByEvaluateAfterTimelyPropose() public {
        bytes32 id = keccak256("dl-eval");
        uint64 by = uint64(block.timestamp + 50);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    // --- CFP negatives / current behaviour ---

    function test_cfpEmptyParticipantsReverts() public {
        vm.expectRevert(ContractNetLib.EmptyParticipants.selector);
        manager.cfp(_empty(), _cfp(keccak256("empty"), _deadline()));
    }

    function test_cfpDuplicateParticipantsReverts() public {
        vm.expectRevert(ContractNetLib.DuplicateParticipant.selector);
        manager.cfp(_two(address(p1), address(p1)), _cfp(keccak256("dup"), _deadline()));
    }

    function test_cfpAddressZeroRevertsEntireTransaction() public {
        bytes32 id = keccak256("zero");
        vm.expectRevert(
            abi.encodeWithSelector(ContractNetLib.InvalidParticipant.selector, address(0))
        );
        manager.cfp(_one(address(0)), _cfp(id, _deadline()));
        _assertNetGone(id);
    }

    function test_cfpEoaRevertsEntireTransaction() public {
        address eoa = address(0xBEEF);
        bytes32 id = keccak256("eoa");
        vm.expectRevert(abi.encodeWithSelector(ContractNetLib.InvalidParticipant.selector, eoa));
        manager.cfp(_one(eoa), _cfp(id, _deadline()));
        _assertNetGone(id);
        assertEq(manager.slotOf(id, eoa), ContractNetLib.SLOT_NONE);
    }

    function test_cfpInvalidAmongValidRevertsNoPartialState() public {
        bytes32 id = keccak256("mix-inv");
        address eoa = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(ContractNetLib.InvalidParticipant.selector, eoa));
        manager.cfp(_two(address(p1), eoa), _cfp(id, _deadline()));
        _assertNetGone(id);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_cfpDeployedParticipantOk() public {
        bytes32 id = keccak256("ok-p");
        manager.cfp(_one(address(p1)), _cfp(id, _deadline()));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
    }

    function test_cfpManagerInParticipantListReverts() public {
        bytes32 id = keccak256("m4");
        Message memory cfp = _cfp(id, _deadline());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.cfp(_one(address(manager)), cfp);
        _assertNetGone(id);
    }

    function test_cfpReplyByMaxNeverLateEvaluateReverts() public {
        bytes32 id = keccak256("m7");
        uint64 by = type(uint64).max;
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(type(uint64).max));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
    }

    function test_alreadyExpiredCfpAllowsLateProposeReject() public {
        bytes32 id = keccak256("m8");
        uint64 by = uint64(block.timestamp - 1);
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        _assertNetGone(id);
    }

    function test_acceptProposalWithoutProposeReverts() public {
        bytes32 id = keccak256("p4");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
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
        bytes32 id = keccak256("a10-cn");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_one(address(p1)), cfp);
        Message memory bad = _out(cfp, Performative.Propose);
        bad.performative = 255;
        vm.prank(address(p1));
        vm.expectRevert();
        manager.handle(bad);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_cfpSameIdWhileActiveReverts() public {
        bytes32 id = keccak256("again");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_one(address(p1)), cfp);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.cfp(_one(address(p2)), cfp);
    }

    function test_cfpAtomicRevertLeavesNoState() public {
        bytes32 id = keccak256("atomic");
        Message memory cfp = _cfp(id, _deadline());
        vm.expectRevert(bytes("cfp-handle-revert"));
        manager.cfp(_two(address(p1), address(revertCfp)), cfp);
        _assertNetGone(id);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_cfpPublicCallerCurrentlyAllowed() public {
        bytes32 id = keccak256("pub-cfp");
        vm.prank(address(0x1111));
        manager.cfp(_one(address(p1)), _cfp(id, _deadline()));
        assertEq(manager.conversation(id).live, 1);
    }

    function test_reuseConversationIdAfterCleanup() public {
        bytes32 id = keccak256("reuse");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        _assertNetGone(id);
        manager.cfp(_one(address(p2)), cfp);
        assertEq(manager.conversation(id).live, 1);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_INVITED);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
    }

    // --- Response negatives ---

    function test_proposeThenRefuseReverts() public {
        bytes32 id = keccak256("pr");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_refuseThenProposeReverts() public {
        bytes32 id = keccak256("rp");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        _assertNetGone(id);
    }

    function test_responseOnWrongConversationDoesNotMutateOther() public {
        bytes32 a = keccak256("ca");
        bytes32 b = keccak256("cb");
        Message memory cfpA = _cfp(a, _deadline());
        Message memory cfpB = _cfp(b, _deadline());
        manager.cfp(_one(address(p1)), cfpA);
        manager.cfp(_one(address(p2)), cfpB);
        vm.prank(address(p1));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        manager.handle(_out(cfpB, Performative.Propose));
        assertEq(manager.slotOf(a, address(p1)), ContractNetLib.SLOT_INVITED);
        assertEq(manager.slotOf(b, address(p2)), ContractNetLib.SLOT_INVITED);
    }

    function test_sameParticipantTwoConversations() public {
        bytes32 a = keccak256("p8a");
        bytes32 b = keccak256("p8b");
        Message memory cfpA = _cfp(a, _deadline());
        Message memory cfpB = _cfp(b, _deadline());
        manager.cfp(_one(address(p1)), cfpA);
        manager.cfp(_one(address(p1)), cfpB);
        p1.respond(cfpA, address(manager), _out(cfpA, Performative.Propose));
        assertEq(p1.session(a).phase, ContractNetLib.PART_PROPOSED);
        assertEq(p1.session(b).phase, ContractNetLib.PART_CFPED);
    }

    function test_rejectProposalWhileOnlyCfpedRevertsPreservesSession() public {
        bytes32 id = keccak256("p5");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
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
        bytes32 id = keccak256("p2");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_one(address(p1)), cfp);
        vm.prank(address(p2));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        p1.handle(cfp);
        assertEq(p1.session(id).manager, address(manager));
    }

    function test_respondPublicCallerCurrentlyAllowed() public {
        bytes32 id = keccak256("pub-r");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_one(address(p1)), cfp);
        vm.prank(address(0x2222));
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    // --- Evaluate negatives ---

    function test_evaluateDuplicateInAcceptReverts() public {
        bytes32 id = keccak256("dup-a");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _two(address(p1), address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateDuplicateInRejectReverts() public {
        bytes32 id = keccak256("dup-r");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(p1), address(p2)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _empty(), _two(address(p1), address(p1)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateDuplicateInSilentReverts() public {
        bytes32 id = keccak256("dup-s");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _empty(), _empty(), _two(address(p1), address(p1)));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_evaluateOverlapAcceptRejectReverts() public {
        bytes32 id = keccak256("ov");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(p1), address(p2)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p1)), _one(address(p1)), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateUnknownParticipantReverts() public {
        bytes32 id = keccak256("unk");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p3)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p3)), ContractNetLib.SLOT_NONE);
    }

    function test_evaluateOmitProposedReverts() public {
        bytes32 id = keccak256("omit");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(p1), address(p2)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.IncompleteEvaluation.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_evaluateTwiceReverts() public {
        bytes32 id = keccak256("twice");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    function test_evaluatePublicCallerCurrentlyAllowed() public {
        bytes32 id = keccak256("pub-e");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.prank(address(0x3333));
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
    }

    // --- Reentrancy / rollback ---

    function test_maliciousReentrantProposeOnAcceptRevertsEvaluate() public {
        bytes32 id = keccak256("mal");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(malicious)), cfp);
        malicious.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        manager.evaluate(id, _one(address(malicious)), _empty(), _empty());
        assertEq(manager.slotOf(id, address(malicious)), ContractNetLib.SLOT_PROPOSED);
        assertFalse(manager.conversation(id).evaluated);
    }

    function test_acceptHandleRevertRollsBackEvaluate() public {
        bytes32 id = keccak256("rb");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(p1), address(revertAccept)), cfp);
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
        bytes32 keep = keccak256("keep2");
        bytes32 bad = keccak256("bad");
        uint64 by = _deadline();
        Message memory cfpKeep = _cfp(keep, by);
        Message memory cfpBad = _cfp(bad, by);
        manager.cfp(_one(address(p1)), cfpKeep);
        manager.cfp(_one(address(revertAccept)), cfpBad);
        p1.respond(cfpKeep, address(manager), _out(cfpKeep, Performative.Propose));
        revertAccept.respond(cfpBad, address(manager), _out(cfpBad, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(bytes("accept-handle-revert"));
        manager.evaluate(bad, _one(address(revertAccept)), _empty(), _empty());
        assertEq(manager.slotOf(keep, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.conversation(keep).live, 1);
    }

    function test_evaluateRefusedAddressRevertsWithoutMutatingSibling() public {
        bytes32 id = keccak256("m24");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_two(address(p1), address(p2)), cfp);
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
        ContractNetManager bare = new ContractNetManager(address(0));
        address[] memory parts = _one(address(p1));
        Message memory m = _cfp(keccak256("bare"), _deadline());
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
        ContractNetParticipant bare = new ContractNetParticipant(address(0));
        Message memory m = _cfp(keccak256("bare-p"), _deadline());
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
        bytes32 id = keccak256("ex-early");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        vm.warp(uint256(by));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
    }

    function test_expireCfpedAfterReplyByDeletes() public {
        bytes32 id = keccak256("ex-ok");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(by) + 1);
        vm.prank(address(0x9999));
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_expireProposedAfterDeadlineReverts() public {
        bytes32 id = keccak256("ex-pr");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_PROPOSED);
    }

    function test_expireAcceptedReverts() public {
        bytes32 id = keccak256("ex-ac");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        manager.evaluate(id, _one(address(p1)), _empty(), _empty());
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        assertEq(p1.session(id).phase, ContractNetLib.PART_ACCEPTED);
    }

    function test_expireDoesNotAffectOtherConversation() public {
        bytes32 a = keccak256("ex-a");
        bytes32 b = keccak256("ex-b");
        uint64 by = _deadline();
        manager.cfp(_one(address(p1)), _cfp(a, by));
        manager.cfp(_one(address(p1)), _cfp(b, by));
        vm.warp(uint256(by) + 1);
        p1.expire(a);
        assertEq(p1.session(a).phase, ContractNetLib.PART_NONE);
        assertEq(p1.session(b).phase, ContractNetLib.PART_CFPED);
    }

    function test_reuseAfterExpireNoTombstone() public {
        bytes32 id = keccak256("ex-re");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_one(address(p1)), cfp);
        vm.warp(uint256(by) + 1);
        p1.expire(id);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.expire(id);
        manager.evaluate(id, _empty(), _empty(), _one(address(p1)));
        _assertNetGone(id);
        manager.cfp(_one(address(p1)), _cfp(id, uint64(block.timestamp + 50)));
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
    }

    function test_snapshot_expire() public {
        bytes32 id = keccak256("sx");
        uint64 by = _deadline();
        manager.cfp(_one(address(p1)), _cfp(id, by));
        vm.warp(uint256(by) + 1);
        p1.expire(id);
    }
}
