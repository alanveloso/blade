// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {Agent} from "../../src/core/Agent.sol";
import {SubscribeAgent, SubscribePhase} from "../../src/core/SubscribeAgent.sol";
import {Message} from "../../src/core/Message.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {Performative} from "../../src/core/Performative.sol";

contract SubscriptionActor is SubscribeAgent {
    bool public rejectDelivery;
    constructor() Agent(address(0)) {}

    function start(address peer, bytes32 id) external {
        _startSubscribe(peer, id, "");
    }

    function act(bytes32 id, Performative a) external {
        _subscriptionAct(id, a, "");
    }

    function reject(bool value) external {
        rejectDelivery = value;
    }

    function _onReceive(Message calldata) internal view override {
        require(!rejectDelivery, "delivery");
    }
}

contract SubscribeTest is Test {
    SubscriptionActor a;
    SubscriptionActor b;
    bytes32 constant ID = bytes32(uint256(1));

    function setUp() public {
        a = new SubscriptionActor();
        b = new SubscriptionActor();
    }

    function open(bytes32 id) internal {
        a.start(address(b), id);
        b.act(id, Performative.Agree);
    }

    function phase(bytes32 id, SubscribePhase p) internal view {
        assertEq(uint8(a.subscription(id).phase), uint8(p));
        assertEq(uint8(b.subscription(id).phase), uint8(p));
    }

    function testFuzz_notificationsAndCancel(uint8 count) public {
        open(ID);
        for (uint256 i; i < uint256(count) % 32; ++i) {
            b.act(ID, Performative.Inform);
        }
        phase(ID, SubscribePhase.Active);
        a.act(ID, Performative.Cancel);
        phase(ID, SubscribePhase.Cancelling);
        b.act(ID, Performative.Inform);
        phase(ID, SubscribePhase.None);
        vm.expectRevert(SubscribeAgent.InvalidSubscription.selector);
        b.act(ID, Performative.Inform);
    }

    function test_refuseFailureAndNotUnderstood() public {
        a.start(address(b), ID);
        b.act(ID, Performative.Refuse);
        phase(ID, SubscribePhase.None);
        open(ID);
        b.act(ID, Performative.Failure);
        phase(ID, SubscribePhase.None);
        open(ID);
        a.act(ID, Performative.NotUnderstood);
        phase(ID, SubscribePhase.None);
    }

    function test_cancelFailureResumes() public {
        open(ID);
        a.act(ID, Performative.Cancel);
        b.act(ID, Performative.Failure);
        phase(ID, SubscribePhase.Active);
        b.act(ID, Performative.Inform);
    }

    function testFuzz_sessionIsolation(bool reverse) public {
        bytes32 other = bytes32(uint256(2));
        open(ID);
        open(other);
        bytes32 first = reverse ? ID : other;
        bytes32 second = reverse ? other : ID;
        a.act(first, Performative.Cancel);
        b.act(second, Performative.Inform);
        b.act(first, Performative.Inform);
        phase(first, SubscribePhase.None);
        phase(second, SubscribePhase.Active);
    }

    function test_invalidTransitionsAndRollback() public {
        a.start(address(b), ID);
        vm.expectRevert(SubscribeAgent.InvalidSubscription.selector);
        b.act(ID, Performative.Propose);
        phase(ID, SubscribePhase.Pending);
        b.act(ID, Performative.Agree);
        vm.expectRevert(SubscribeAgent.InvalidSubscription.selector);
        a.act(ID, Performative.Inform);
        a.reject(true);
        vm.expectRevert(bytes("delivery"));
        b.act(ID, Performative.Failure);
        phase(ID, SubscribePhase.Active);
        a.reject(false);
        b.reject(true);
        vm.expectRevert(bytes("delivery"));
        a.act(ID, Performative.Cancel);
        phase(ID, SubscribePhase.Active);
    }

    function testFuzz_wrongPeerAndToken(address stranger, bytes32 token) public {
        vm.assume(stranger != address(b));
        open(ID);
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Inform);
        m.conversationId = ID;
        m.inReplyTo = a.subscription(ID).token;
        vm.prank(stranger);
        vm.expectRevert(SubscribeAgent.SubscriptionPeer.selector);
        a.handle(m);
        vm.assume(token != m.inReplyTo);
        m.inReplyTo = token;
        vm.prank(address(b));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        a.handle(m);
        phase(ID, SubscribePhase.Active);
    }

    function test_reuseRejectsStaleNotification() public {
        open(ID);
        bytes32 old = a.subscription(ID).token;
        b.act(ID, Performative.Failure);
        open(ID);
        assertNotEq(old, a.subscription(ID).token);
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Inform);
        m.conversationId = ID;
        m.inReplyTo = old;
        vm.prank(address(b));
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        a.handle(m);
        phase(ID, SubscribePhase.Active);
    }

    function test_duplicateOpenRejectedAndOpeningCancellationAllowed() public {
        a.start(address(b), ID);
        vm.expectRevert(SubscribeAgent.InvalidSubscription.selector);
        a.start(address(b), ID);
        a.act(ID, Performative.Cancel);
        phase(ID, SubscribePhase.Cancelling);
        b.act(ID, Performative.Failure);
        phase(ID, SubscribePhase.Pending);
        b.act(ID, Performative.Inform);
        phase(ID, SubscribePhase.Active);
    }

    function test_missingTokenAndForgedLogicalIdentityRejected() public {
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Subscribe);
        m.conversationId = ID;
        vm.expectRevert(SubscribeAgent.SubscriptionToken.selector);
        b.handle(m);
        m.replyWith = bytes32(uint256(7));
        m.logicalSender = bytes32(uint256(9));
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        b.handle(m);
        phase(ID, SubscribePhase.None);
    }

    function test_notificationCancelRaceHasExplicitMeaning() public {
        open(ID);
        uint256 snapshot = vm.snapshotState();
        b.act(ID, Performative.Inform);
        phase(ID, SubscribePhase.Active);
        a.act(ID, Performative.Cancel);
        phase(ID, SubscribePhase.Cancelling);
        assertTrue(vm.revertToState(snapshot));
        a.act(ID, Performative.Cancel);
        b.act(ID, Performative.Inform);
        phase(ID, SubscribePhase.None); // Inform now means cancel-done, not a notification.
    }

    function test_openFailureRollsBackBothEndpoints() public {
        b.reject(true);
        vm.expectRevert(bytes("delivery"));
        a.start(address(b), ID);
        phase(ID, SubscribePhase.None);
    }
}
