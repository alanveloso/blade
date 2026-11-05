// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NetFixture} from "./Fixtures.sol";
import {SubscriptionActor} from "./Subscribe.t.sol";
import {SubscribeAgent, SubscribePhase} from "../../src/core/SubscribeAgent.sol";
import {QueuedContractNetManager} from "../../experiments/QueuedContractNetManager.sol";
import {ExposedContractNetParticipant} from "../ContractNetActors.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";

contract FinalRegressionTest is NetFixture {
    bytes32 constant ID = bytes32(uint256(17));

    function test_cancelDoesNotAcceptOldNotificationAsAcknowledgement() public {
        SubscriptionActor a = new SubscriptionActor();
        SubscriptionActor b = new SubscriptionActor();
        a.start(address(b), ID);
        b.act(ID, Performative.Agree);
        bytes32 token = a.subscription(ID).token;
        a.act(ID, Performative.Cancel);
        Message memory old;
        old.protocol = uint8(Protocol.FipaSubscribe);
        old.performative = uint8(Performative.Inform);
        old.conversationId = ID;
        old.inReplyTo = token;
        vm.prank(address(b));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        a.handle(old);
        assertEq(uint8(a.subscription(ID).phase), uint8(SubscribePhase.Cancelling));
        b.act(ID, Performative.Inform);
        assertEq(uint8(a.subscription(ID).phase), uint8(SubscribePhase.None));
    }

    function test_contractNetRejectsLogicalOpeningBeforeStateChange() public {
        address relay = address(0xbeef);
        ExposedContractNetParticipant p = new ExposedContractNetParticipant(relay);
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        m.logicalSender = bytes32(uint256(1));
        vm.prank(relay);
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        p.handle(m);
        assertEq(p.session(ID).phase, ContractNetLib.PART_NONE);
    }

    function queued() internal returns (QueuedContractNetManager q, Message memory m) {
        q = new QueuedContractNetManager();
        m = _cfp(ID, uint64(block.timestamp + 100));
        q.cfp(_one(address(p1)), m);
        p1.respond(m, address(q), _out(m, Performative.Propose));
        vm.warp(block.timestamp + 101);
        q.evaluate(ID, _one(address(p1)), _empty(), _empty());
    }

    function test_withdrawalBeforeDeliveryClearsObsoleteDecision() public {
        (QueuedContractNetManager q, Message memory m) = queued();
        p1.respond(m, address(q), _out(m, Performative.NotUnderstood));
        assertEq(q.pendingCount(ID), 0);
        assertEq(q.pending(ID, address(p1)), 0);
        assertEq(q.conversation(ID).live, 0);
        m.replyBy = uint64(block.timestamp + 100);
        q.cfp(_one(address(p1)), m);
        assertEq(q.conversation(ID).live, 1);
    }

    function test_completionBeforeDecisionDeliveryRejected() public {
        (QueuedContractNetManager q, Message memory m) = queued();
        vm.prank(address(p1));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        q.handle(_out(m, Performative.Inform));
        assertEq(q.pendingCount(ID), 1);
        assertEq(q.conversation(ID).live, 1);
    }
}
