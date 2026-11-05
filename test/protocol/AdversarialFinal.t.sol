// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NetFixture} from "./Fixtures.sol";
import {SubscriptionActor} from "./Subscribe.t.sol";
import {SubscribeAgent, SubscribePhase} from "../../src/core/SubscribeAgent.sol";
import {ExposedContractNetManager} from "../ContractNetActors.sol";
import {Agent} from "../../src/core/Agent.sol";
import {QueuedContractNetManager} from "../../experiments/QueuedContractNetManager.sol";
import {ExposedContractNetParticipant, RevertOnCfpParticipant} from "../ContractNetActors.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";

contract AutoSubscription is SubscribeAgent {
    bool public immutable provider;
    bool public failAfter;

    constructor(bool p) Agent(address(0)) {
        provider = p;
    }

    function start(address peer, bytes32 id) external {
        _startSubscribe(peer, id, "");
    }

    function setFail(bool fail) external {
        failAfter = fail;
    }

    function _onReceive(Message calldata m) internal override {
        if (provider && m.performative == uint8(Performative.Subscribe)) {
            _subscriptionAct(m.conversationId, Performative.Inform, ""); // implicit agreement
        } else if (
            !provider && m.performative == uint8(Performative.Inform)
                && _subscriptions[m.conversationId].phase == SubscribePhase.Active
        ) {
            _subscriptionAct(m.conversationId, Performative.Cancel, "");
        } else if (provider && m.performative == uint8(Performative.Cancel)) {
            _subscriptionAct(m.conversationId, Performative.Inform, "");
        }
        require(!failAfter, "callback failure");
    }
}

contract CompletingQueuedPeer is ExposedContractNetParticipant {
    bool public duplicateSucceeded;
    constructor() ExposedContractNetParticipant(address(0)) {}

    function _onReceive(Message calldata m) internal override {
        if (m.performative == uint8(Performative.AcceptProposal)) {
            (duplicateSucceeded,) = msg.sender
                .call(
                    abi.encodeCall(
                        QueuedContractNetManager.deliver, (m.conversationId, address(this))
                    )
                );
            Message memory out;
            out.protocol = m.protocol;
            out.conversationId = m.conversationId;
            out.performative = uint8(Performative.Inform);
            _reply(m, msg.sender, out);
        }
    }
}

contract RelayedSubscriptionProbe is SubscribeAgent {
    constructor(address relay) Agent(relay) {}
}

contract AdversarialFinalTest is NetFixture {
    bytes32 constant ID = bytes32(uint256(31));

    function test_nestedSubscribeNotifyCancelAndAcknowledgement() public {
        AutoSubscription a = new AutoSubscription(false);
        AutoSubscription b = new AutoSubscription(true);
        a.start(address(b), ID);
        assertEq(uint8(a.subscription(ID).phase), uint8(SubscribePhase.None));
        assertEq(uint8(b.subscription(ID).phase), uint8(SubscribePhase.None));
    }

    function test_nestedSubscribeCallbackFailureRollsBackAll() public {
        AutoSubscription a = new AutoSubscription(false);
        AutoSubscription b = new AutoSubscription(true);
        b.setFail(true);
        vm.expectRevert(bytes("callback failure"));
        a.start(address(b), ID);
        assertEq(uint8(a.subscription(ID).phase), uint8(SubscribePhase.None));
        assertEq(uint8(b.subscription(ID).phase), uint8(SubscribePhase.None));
        b.setFail(false);
        a.start(address(b), ID);
    }

    function testFuzz_cancelRetryRejectsEarlierAcknowledgement(bool initialAgreement) public {
        SubscriptionActor a = new SubscriptionActor();
        SubscriptionActor b = new SubscriptionActor();
        a.start(address(b), ID);
        if (initialAgreement) b.act(ID, Performative.Agree);
        a.act(ID, Performative.Cancel);
        bytes32 old = a.subscription(ID).cancelToken;
        b.act(ID, Performative.Failure);
        a.act(ID, Performative.Cancel);
        assertNotEq(old, a.subscription(ID).cancelToken);
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Inform);
        m.conversationId = ID;
        m.inReplyTo = old;
        vm.prank(address(b));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        a.handle(m);
        b.act(ID, Performative.Inform);
        assertEq(uint8(a.subscription(ID).phase), uint8(SubscribePhase.None));
    }

    function test_queuedDeliveryReentrancyCannotDuplicateAndCanComplete() public {
        QueuedContractNetManager q = new QueuedContractNetManager();
        CompletingQueuedPeer peer = new CompletingQueuedPeer();
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        q.cfp(_one(address(peer)), m);
        peer.respond(m, address(q), _out(m, Performative.Propose));
        vm.warp(block.timestamp + 101);
        q.evaluate(ID, _one(address(peer)), _empty(), _empty());
        q.deliver(ID, address(peer));
        assertFalse(peer.duplicateSucceeded());
        assertEq(q.pendingCount(ID), 0);
        assertEq(q.conversation(ID).live, 0);
    }

    function testFuzz_queuedRejectDeliveryOrderAndCleanup(bool reverse) public {
        QueuedContractNetManager q = new QueuedContractNetManager();
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        q.cfp(_two(address(p1), address(p2)), m);
        p1.respond(m, address(q), _out(m, Performative.Propose));
        p2.respond(m, address(q), _out(m, Performative.Propose));
        vm.warp(block.timestamp + 101);
        q.evaluate(ID, _empty(), _two(address(p1), address(p2)), _empty());
        assertEq(q.conversation(ID).live, 0);
        vm.expectRevert(bytes("pending decisions"));
        q.cfp(_one(address(p1)), m);
        q.deliver(ID, reverse ? address(p1) : address(p2));
        assertEq(q.pendingCount(ID), 1);
        q.deliver(ID, reverse ? address(p2) : address(p1));
        assertEq(q.pendingCount(ID), 0);
        assertEq(p1.session(ID).phase, 0);
        assertEq(p2.session(ID).phase, 0);
        m.replyBy = uint64(block.timestamp + 100);
        q.cfp(_one(address(p1)), m);
    }

    function test_queueStillCannotRecoverFromCfpRevert() public {
        QueuedContractNetManager q = new QueuedContractNetManager();
        RevertOnCfpParticipant bad = new RevertOnCfpParticipant();
        vm.expectRevert(bytes("cfp-handle-revert"));
        q.cfp(_two(address(p1), address(bad)), _cfp(ID, uint64(block.timestamp + 100)));
        assertEq(q.conversation(ID).live, 0);
        assertEq(p1.session(ID).phase, 0);
        assertEq(q.pendingCount(ID), 0);
    }

    function testFuzz_queueOwnerAuthorization(address caller) public {
        vm.assume(caller != address(this));
        QueuedContractNetManager q = new QueuedContractNetManager();
        vm.prank(caller);
        vm.expectRevert(bytes("owner"));
        q.cfp(_one(address(p1)), _cfp(ID, uint64(block.timestamp + 100)));
        vm.prank(caller);
        vm.expectRevert(bytes("owner"));
        q.evaluate(ID, _empty(), _empty(), _empty());
        assertEq(q.conversation(ID).live, 0);
    }

    function testFuzz_invalidCancelEnvelopePreservesState(bytes32 wrong) public {
        SubscriptionActor a = new SubscriptionActor();
        SubscriptionActor b = new SubscriptionActor();
        a.start(address(b), ID);
        b.act(ID, Performative.Agree);
        bytes32 token = a.subscription(ID).token;
        vm.assume(wrong != token);
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Cancel);
        m.conversationId = ID;
        m.replyWith = bytes32(uint256(123));
        m.inReplyTo = wrong;
        vm.prank(address(a));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        b.handle(m);
        m.inReplyTo = token;
        m.replyWith = bytes32(0);
        vm.prank(address(a));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        b.handle(m);
        m.replyWith = token;
        vm.prank(address(a));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        b.handle(m);
        assertEq(uint8(b.subscription(ID).phase), uint8(SubscribePhase.Active));
        assertEq(b.subscription(ID).cancelToken, bytes32(0));
    }

    function test_subscribeRelayAndUnsolicitedNotificationRejected() public {
        address relay = address(0xbeef);
        RelayedSubscriptionProbe p = new RelayedSubscriptionProbe(relay);
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Subscribe);
        m.conversationId = ID;
        m.replyWith = bytes32(uint256(1));
        m.logicalSender = bytes32(uint256(2));
        vm.prank(relay);
        vm.expectRevert(SubscribeAgent.SubscriptionPeer.selector);
        p.handle(m);
        m.logicalSender = bytes32(0);
        m.performative = uint8(Performative.Inform);
        vm.expectRevert(SubscribeAgent.InvalidSubscription.selector);
        p.handle(m);
        assertEq(uint8(p.subscription(ID).phase), uint8(SubscribePhase.None));
    }

    function test_contractNetManagerRejectsLogicalContinuation() public {
        address relay = address(0xbeef);
        ExposedContractNetManager gated = new ExposedContractNetManager(relay);
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        gated.cfp(_one(address(p1)), m);
        m = _out(m, Performative.Propose);
        m.logicalSender = bytes32(uint256(1));
        vm.prank(relay);
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        gated.handle(m);
        assertEq(gated.slotOf(ID, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_contractNetRejectDecisionBeforeProposal() public {
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        manager.cfp(_one(address(p1)), m);
        m = _out(m, Performative.RejectProposal);
        vm.prank(address(manager));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.handle(m);
        assertEq(p1.session(ID).phase, ContractNetLib.PART_CFPED);
    }

    /// @dev Residual design limit, not an anti-replay claim: CN has no session nonce.
    function test_contractNetSamePeerStaleTokenNotEnforcedOnReusedId() public {
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        manager.cfp(_one(address(p1)), m);
        p1.respond(m, address(manager), _out(m, Performative.Refuse));
        m.replyBy = uint64(block.timestamp + 200);
        m.replyWith = bytes32(uint256(77));
        manager.cfp(_one(address(p1)), m);
        Message memory stale = _out(m, Performative.Propose);
        stale.inReplyTo = bytes32(uint256(88));
        vm.prank(address(p1));
        manager.handle(stale);
        assertEq(manager.slotOf(ID, address(p1)), ContractNetLib.SLOT_PROPOSED);
    }
}
