pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RequestAgent, RequestPhase, RequestRole} from "../src/core/RequestAgent.sol";
import {Message, MessageLib} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {Agent} from "../src/core/Agent.sol";

contract ScriptedRequestAgent is RequestAgent {
    constructor(address trustedAcc_) RequestAgent(trustedAcc_) {}

    function startRequest(address to, Message memory outbound) external {
        _startRequest(to, outbound);
    }

    function respond(Message calldata inbound, address to, Message memory outbound) external {
        _reply(inbound, to, outbound);
    }
}

contract RequestTest is Test {
    ScriptedRequestAgent internal alice;
    ScriptedRequestAgent internal bob;
    Agent internal accSink;

    bytes internal constant UNIQUE_CONTENT =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    function setUp() public {
        accSink = new Agent(address(0));
        alice = new ScriptedRequestAgent(address(accSink));
        bob = new ScriptedRequestAgent(address(accSink));
    }

    function _requestAt(bytes32 conversationId) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = conversationId;
        m.replyWith = keccak256("rw");
        m.content = UNIQUE_CONTENT;
    }

    function _request() internal pure returns (Message memory m) {
        return _requestAt(keccak256("tb1"));
    }

    function _assertCleared(RequestAgent agent, bytes32 conversationId) internal view {
        RequestAgent.Status memory s = agent.requestStatus(conversationId);
        assertEq(uint8(s.phase), uint8(RequestPhase.None));
        assertEq(uint8(s.role), uint8(RequestRole.None));
        assertEq(s.transportPeer, address(0));
        assertEq(s.logicalPeer, bytes32(0));
        bytes32 slot0 = keccak256(abi.encode(conversationId, uint256(0)));
        assertEq(vm.load(address(agent), slot0), bytes32(0));
        assertEq(vm.load(address(agent), bytes32(uint256(slot0) + 1)), bytes32(0));
    }

    function _assertActive(
        RequestAgent agent,
        bytes32 conversationId,
        RequestPhase phase,
        RequestRole role,
        address transportPeer,
        bytes32 logicalPeer
    ) internal view {
        RequestAgent.Status memory s = agent.requestStatus(conversationId);
        assertEq(uint8(s.phase), uint8(phase));
        assertEq(uint8(s.role), uint8(role));
        assertEq(s.transportPeer, transportPeer);
        assertEq(s.logicalPeer, logicalPeer);
    }

    function _assertContentAbsent(address target) internal view {
        bytes32 needle = bytes32(UNIQUE_CONTENT);
        for (uint256 i = 0; i < 16; i++) {
            assertTrue(vm.load(target, bytes32(i)) != needle);
        }
    }

    function _replyAct(Message memory inbound, Performative act)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(act);
        m.protocol = inbound.protocol;
        m.conversationId = inbound.conversationId;
        m.inReplyTo = inbound.replyWith;
    }

    function test_requestRefuse() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestInformSkipsAgree() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestFailureSkipsAgree() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Failure));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestAgreeRetainsMinimalState() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        _assertActive(
            alice,
            req.conversationId,
            RequestPhase.Agreed,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
        _assertActive(
            bob,
            req.conversationId,
            RequestPhase.Agreed,
            RequestRole.Participant,
            address(alice),
            bytes32(0)
        );
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestAgreeThenInform() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        _assertActive(
            bob,
            req.conversationId,
            RequestPhase.Agreed,
            RequestRole.Participant,
            address(alice),
            bytes32(0)
        );
        _assertActive(
            alice,
            req.conversationId,
            RequestPhase.Agreed,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestAgreeThenFailure() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        bob.respond(req, address(alice), _replyAct(req, Performative.Failure));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestNotUnderstood() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.NotUnderstood));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_outOfEnumPerformativeOnActiveRequestReverts() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        Message memory bad = _replyAct(req, Performative.Agree);
        bad.performative = 255;
        vm.prank(address(bob));
        vm.expectRevert();
        alice.handle(bad);
        _assertActive(
            alice,
            req.conversationId,
            RequestPhase.Requested,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
    }

    function test_invalidRefuseAfterAgree() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
    }

    function test_duplicateParticipantAgreeReverts() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
    }

    function test_accWrongLogicalSenderReverts() public {
        Message memory req = _request();
        req.logicalSender = keccak256("alice-logical");
        vm.prank(address(accSink));
        bob.handle(req);
        Message memory inf = _replyAct(req, Performative.Inform);
        inf.logicalSender = keccak256("eve-logical");
        vm.prank(address(accSink));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        bob.handle(inf);
        _assertActive(
            bob,
            req.conversationId,
            RequestPhase.Requested,
            RequestRole.Participant,
            address(accSink),
            keccak256("alice-logical")
        );
    }

    function test_reuseConversationIdAfterCleanup() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        _assertCleared(alice, req.conversationId);
        alice.startRequest(address(bob), req);
        _assertActive(
            alice,
            req.conversationId,
            RequestPhase.Requested,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
        _assertActive(
            bob,
            req.conversationId,
            RequestPhase.Requested,
            RequestRole.Participant,
            address(alice),
            bytes32(0)
        );
    }

    function test_secondInformAfterAgreeReverts() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_invalidDuplicateRequest() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        alice.startRequest(address(bob), req);
    }

    function test_clearedSessionRejectsFurtherParticipantReply() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
    }

    function test_cleanupDoesNotCorruptOtherConversation() public {
        Message memory keep = _requestAt(keccak256("keep"));
        Message memory drop = _requestAt(keccak256("drop"));
        alice.startRequest(address(bob), keep);
        bob.respond(keep, address(alice), _replyAct(keep, Performative.Agree));
        alice.startRequest(address(bob), drop);
        bob.respond(drop, address(alice), _replyAct(drop, Performative.Refuse));
        _assertCleared(alice, drop.conversationId);
        _assertCleared(bob, drop.conversationId);
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(drop, address(alice), _replyAct(drop, Performative.Inform));
        _assertActive(
            alice,
            keep.conversationId,
            RequestPhase.Agreed,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
        _assertActive(
            bob,
            keep.conversationId,
            RequestPhase.Agreed,
            RequestRole.Participant,
            address(alice),
            bytes32(0)
        );
        bob.respond(keep, address(alice), _replyAct(keep, Performative.Inform));
        _assertCleared(alice, keep.conversationId);
        _assertCleared(bob, keep.conversationId);
    }

    function test_fipaRequestRequiresConversationId() public {
        Message memory req = _request();
        req.conversationId = bytes32(0);
        vm.expectRevert(MessageLib.ProtocolRequiresConversationId.selector);
        alice.startRequest(address(bob), req);
    }

    function test_unexpectedPeerReverts() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        ScriptedRequestAgent charlie = new ScriptedRequestAgent(address(accSink));
        vm.prank(address(charlie));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        bob.handle(_replyAct(req, Performative.Inform));
    }

    function test_accRequestThenRefuse() public {
        Message memory req = _request();
        req.logicalSender = keccak256("jade-alice");
        vm.prank(address(accSink));
        bob.handle(req);
        assertEq(uint8(bob.requestStatus(req.conversationId).phase), uint8(RequestPhase.Requested));
        req.logicalSender = bytes32(0);
        bob.respond(req, address(accSink), _replyAct(req, Performative.Refuse));
        _assertCleared(bob, req.conversationId);
    }

    function test_requestRefuseDoesNotStoreContent() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_snapshot_requestRefuse() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
    }

    function test_snapshot_requestAgreeInform() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
    }
}
