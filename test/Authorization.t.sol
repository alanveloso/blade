pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Agent} from "../src/core/Agent.sol";
import {IAgent} from "../src/core/IAgent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {RequestAgent, RequestPhase, RequestRole} from "../src/core/RequestAgent.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {ContractNetParticipant} from "../src/core/ContractNetParticipant.sol";
import {ScriptedRequestAgent} from "./Request.t.sol";
import {ExposedContractNetManager, ExposedContractNetParticipant} from "./ContractNetActors.sol";

error InboundDenied();

contract GatingRequestAgent is RequestAgent {
    bytes32 public immutable blocked;

    constructor(address trustedRelay_, bytes32 blocked_) Agent(trustedRelay_) {
        blocked = blocked_;
    }

    function _authorizeInbound(Message calldata message) internal view override {
        if (message.conversationId == blocked) {
            revert InboundDenied();
        }
    }
}

contract GatingCnParticipant is ContractNetParticipant {
    bytes32 public immutable blocked;

    constructor(bytes32 blocked_) Agent(address(0)) {
        blocked = blocked_;
    }

    function _authorizeInbound(Message calldata message) internal view override {
        if (message.conversationId == blocked) {
            revert InboundDenied();
        }
    }
}

contract AuthorizationTest is Test {
    function test_defaultAgentRemainsPermissive() public {
        Agent a = new Agent(address(0));
        Message memory m;
        m.performative = uint8(Performative.Inform);
        m.protocol = uint8(Protocol.None);
        IAgent(address(a)).handle(m);
    }

    function test_rejectedRequestLeavesEmptyStatus() public {
        bytes32 blocked = keccak256("deny-req");
        GatingRequestAgent gated = new GatingRequestAgent(address(0), blocked);
        ScriptedRequestAgent peer = new ScriptedRequestAgent(address(0));
        Message memory req;
        req.performative = uint8(Performative.Request);
        req.protocol = uint8(Protocol.FipaRequest);
        req.conversationId = blocked;
        vm.expectRevert(InboundDenied.selector);
        peer.startRequest(address(gated), req);
        RequestAgent.Status memory s = gated.requestStatus(blocked);
        assertEq(uint8(s.phase), uint8(RequestPhase.None));
        assertEq(uint8(s.role), uint8(RequestRole.None));
        assertEq(s.transportPeer, address(0));
        assertEq(s.logicalPeer, bytes32(0));
    }

    function test_authorizedRequestMutatesAsBefore() public {
        GatingRequestAgent gated = new GatingRequestAgent(address(0), keccak256("other"));
        ScriptedRequestAgent peer = new ScriptedRequestAgent(address(0));
        bytes32 id = keccak256("ok-req");
        Message memory req;
        req.performative = uint8(Performative.Request);
        req.protocol = uint8(Protocol.FipaRequest);
        req.conversationId = id;
        peer.startRequest(address(gated), req);
        assertEq(uint8(gated.requestStatus(id).phase), uint8(RequestPhase.Requested));
        assertEq(gated.requestStatus(id).transportPeer, address(peer));
    }

    function test_rejectedCfpLeavesEmptySession() public {
        bytes32 blocked = keccak256("deny-cfp");
        GatingCnParticipant gated = new GatingCnParticipant(blocked);
        ExposedContractNetManager manager = new ExposedContractNetManager(address(0));
        address[] memory parts = new address[](1);
        parts[0] = address(gated);
        Message memory cfp;
        cfp.performative = uint8(Performative.Cfp);
        cfp.protocol = uint8(Protocol.FipaContractNet);
        cfp.conversationId = blocked;
        cfp.replyBy = uint64(block.timestamp + 10);
        vm.expectRevert(InboundDenied.selector);
        manager.cfp(parts, cfp);
        assertEq(gated.session(blocked).phase, ContractNetLib.PART_NONE);
        assertEq(gated.session(blocked).manager, address(0));
        assertEq(gated.session(blocked).replyBy, 0);
        assertEq(manager.conversation(blocked).live, 0);
    }

    function test_authorizedCfpMutatesAsBefore() public {
        GatingCnParticipant gated = new GatingCnParticipant(keccak256("other"));
        ExposedContractNetManager manager = new ExposedContractNetManager(address(0));
        address[] memory parts = new address[](1);
        parts[0] = address(gated);
        bytes32 id = keccak256("ok-cfp");
        Message memory cfp;
        cfp.performative = uint8(Performative.Cfp);
        cfp.protocol = uint8(Protocol.FipaContractNet);
        cfp.conversationId = id;
        cfp.replyBy = uint64(block.timestamp + 10);
        manager.cfp(parts, cfp);
        assertEq(gated.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(gated.session(id).manager, address(manager));
    }

    function test_relayAuthenticationRunsBeforeAuthorization() public {
        Agent relay = new Agent(address(0));
        bytes32 blocked = keccak256("any");
        GatingRequestAgent gated = new GatingRequestAgent(address(relay), blocked);
        Message memory req;
        req.performative = uint8(Performative.Request);
        req.protocol = uint8(Protocol.FipaRequest);
        req.conversationId = blocked;
        vm.prank(address(relay));
        vm.expectRevert(Agent.RelayMustSetLogicalSender.selector);
        IAgent(address(gated)).handle(req);

        req.logicalSender = keccak256("spoof");
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        IAgent(address(gated)).handle(req);
    }
}
