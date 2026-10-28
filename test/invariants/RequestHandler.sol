pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RequestAgent, RequestPhase, RequestRole} from "../../src/core/RequestAgent.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {ScriptedRequestAgent} from "../Request.t.sol";

/// @dev Stateful Request sequences. Invalid calls are caught; ghost state is the observation oracle.
contract RequestHandler is Test {
    uint256 internal constant N_IDS = 3;
    uint256 internal constant N_SLOTS = N_IDS * 2;
    bytes internal constant NEEDLE =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    ScriptedRequestAgent public alice;
    ScriptedRequestAgent public bob;
    ScriptedRequestAgent public stranger;
    address public relay;

    bytes32[N_IDS] internal ids;
    uint256 public calls;
    uint256 public successfulMutations;
    /// @dev Tokens of instances that reached a terminal act; a live session must never reuse one.
    bytes32[] internal retired;
    uint256 public staleAccepted;
    uint256 public wrongTokenAccepted;

    constructor() {
        relay = address(0xBEEF);
        alice = new ScriptedRequestAgent(relay);
        bob = new ScriptedRequestAgent(relay);
        stranger = new ScriptedRequestAgent(relay);
        ids[0] = keccak256("inv-req-0");
        ids[1] = keccak256("inv-req-1");
        ids[2] = keccak256("inv-req-2");
    }

    function openAliceToBob(uint8 idSel) external {
        _open(alice, bob, _id(idSel));
    }

    function openBobToAlice(uint8 idSel) external {
        _open(bob, alice, _id(idSel));
    }

    function participantRespond(uint8 idSel, uint8 actSel) external {
        bytes32 id = _id(idSel);
        (ScriptedRequestAgent participant, ScriptedRequestAgent initiator) = _roles(id);
        if (address(participant) == address(0)) {
            return;
        }
        bytes32 token = participant.requestStatus(id).replyWith;
        Message memory inbound = _base(id);
        inbound.replyWith = token;
        Message memory outbound = _reply(id, _requestAct(actSel), token);
        bytes32[N_SLOTS] memory before = _packAll();
        try participant.respond(inbound, address(initiator), outbound) {
            successfulMutations++;
            _assertIsolation(id, before);
            if (participant.requestStatus(id).phase == RequestPhase.None) {
                retired.push(token);
            }
        } catch {
            _assertUnchanged(before);
        }
        calls++;
    }

    /// @dev Legitimate transport peer delivers, bypassing its own Core, an act carrying a token
    /// from a previous instance (any id). Only the initiator's correlation check can stop it.
    function staleTokenReply(uint8 idSel, uint8 actSel, uint16 tokSel) external {
        if (retired.length == 0) {
            return;
        }
        bytes32 id = _id(idSel);
        (ScriptedRequestAgent participant, ScriptedRequestAgent initiator) = _roles(id);
        if (address(participant) == address(0)) {
            return;
        }
        bytes32 stale = retired[tokSel % retired.length];
        bytes32[N_SLOTS] memory before = _packAll();
        vm.prank(address(participant));
        try initiator.handle(_reply(id, _requestAct(actSel), stale)) {
            staleAccepted++;
        } catch {}
        _assertUnchanged(before);
        calls++;
    }

    function wrongTokenReply(uint8 idSel, uint8 actSel, bytes32 wrong) external {
        bytes32 id = _id(idSel);
        (ScriptedRequestAgent participant, ScriptedRequestAgent initiator) = _roles(id);
        if (address(participant) == address(0) || wrong == initiator.requestStatus(id).replyWith) {
            return;
        }
        bytes32[N_SLOTS] memory before = _packAll();
        vm.prank(address(participant));
        try initiator.handle(_reply(id, _requestAct(actSel), wrong)) {
            wrongTokenAccepted++;
        } catch {}
        _assertUnchanged(before);
        calls++;
    }

    /// @dev Application hands the participant Core an inbound/outbound pair that is internally
    /// consistent but does not match the stored session token.
    function forgedInboundRespond(uint8 idSel, uint8 actSel, bytes32 forged) external {
        bytes32 id = _id(idSel);
        (ScriptedRequestAgent participant, ScriptedRequestAgent initiator) = _roles(id);
        if (address(participant) == address(0) || forged == participant.requestStatus(id).replyWith)
        {
            return;
        }
        Message memory inbound = _base(id);
        inbound.replyWith = forged;
        bytes32[N_SLOTS] memory before = _packAll();
        try participant.respond(
            inbound, address(initiator), _reply(id, _requestAct(actSel), forged)
        ) {
            wrongTokenAccepted++;
        } catch {}
        _assertUnchanged(before);
        calls++;
    }

    function wrongPeerHandle(uint8 idSel, uint8 actSel) external {
        bytes32 id = _id(idSel);
        bytes32[N_SLOTS] memory before = _packAll();
        vm.prank(address(stranger));
        try alice.handle(_reply(id, _requestAct(actSel), alice.requestStatus(id).replyWith)) {}
            catch {}
        vm.prank(address(stranger));
        try bob.handle(_reply(id, _requestAct(actSel), bob.requestStatus(id).replyWith)) {} catch {}
        _assertUnchanged(before);
        calls++;
    }

    function relayWrongLogical(uint8 idSel) external {
        bytes32 id = _id(idSel);
        bytes32[N_SLOTS] memory before = _packAll();
        Message memory m = _reply(id, Performative.Inform, alice.requestStatus(id).replyWith);
        m.logicalSender = keccak256("eve");
        vm.prank(relay);
        try alice.handle(m) {} catch {}
        m.inReplyTo = bob.requestStatus(id).replyWith;
        vm.prank(relay);
        try bob.handle(m) {} catch {}
        _assertUnchanged(before);
        calls++;
    }

    function nativeLogicalSpoof(uint8 idSel) external {
        bytes32 id = _id(idSel);
        bytes32[N_SLOTS] memory before = _packAll();
        Message memory m = _base(id);
        m.replyWith = keccak256("spoof-rw");
        m.logicalSender = keccak256("spoof");
        vm.prank(address(alice));
        try bob.handle(m) {} catch {}
        _assertUnchanged(before);
        calls++;
    }

    function assertRequestInvariants() external view {
        for (uint256 i = 0; i < N_IDS; i++) {
            _assertAgent(alice, ids[i]);
            _assertAgent(bob, ids[i]);
            _assertPair(ids[i]);
            _assertFresh(alice.requestStatus(ids[i]).replyWith);
            _assertFresh(bob.requestStatus(ids[i]).replyWith);
        }
        assertEq(staleAccepted, 0, "R-C2 stale token accepted");
        assertEq(wrongTokenAccepted, 0, "R-C1 wrong token accepted");
        _assertNoNeedle(address(alice));
        _assertNoNeedle(address(bob));
    }

    function _open(ScriptedRequestAgent from, ScriptedRequestAgent to, bytes32 id) internal {
        bytes32[N_SLOTS] memory before = _packAll();
        try from.startRequest(address(to), _base(id)) {
            successfulMutations++;
            _assertIsolation(id, before);
        } catch {
            _assertUnchanged(before);
        }
        calls++;
    }

    function _roles(bytes32 id)
        internal
        view
        returns (ScriptedRequestAgent participant, ScriptedRequestAgent initiator)
    {
        if (alice.requestStatus(id).role == RequestRole.Participant) {
            return (alice, bob);
        }
        if (bob.requestStatus(id).role == RequestRole.Participant) {
            return (bob, alice);
        }
    }

    function _id(uint8 sel) internal view returns (bytes32) {
        return ids[sel % N_IDS];
    }

    function _base(bytes32 id) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = id;
        m.content = NEEDLE;
    }

    function _reply(bytes32 id, Performative act, bytes32 token)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(act);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = id;
        m.inReplyTo = token;
    }

    function _requestAct(uint8 sel) internal pure returns (Performative) {
        uint256 i = sel % 6;
        if (i == 0) return Performative.Agree;
        if (i == 1) return Performative.Refuse;
        if (i == 2) return Performative.Inform;
        if (i == 3) return Performative.Failure;
        if (i == 4) return Performative.NotUnderstood;
        return Performative.Cfp;
    }

    function _assertAgent(RequestAgent a, bytes32 id) internal view {
        RequestAgent.Status memory s = a.requestStatus(id);
        assertTrue(uint8(s.phase) <= uint8(RequestPhase.Agreed), "R-I1 stored Terminal");
        if (s.phase == RequestPhase.None) {
            assertEq(uint8(s.role), uint8(RequestRole.None), "R-I2 leftover role");
            assertEq(s.transportPeer, address(0), "R-I2 leftover peer");
            assertEq(s.logicalPeer, bytes32(0), "R-I2 leftover logical");
            assertEq(s.replyWith, bytes32(0), "R-I2 leftover token");
            bytes32 slot0 = keccak256(abi.encode(id, uint256(0)));
            for (uint256 k = 0; k < 3; k++) {
                assertEq(vm.load(address(a), bytes32(uint256(slot0) + k)), 0, "R-I2 raw slot");
            }
        } else {
            assertTrue(s.role == RequestRole.Initiator || s.role == RequestRole.Participant);
            assertTrue(s.transportPeer != address(0), "R-I3 missing peer");
            assertTrue(s.replyWith != bytes32(0), "R-C3 live session without token");
        }
    }

    function _assertPair(bytes32 id) internal view {
        RequestAgent.Status memory sa = alice.requestStatus(id);
        RequestAgent.Status memory sb = bob.requestStatus(id);
        if (sa.phase == RequestPhase.None || sb.phase == RequestPhase.None) {
            return;
        }
        assertTrue(sa.role != sb.role, "both same role");
        assertEq(uint8(sa.phase), uint8(sb.phase), "phase skew");
        assertEq(sa.replyWith, sb.replyWith, "R-C4 token skew");
    }

    function _assertFresh(bytes32 token) internal view {
        if (token == bytes32(0)) {
            return;
        }
        for (uint256 i = 0; i < retired.length; i++) {
            assertTrue(retired[i] != token, "R-C5 retired token reused");
        }
    }

    function _assertNoNeedle(address target) internal view {
        bytes32 n = bytes32(NEEDLE);
        for (uint256 i = 0; i < 16; i++) {
            assertTrue(vm.load(target, bytes32(i)) != n, "content stored");
        }
    }

    function _packAll() internal view returns (bytes32[N_SLOTS] memory out) {
        uint256 k;
        for (uint256 i = 0; i < N_IDS; i++) {
            out[k++] = _pack(alice, ids[i]);
            out[k++] = _pack(bob, ids[i]);
        }
    }

    function _pack(RequestAgent a, bytes32 id) internal view returns (bytes32) {
        RequestAgent.Status memory s = a.requestStatus(id);
        return keccak256(abi.encode(s.phase, s.role, s.transportPeer, s.logicalPeer, s.replyWith));
    }

    function _assertUnchanged(bytes32[N_SLOTS] memory before) internal view {
        bytes32[N_SLOTS] memory after_ = _packAll();
        for (uint256 i = 0; i < N_SLOTS; i++) {
            assertEq(after_[i], before[i], "R-I5/I6 silent mutation");
        }
    }

    function _assertIsolation(bytes32 touched, bytes32[N_SLOTS] memory before) internal view {
        uint256 k;
        for (uint256 i = 0; i < N_IDS; i++) {
            if (ids[i] != touched) {
                assertEq(_pack(alice, ids[i]), before[k], "R-I4 alice sibling");
                assertEq(_pack(bob, ids[i]), before[k + 1], "R-I4 bob sibling");
            }
            k += 2;
        }
    }
}
