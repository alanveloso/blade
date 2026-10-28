pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CompositeAgent} from "../examples/CompositeExample.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {IAgent} from "../src/core/IAgent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {RequestAgent, RequestPhase} from "../src/core/RequestAgent.sol";
import {ScriptedRequestAgent} from "./Request.t.sol";
import {ExposedContractNetManager, ExposedContractNetParticipant} from "./ContractNetActors.sol";

contract CompositionTest is Test {
    CompositeAgent internal self;
    ScriptedRequestAgent internal reqPeer;
    ExposedContractNetParticipant internal cnPeer;
    ExposedContractNetManager internal otherManager;

    function setUp() public {
        self = new CompositeAgent(address(0));
        reqPeer = new ScriptedRequestAgent(address(0));
        cnPeer = new ExposedContractNetParticipant(address(0));
        otherManager = new ExposedContractNetManager(address(0));
    }

    function _req(bytes32 id) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = id;
    }

    function _cfp(bytes32 id, uint64 by) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        m.replyBy = by;
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

    function _one(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _none() internal pure returns (address[] memory x) {}

    function test_requestInitiator() public {
        bytes32 id = keccak256("comp-ri");
        self.startRequest(address(reqPeer), _req(id));
        assertEq(uint8(self.requestStatus(id).phase), uint8(RequestPhase.Requested));
        reqPeer.respond(_req(id), address(self), _out(_req(id), Performative.Inform));
        assertEq(uint8(self.requestStatus(id).phase), uint8(RequestPhase.None));
    }

    function test_requestParticipant() public {
        bytes32 id = keccak256("comp-rp");
        reqPeer.startRequest(address(self), _req(id));
        assertEq(uint8(self.requestStatus(id).phase), uint8(RequestPhase.Requested));
        self.respond(_req(id), address(reqPeer), _out(_req(id), Performative.Inform));
        assertEq(uint8(self.requestStatus(id).phase), uint8(RequestPhase.None));
        assertEq(uint8(reqPeer.requestStatus(id).phase), uint8(RequestPhase.None));
    }

    function test_contractNetManager() public {
        bytes32 id = keccak256("comp-m");
        uint64 by = uint64(block.timestamp + 10);
        Message memory cfp = _cfp(id, by);
        self.cfp(_one(address(cnPeer)), cfp);
        cnPeer.respond(cfp, address(self), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        self.evaluate(id, _one(address(cnPeer)), _none(), _none());
        Message memory acc;
        acc.performative = uint8(Performative.AcceptProposal);
        acc.protocol = uint8(Protocol.FipaContractNet);
        acc.conversationId = id;
        cnPeer.respond(acc, address(self), _out(acc, Performative.Inform));
        assertEq(self.conversation(id).live, 0);
        assertEq(cnPeer.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_contractNetParticipant() public {
        bytes32 id = keccak256("comp-p");
        uint64 by = uint64(block.timestamp + 10);
        Message memory cfp = _cfp(id, by);
        otherManager.cfp(_one(address(self)), cfp);
        assertEq(self.session(id).phase, ContractNetLib.PART_CFPED);
        self.respond(cfp, address(otherManager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        otherManager.evaluate(id, _one(address(self)), _none(), _none());
        Message memory acc;
        acc.performative = uint8(Performative.AcceptProposal);
        acc.protocol = uint8(Protocol.FipaContractNet);
        acc.conversationId = id;
        self.respond(acc, address(otherManager), _out(acc, Performative.Inform));
        assertEq(self.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(otherManager.conversation(id).live, 0);
    }

    function test_requestAndContractNetConcurrent() public {
        bytes32 reqId = keccak256("live-req");
        bytes32 cnId = keccak256("live-cn");
        self.startRequest(address(reqPeer), _req(reqId));
        uint64 by = uint64(block.timestamp + 10);
        Message memory cfp = _cfp(cnId, by);
        self.cfp(_one(address(cnPeer)), cfp);
        assertEq(uint8(self.requestStatus(reqId).phase), uint8(RequestPhase.Requested));
        assertEq(self.conversation(cnId).live, 1);
        reqPeer.respond(_req(reqId), address(self), _out(_req(reqId), Performative.Refuse));
        assertEq(uint8(self.requestStatus(reqId).phase), uint8(RequestPhase.None));
        assertEq(self.conversation(cnId).live, 1);
        cnPeer.respond(cfp, address(self), _out(cfp, Performative.Refuse));
        assertEq(self.conversation(cnId).live, 0);
        assertEq(uint8(self.requestStatus(reqId).phase), uint8(RequestPhase.None));
    }

    function test_managerAndParticipantDifferentConversations() public {
        bytes32 asMgr = keccak256("as-mgr");
        bytes32 asPart = keccak256("as-part");
        uint64 by = uint64(block.timestamp + 10);
        Message memory cfpM = _cfp(asMgr, by);
        Message memory cfpP = _cfp(asPart, by);
        self.cfp(_one(address(cnPeer)), cfpM);
        otherManager.cfp(_one(address(self)), cfpP);
        cnPeer.respond(cfpM, address(self), _out(cfpM, Performative.Propose));
        self.respond(cfpP, address(otherManager), _out(cfpP, Performative.Propose));
        assertEq(self.slotOf(asMgr, address(cnPeer)), ContractNetLib.SLOT_PROPOSED);
        assertEq(self.session(asPart).phase, ContractNetLib.PART_PROPOSED);
        vm.warp(uint256(by) + 1);
        self.evaluate(asMgr, _one(address(cnPeer)), _none(), _none());
        otherManager.evaluate(asPart, _one(address(self)), _none(), _none());
        Message memory accM;
        accM.performative = uint8(Performative.AcceptProposal);
        accM.protocol = uint8(Protocol.FipaContractNet);
        accM.conversationId = asMgr;
        cnPeer.respond(accM, address(self), _out(accM, Performative.Inform));
        Message memory accP;
        accP.performative = uint8(Performative.AcceptProposal);
        accP.protocol = uint8(Protocol.FipaContractNet);
        accP.conversationId = asPart;
        self.respond(accP, address(otherManager), _out(accP, Performative.Inform));
        assertEq(self.conversation(asMgr).live, 0);
        assertEq(self.session(asPart).phase, ContractNetLib.PART_NONE);
    }

    /// @dev Request and CN use independent mappings; the same conversationId is supported across protocols.
    function test_sameConversationIdAcrossRequestAndContractNet() public {
        bytes32 id = keccak256("shared-cid");
        self.startRequest(address(reqPeer), _req(id));
        uint64 by = uint64(block.timestamp + 10);
        Message memory cfp = _cfp(id, by);
        self.cfp(_one(address(cnPeer)), cfp);
        assertEq(uint8(self.requestStatus(id).phase), uint8(RequestPhase.Requested));
        assertEq(self.conversation(id).live, 1);
        reqPeer.respond(_req(id), address(self), _out(_req(id), Performative.Inform));
        assertEq(uint8(self.requestStatus(id).phase), uint8(RequestPhase.None));
        assertEq(self.conversation(id).live, 1);
        cnPeer.respond(cfp, address(self), _out(cfp, Performative.Refuse));
        assertEq(self.conversation(id).live, 0);
    }

    function test_invalidRequestTransition() public {
        bytes32 id = keccak256("bad-req");
        self.startRequest(address(reqPeer), _req(id));
        Message memory agree = _out(_req(id), Performative.Agree);
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        self.respond(_req(id), address(reqPeer), agree);
    }

    function test_invalidManagerTransition() public {
        bytes32 id = keccak256("bad-mgr");
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        self.evaluate(id, _none(), _none(), _none());
    }

    function test_invalidParticipantTransition() public {
        bytes32 id = keccak256("bad-part");
        Message memory cfp = _cfp(id, uint64(block.timestamp + 10));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        self.respond(cfp, address(otherManager), _out(cfp, Performative.Propose));
    }

    function test_sameCnIdManagerThenParticipantCfpReverts() public {
        bytes32 id = keccak256("cn-overlap");
        uint64 by = uint64(block.timestamp + 10);
        self.cfp(_one(address(cnPeer)), _cfp(id, by));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        otherManager.cfp(_one(address(self)), _cfp(id, by));
        assertEq(self.conversation(id).live, 1);
        assertEq(self.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_sameCnIdParticipantThenManagerCfpReverts() public {
        bytes32 id = keccak256("cn-overlap-2");
        uint64 by = uint64(block.timestamp + 10);
        otherManager.cfp(_one(address(self)), _cfp(id, by));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        self.cfp(_one(address(cnPeer)), _cfp(id, by));
        assertEq(self.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(self.conversation(id).live, 0);
    }

    function test_malformedContractNetWithoutSessionReverts() public {
        Message memory propose;
        propose.performative = uint8(Performative.Propose);
        propose.protocol = uint8(Protocol.FipaContractNet);
        propose.conversationId = keccak256("orphan-cn");
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        IAgent(address(self)).handle(propose);
    }
}
