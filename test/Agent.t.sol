pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Agent} from "../src/core/Agent.sol";
import {Message, MessageLib} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

contract EchoAgent is Agent {
    address public lastPeer;

    constructor(address trustedRelay_) Agent(trustedRelay_) {}

    function _onReceive(Message calldata inbound) internal override {
        lastPeer = msg.sender;
        if (
            inbound.performative == uint8(Performative.Request)
                && inbound.logicalSender == bytes32(0)
        ) {
            Message memory outbound;
            outbound.performative = uint8(Performative.Inform);
            outbound.protocol = inbound.protocol;
            outbound.conversationId = inbound.conversationId;
            outbound.inReplyTo = inbound.replyWith;
            outbound.content = hex"aa";
            _reply(inbound, msg.sender, outbound);
        }
    }
}

contract AgentTest is Test {
    EchoAgent internal alice;
    EchoAgent internal bob;
    address internal relay = address(0x11EE);

    function setUp() public {
        alice = new EchoAgent(relay);
        bob = new EchoAgent(relay);
    }

    function _nativeRequest(bytes32 conv) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = conv;
        m.replyWith = keccak256("rw");
        m.content = hex"01";
    }

    function test_nativeAgentToAgentReceiveAndReply() public {
        Message memory req = _nativeRequest(keccak256("c1"));
        vm.prank(address(alice));
        bob.handle(req);
        assertEq(bob.lastPeer(), address(alice));
        assertEq(alice.lastPeer(), address(bob));
    }

    function test_receivedEventHasTransportCallerNotFromTo() public {
        Message memory req = _nativeRequest(keccak256("c2"));
        vm.expectEmit(true, true, false, true, address(bob));
        emit Agent.Received(
            address(alice),
            req.conversationId,
            bytes32(0),
            req.performative,
            req.protocol,
            req.replyWith,
            req.inReplyTo,
            req.replyBy,
            req.content
        );
        vm.prank(address(alice));
        bob.handle(req);
    }

    function test_untrustedCannotSetLogicalSender() public {
        Message memory req = _nativeRequest(keccak256("c3"));
        req.logicalSender = keccak256("alice-logical");
        vm.prank(address(alice));
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        bob.handle(req);
    }

    function test_relayMustSetLogicalSender() public {
        Message memory req = _nativeRequest(keccak256("c4"));
        vm.prank(relay);
        vm.expectRevert(Agent.RelayMustSetLogicalSender.selector);
        bob.handle(req);
    }

    function test_relayWithOpaqueLogicalSender() public {
        Message memory req = _nativeRequest(keccak256("c5"));
        req.logicalSender = keccak256("alice-logical");
        vm.prank(relay);
        bob.handle(req);
        assertEq(bob.lastPeer(), relay);
    }

    function test_replySelectorAbsent() public {
        Message memory req = _nativeRequest(keccak256("c6"));
        (bool ok,) = address(bob)
            .call(
                abi.encodeWithSignature(
                    "reply(address,(uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes))",
                    address(alice),
                    req
                )
            );
        assertFalse(ok);
    }

    function test_replyConversationMismatchReverts() public {
        MismatchAgent m = new MismatchAgent(address(0));
        Message memory req = _nativeRequest(keccak256("c7"));
        vm.prank(address(alice));
        vm.expectRevert(Agent.ConversationMismatch.selector);
        m.handle(req);
    }

    function test_replyWithMismatchReverts() public {
        ReplyWithMismatchAgent m = new ReplyWithMismatchAgent(address(0));
        Message memory req = _nativeRequest(keccak256("c8"));
        vm.prank(address(alice));
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        m.handle(req);
    }

    function test_trustedRelayZeroRejectsLogicalSender() public {
        EchoAgent nativeOnly = new EchoAgent(address(0));
        Message memory req = _nativeRequest(keccak256("c9"));
        req.logicalSender = keccak256("spoof");
        vm.prank(address(alice));
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        nativeOnly.handle(req);
    }

    function test_emptyContentDelivered() public {
        Message memory req = _nativeRequest(keccak256("c10"));
        req.content = "";
        vm.prank(address(alice));
        bob.handle(req);
        assertEq(bob.lastPeer(), address(alice));
    }

    function test_unsupportedProtocolOnBareAgentIsDelivered() public {
        RecordingAgent rec = new RecordingAgent(address(0));
        Message memory m;
        m.performative = uint8(Performative.Inform);
        m.protocol = 99;
        m.conversationId = keccak256("a9");
        m.content = hex"11";
        vm.prank(address(alice));
        rec.handle(m);
        assertEq(rec.lastProtocol(), 99);
        assertEq(rec.lastPerformative(), uint8(Performative.Inform));
    }

    function test_outOfEnumPerformativeOnBareAgentIsDelivered() public {
        RecordingAgent rec = new RecordingAgent(address(0));
        Message memory m;
        m.performative = 255;
        m.protocol = uint8(Protocol.None);
        vm.prank(address(alice));
        rec.handle(m);
        assertEq(rec.lastPerformative(), 255);
    }

    function test_largeContentIsNotStoredOnBareAgent() public {
        Agent bare = new Agent(address(0));
        Message memory m;
        m.performative = uint8(Performative.Inform);
        m.protocol = uint8(Protocol.None);
        m.content = new bytes(512);
        for (uint256 i = 0; i < 512; i++) {
            m.content[i] = bytes1(uint8(0xA5));
        }
        vm.record();
        vm.prank(address(alice));
        bare.handle(m);
        (, bytes32[] memory writes) = vm.accesses(address(bare));
        assertEq(writes.length, 0);
    }

    function testFuzz_untrustedCannotSetLogicalSender(bytes32 logicalSender) public {
        vm.assume(logicalSender != bytes32(0));
        Message memory req = _nativeRequest(keccak256("fuzz-ls"));
        req.logicalSender = logicalSender;
        vm.prank(address(alice));
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        bob.handle(req);
    }
}

contract MismatchAgent is Agent {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}

    function _onReceive(Message calldata inbound) internal override {
        Message memory outbound;
        outbound.performative = uint8(Performative.Inform);
        outbound.protocol = inbound.protocol;
        outbound.conversationId = keccak256("other");
        _reply(inbound, msg.sender, outbound);
    }
}

contract RecordingAgent is Agent {
    uint8 public lastProtocol;
    uint8 public lastPerformative;

    constructor(address trustedRelay_) Agent(trustedRelay_) {}

    function _onReceive(Message calldata inbound) internal override {
        lastProtocol = inbound.protocol;
        lastPerformative = inbound.performative;
    }
}

contract ReplyWithMismatchAgent is Agent {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}

    function _onReceive(Message calldata inbound) internal override {
        Message memory outbound;
        outbound.performative = uint8(Performative.Inform);
        outbound.protocol = inbound.protocol;
        outbound.conversationId = inbound.conversationId;
        outbound.inReplyTo = bytes32(uint256(1));
        _reply(inbound, msg.sender, outbound);
    }
}
