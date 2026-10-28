pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RequestAgent, RequestPhase, RequestRole} from "../src/core/RequestAgent.sol";
import {Message, MessageLib} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {Agent} from "../src/core/Agent.sol";

contract ScriptedRequestAgent is RequestAgent {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}

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
    Agent internal relaySink;

    bytes internal constant UNIQUE_CONTENT =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    function setUp() public {
        relaySink = new Agent(address(0));
        alice = new ScriptedRequestAgent(address(relaySink));
        bob = new ScriptedRequestAgent(address(relaySink));
    }

    /// @dev Outbound Request as the application builds it: `replyWith` is assigned by the Core.
    function _requestAt(bytes32 conversationId) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = conversationId;
        m.content = UNIQUE_CONTENT;
    }

    function _request() internal pure returns (Message memory m) {
        return _requestAt(keccak256("tb1"));
    }

    /// @dev Relay-delivered Request (opaque logical initiator chooses the token).
    function _relayedRequest() internal pure returns (Message memory m) {
        m = _request();
        m.replyWith = keccak256("rw");
    }

    /// @dev alice -> bob Request; returns the message as delivered (with the Core-assigned token).
    function _open(Message memory req) internal returns (Message memory) {
        alice.startRequest(address(bob), req);
        req.replyWith = alice.requestStatus(req.conversationId).replyWith;
        return req;
    }

    function _assertCleared(RequestAgent agent, bytes32 conversationId) internal view {
        RequestAgent.Status memory s = agent.requestStatus(conversationId);
        assertEq(uint8(s.phase), uint8(RequestPhase.None));
        assertEq(uint8(s.role), uint8(RequestRole.None));
        assertEq(s.transportPeer, address(0));
        assertEq(s.logicalPeer, bytes32(0));
        assertEq(s.replyWith, bytes32(0));
        bytes32 slot0 = keccak256(abi.encode(conversationId, uint256(0)));
        assertEq(vm.load(address(agent), slot0), bytes32(0));
        assertEq(vm.load(address(agent), bytes32(uint256(slot0) + 1)), bytes32(0));
        assertEq(vm.load(address(agent), bytes32(uint256(slot0) + 2)), bytes32(0));
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
        assertTrue(s.replyWith != bytes32(0), "live session without token");
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

    function _copy(Message memory m) internal pure returns (Message memory) {
        return abi.decode(abi.encode(m), (Message));
    }

    function _statusHash(RequestAgent agent, bytes32 id) internal view returns (bytes32) {
        return keccak256(abi.encode(agent.requestStatus(id)));
    }

    function test_requestRefuse() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestInformSkipsAgree() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestFailureSkipsAgree() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Failure));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestAgreeRetainsMinimalState() public {
        Message memory req = _open(_request());
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
        Message memory req = _open(_request());
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
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        bob.respond(req, address(alice), _replyAct(req, Performative.Failure));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
    }

    function test_requestNotUnderstood() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.NotUnderstood));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_outOfEnumPerformativeOnActiveRequestReverts() public {
        Message memory req = _open(_request());
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
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
    }

    function test_duplicateParticipantAgreeReverts() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
    }

    function test_relayWrongLogicalSenderReverts() public {
        Message memory req = _relayedRequest();
        req.logicalSender = keccak256("alice-logical");
        vm.prank(address(relaySink));
        bob.handle(req);
        Message memory inf = _replyAct(req, Performative.Inform);
        inf.logicalSender = keccak256("eve-logical");
        vm.prank(address(relaySink));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        bob.handle(inf);
        _assertActive(
            bob,
            req.conversationId,
            RequestPhase.Requested,
            RequestRole.Participant,
            address(relaySink),
            keccak256("alice-logical")
        );
    }

    /// @dev Revised for the JAAMAS review: reuse of a `conversationId` after cleanup is still
    /// allowed, but the new instance gets a fresh Core-assigned token and the previous instance's
    /// replies no longer correlate with it.
    function test_reuseConversationIdAfterCleanup() public {
        Message memory first = _open(_request());
        bob.respond(first, address(alice), _replyAct(first, Performative.Refuse));
        _assertCleared(alice, first.conversationId);
        _assertCleared(bob, first.conversationId);

        Message memory second = _open(_request());
        assertEq(second.conversationId, first.conversationId);
        assertTrue(second.replyWith != first.replyWith, "token reused across instances");
        _assertActive(
            alice,
            second.conversationId,
            RequestPhase.Requested,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
        _assertActive(
            bob,
            second.conversationId,
            RequestPhase.Requested,
            RequestRole.Participant,
            address(alice),
            bytes32(0)
        );
        assertEq(bob.requestStatus(second.conversationId).replyWith, second.replyWith);

        vm.prank(address(bob));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.handle(_replyAct(first, Performative.Inform));
        _assertActive(
            alice,
            second.conversationId,
            RequestPhase.Requested,
            RequestRole.Initiator,
            address(bob),
            bytes32(0)
        );
    }

    function test_secondInformAfterAgreeReverts() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_invalidDuplicateRequest() public {
        _open(_request());
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        alice.startRequest(address(bob), _request());
    }

    function test_clearedSessionRejectsFurtherParticipantReply() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
    }

    function test_cleanupDoesNotCorruptOtherConversation() public {
        Message memory keep = _open(_requestAt(keccak256("keep")));
        bob.respond(keep, address(alice), _replyAct(keep, Performative.Agree));
        Message memory drop = _open(_requestAt(keccak256("drop")));
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
        Message memory req = _open(_request());
        ScriptedRequestAgent charlie = new ScriptedRequestAgent(address(relaySink));
        vm.prank(address(charlie));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        bob.handle(_replyAct(req, Performative.Inform));
    }

    function test_outboundContinuationCannotBeRedirected() public {
        Message memory req = _open(_request());
        ScriptedRequestAgent charlie = new ScriptedRequestAgent(address(relaySink));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        bob.respond(req, address(charlie), _replyAct(req, Performative.Inform));
        _assertActive(
            bob,
            req.conversationId,
            RequestPhase.Requested,
            RequestRole.Participant,
            address(alice),
            bytes32(0)
        );
    }

    function test_relayRequestThenRefuse() public {
        Message memory req = _relayedRequest();
        req.logicalSender = keccak256("external-alice");
        vm.prank(address(relaySink));
        bob.handle(req);
        assertEq(uint8(bob.requestStatus(req.conversationId).phase), uint8(RequestPhase.Requested));
        req.logicalSender = bytes32(0);
        bob.respond(req, address(relaySink), _replyAct(req, Performative.Refuse));
        _assertCleared(bob, req.conversationId);
    }

    function test_requestRefuseDoesNotStoreContent() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        _assertContentAbsent(address(alice));
        _assertContentAbsent(address(bob));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    // --- Correlation (JAAMAS review, reviewer 3) ---

    function test_corr_tokenAssignedByCoreAndDeliveredToPeer() public {
        Message memory req = _request();
        alice.startRequest(address(bob), req);
        bytes32 aliceToken = alice.requestStatus(req.conversationId).replyWith;
        bytes32 bobToken = bob.requestStatus(req.conversationId).replyWith;
        assertTrue(aliceToken != bytes32(0));
        assertEq(bobToken, aliceToken);
        // The memory copy handed to `_startRequest` is updated in place for the application.
        ExposedTokenRequester r = new ExposedTokenRequester();
        assertEq(r.startAndReturnToken(address(bob), _requestAt(keccak256("x"))), r.lastToken());
    }

    function test_corr_correctInReplyToAccepted() public {
        Message memory req = _open(_request());
        Message memory inf = _replyAct(req, Performative.Inform);
        assertEq(inf.inReplyTo, alice.requestStatus(req.conversationId).replyWith);
        vm.prank(address(bob));
        alice.handle(inf);
        _assertCleared(alice, req.conversationId);
    }

    /// @dev Raw delivery from the authorized transport peer: the participant's Core is bypassed,
    /// so the only check exercised is the initiator's inbound correlation.
    function test_corr_wrongInReplyToRejectedAtInitiator() public {
        Message memory req = _open(_request());
        bytes32 beforeHash = _statusHash(alice, req.conversationId);
        Message memory inf = _replyAct(req, Performative.Inform);
        inf.inReplyTo = keccak256("wrong");
        vm.prank(address(bob));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.handle(inf);
        assertEq(_statusHash(alice, req.conversationId), beforeHash);
    }

    /// @dev Initiator is a stateless `Agent` that accepts any reply, so the only component able
    /// to reject is the participant's outbound session check.
    function _openFromSink() internal returns (Message memory req, Agent sink) {
        sink = new Agent(address(0));
        req = _relayedRequest();
        vm.prank(address(sink));
        bob.handle(req);
    }

    /// @dev The application hands the participant Core a forged `inbound` that agrees with the
    /// wrong `inReplyTo`, so `Agent._reply`'s inbound check passes; the session check must fire.
    function test_corr_wrongInReplyToRejectedAtParticipantOutbound() public {
        (Message memory req, Agent sink) = _openFromSink();
        bytes32 beforeHash = _statusHash(bob, req.conversationId);
        Message memory forged = _copy(req);
        forged.replyWith = keccak256("wrong");
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        bob.respond(forged, address(sink), _replyAct(forged, Performative.Inform));
        assertEq(_statusHash(bob, req.conversationId), beforeHash);
        bob.respond(req, address(sink), _replyAct(req, Performative.Inform));
        _assertCleared(bob, req.conversationId);
    }

    function test_corr_missingInReplyToRejectedAtInitiator() public {
        Message memory req = _open(_request());
        Message memory agree = _replyAct(req, Performative.Agree);
        agree.inReplyTo = bytes32(0);
        vm.prank(address(bob));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.handle(agree);
        assertEq(
            uint8(alice.requestStatus(req.conversationId).phase), uint8(RequestPhase.Requested)
        );
    }

    function test_corr_missingInReplyToRejectedAtParticipantOutbound() public {
        (Message memory req, Agent sink) = _openFromSink();
        Message memory forged = _copy(req);
        forged.replyWith = bytes32(0);
        Message memory agree = _replyAct(forged, Performative.Agree);
        assertEq(agree.inReplyTo, bytes32(0));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        bob.respond(forged, address(sink), agree);
        assertEq(uint8(bob.requestStatus(req.conversationId).phase), uint8(RequestPhase.Requested));
    }

    function test_corr_inboundRequestWithoutTokenRejected() public {
        Message memory req = _request();
        vm.prank(address(alice));
        vm.expectRevert(RequestAgent.MissingReplyWith.selector);
        bob.handle(req);
        _assertCleared(bob, req.conversationId);
    }

    function test_corr_applicationChosenTokenRejected() public {
        Message memory req = _request();
        req.replyWith = keccak256("app-token");
        vm.expectRevert(RequestAgent.ReplyWithAssignedByCore.selector);
        alice.startRequest(address(bob), req);
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_corr_unauthorizedParticipantWithCorrectTokenRejected() public {
        Message memory req = _open(_request());
        ScriptedRequestAgent charlie = new ScriptedRequestAgent(address(relaySink));
        bytes32 beforeHash = _statusHash(alice, req.conversationId);
        vm.prank(address(charlie));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        alice.handle(_replyAct(req, Performative.Inform));
        assertEq(_statusHash(alice, req.conversationId), beforeHash);
    }

    /// @dev Instance 1 reaches Agreed and terminates; instance 2 reuses the id. Every act of
    /// instance 1 (Agree/Inform/Failure/Refuse/NotUnderstood) replayed by the legitimate peer
    /// must be rejected by both ends without touching instance 2.
    function test_corr_staleReplyDuringNewConversationRejected() public {
        Message memory first = _open(_request());
        bob.respond(first, address(alice), _replyAct(first, Performative.Agree));
        bob.respond(first, address(alice), _replyAct(first, Performative.Inform));
        Message memory second = _open(_request());
        bytes32 aliceBefore = _statusHash(alice, second.conversationId);
        bytes32 bobBefore = _statusHash(bob, second.conversationId);

        Performative[5] memory acts = [
            Performative.Agree,
            Performative.Inform,
            Performative.Failure,
            Performative.Refuse,
            Performative.NotUnderstood
        ];
        for (uint256 i = 0; i < acts.length; i++) {
            vm.prank(address(bob));
            vm.expectRevert(Agent.ReplyWithMismatch.selector);
            alice.handle(_replyAct(first, acts[i]));
            vm.expectRevert(Agent.ReplyWithMismatch.selector);
            bob.respond(first, address(alice), _replyAct(first, acts[i]));
        }
        assertEq(_statusHash(alice, second.conversationId), aliceBefore);
        assertEq(_statusHash(bob, second.conversationId), bobBefore);

        bob.respond(second, address(alice), _replyAct(second, Performative.Inform));
        _assertCleared(alice, second.conversationId);
        _assertCleared(bob, second.conversationId);
    }

    /// @dev "Same id, same token": the application cannot pin the old token, and the Core never
    /// re-derives it, so the old reply is rejected on every reuse.
    function test_corr_reuseConversationIdWithSameTokenImpossible() public {
        Message memory first = _open(_request());
        bob.respond(first, address(alice), _replyAct(first, Performative.Refuse));

        Message memory pinned = _request();
        pinned.replyWith = first.replyWith;
        vm.expectRevert(RequestAgent.ReplyWithAssignedByCore.selector);
        alice.startRequest(address(bob), pinned);

        bytes32 previous = first.replyWith;
        for (uint256 i = 0; i < 5; i++) {
            Message memory again = _open(_request());
            assertTrue(again.replyWith != previous, "token repeated");
            assertTrue(again.replyWith != first.replyWith, "first token repeated");
            vm.prank(address(bob));
            vm.expectRevert(Agent.ReplyWithMismatch.selector);
            alice.handle(_replyAct(first, Performative.Inform));
            bob.respond(again, address(alice), _replyAct(again, Performative.Refuse));
            previous = again.replyWith;
        }
    }

    function test_corr_requestAgreeInformCarriesSessionToken() public {
        Message memory req = _open(_request());
        bytes32 token = req.replyWith;
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        assertEq(alice.requestStatus(req.conversationId).replyWith, token);
        assertEq(bob.requestStatus(req.conversationId).replyWith, token);
        Message memory staleInform = _replyAct(req, Performative.Inform);
        staleInform.inReplyTo = keccak256("other");
        vm.prank(address(bob));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.handle(staleInform);
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_corr_concurrentConversationsDoNotCrossCorrelate() public {
        ScriptedRequestAgent carol = new ScriptedRequestAgent(address(relaySink));
        Message memory a = _open(_requestAt(keccak256("conc-a")));
        Message memory b = _open(_requestAt(keccak256("conc-b")));
        Message memory reqC = _requestAt(keccak256("conc-c"));
        alice.startRequest(address(carol), reqC);
        reqC.replyWith = alice.requestStatus(reqC.conversationId).replyWith;
        assertTrue(a.replyWith != b.replyWith && b.replyWith != reqC.replyWith);

        // Token of conversation b presented on conversation a.
        Message memory crossed = _replyAct(a, Performative.Inform);
        crossed.inReplyTo = b.replyWith;
        vm.prank(address(bob));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.handle(crossed);

        // Correct token of conversation c, but from the peer of conversation a/b.
        vm.prank(address(bob));
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        alice.handle(_replyAct(reqC, Performative.Inform));

        bob.respond(b, address(alice), _replyAct(b, Performative.Agree));
        carol.respond(reqC, address(alice), _replyAct(reqC, Performative.Refuse));
        assertEq(uint8(alice.requestStatus(a.conversationId).phase), uint8(RequestPhase.Requested));
        assertEq(uint8(alice.requestStatus(b.conversationId).phase), uint8(RequestPhase.Agreed));
        _assertCleared(alice, reqC.conversationId);
        bob.respond(a, address(alice), _replyAct(a, Performative.Inform));
        bob.respond(b, address(alice), _replyAct(b, Performative.Inform));
        _assertCleared(alice, a.conversationId);
        _assertCleared(alice, b.conversationId);
    }

    function test_corr_initiatorNotUnderstoodMustKeepToken() public {
        Message memory req = _open(_request());
        Message memory nu;
        nu.performative = uint8(Performative.NotUnderstood);
        nu.protocol = req.protocol;
        nu.conversationId = req.conversationId;

        // Initiator's own Core refuses a continuation that does not keep the session token.
        Message memory noReply;
        noReply.conversationId = req.conversationId;
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.respond(noReply, address(bob), nu);

        // Raw delivery with a wrong token is refused by the participant.
        nu.replyWith = keccak256("wrong");
        vm.prank(address(alice));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        bob.handle(nu);
        assertEq(uint8(bob.requestStatus(req.conversationId).phase), uint8(RequestPhase.Requested));

        nu.replyWith = req.replyWith;
        alice.respond(noReply, address(bob), nu);
        _assertCleared(alice, req.conversationId);
        _assertCleared(bob, req.conversationId);
    }

    function test_corr_relayParticipantCorrelation() public {
        Message memory req = _relayedRequest();
        req.logicalSender = keccak256("external-alice");
        vm.prank(address(relaySink));
        bob.handle(req);
        assertEq(bob.requestStatus(req.conversationId).replyWith, req.replyWith);
        req.logicalSender = bytes32(0);

        Message memory forged = _copy(req);
        forged.replyWith = keccak256("wrong");
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        bob.respond(forged, address(relaySink), _replyAct(forged, Performative.Agree));

        bob.respond(req, address(relaySink), _replyAct(req, Performative.Agree));

        Message memory nu;
        nu.performative = uint8(Performative.NotUnderstood);
        nu.protocol = req.protocol;
        nu.conversationId = req.conversationId;
        nu.logicalSender = keccak256("external-alice");
        nu.replyWith = keccak256("stale");
        vm.prank(address(relaySink));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        bob.handle(nu);
        assertEq(uint8(bob.requestStatus(req.conversationId).phase), uint8(RequestPhase.Agreed));

        nu.replyWith = req.replyWith;
        vm.prank(address(relaySink));
        bob.handle(nu);
        _assertCleared(bob, req.conversationId);
    }

    function test_corr_relayRequestWithoutTokenRejected() public {
        Message memory req = _request();
        req.logicalSender = keccak256("external-alice");
        vm.prank(address(relaySink));
        vm.expectRevert(RequestAgent.MissingReplyWith.selector);
        bob.handle(req);
        _assertCleared(bob, req.conversationId);
    }

    /// @dev LIMITATION (documented): a participant cannot tell a fresh relayed Request from a
    /// replay of a closed one; replay freshness on the relay path is the relay's responsibility.
    function test_limitation_relayReplayOfClosedRequestReopensParticipant() public {
        Message memory req = _relayedRequest();
        req.logicalSender = keccak256("external-alice");
        vm.prank(address(relaySink));
        bob.handle(req);
        Message memory local = _copy(req);
        local.logicalSender = bytes32(0);
        bob.respond(local, address(relaySink), _replyAct(local, Performative.Inform));
        _assertCleared(bob, req.conversationId);
        vm.prank(address(relaySink));
        bob.handle(req);
        assertEq(uint8(bob.requestStatus(req.conversationId).phase), uint8(RequestPhase.Requested));
    }

    /// @dev LIMITATION (documented): sessions are keyed by `conversationId` only. A third agent
    /// that learns a pending id (e.g. from the mempool) can open it first at the participant,
    /// making the honest Request revert. Mitigations are application-level (`_authorizeInbound`,
    /// unpredictable ids); the Core does not claim front-running resistance.
    function test_limitation_conversationIdSquattingBlocksHonestRequest() public {
        ScriptedRequestAgent eve = new ScriptedRequestAgent(address(relaySink));
        Message memory req = _request();
        eve.startRequest(address(bob), req);
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        alice.startRequest(address(bob), _request());
        _assertCleared(alice, req.conversationId);
        assertEq(bob.requestStatus(req.conversationId).transportPeer, address(eve));
    }

    function testFuzz_corr_anyWrongTokenRejected(bytes32 wrong, uint8 actSel) public {
        Message memory req = _open(_request());
        vm.assume(wrong != req.replyWith);
        Performative[4] memory acts =
            [Performative.Agree, Performative.Inform, Performative.Failure, Performative.Refuse];
        Message memory m = _replyAct(req, acts[actSel % 4]);
        m.inReplyTo = wrong;
        bytes32 aliceBefore = _statusHash(alice, req.conversationId);
        vm.prank(address(bob));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        alice.handle(m);
        assertEq(_statusHash(alice, req.conversationId), aliceBefore);
    }

    function testFuzz_corr_tokensUniqueAcrossReuse(uint8 rounds) public {
        uint256 n = uint256(rounds) % 16 + 2;
        bytes32[] memory seen = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            Message memory req = _open(_request());
            for (uint256 j = 0; j < i; j++) {
                assertTrue(seen[j] != req.replyWith, "token collision");
            }
            seen[i] = req.replyWith;
            bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
        }
    }

    function test_snapshot_requestRefuse() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Refuse));
    }

    function test_snapshot_requestAgreeInform() public {
        Message memory req = _open(_request());
        bob.respond(req, address(alice), _replyAct(req, Performative.Agree));
        bob.respond(req, address(alice), _replyAct(req, Performative.Inform));
    }
}

/// @dev Shows the Core writes the assigned token back into the caller's memory message.
contract ExposedTokenRequester is RequestAgent {
    bytes32 public lastToken;

    constructor() Agent(address(0)) {}

    function startAndReturnToken(address to, Message memory outbound) external returns (bytes32) {
        _startRequest(to, outbound);
        lastToken = _request[outbound.conversationId].replyWith;
        return outbound.replyWith;
    }
}
