pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Agent} from "../src/core/Agent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

/// @dev Replies without extra storage (unlike EchoAgent's `lastPeer`).
contract ReplyOnlyAgent is Agent {
    constructor() Agent(address(0)) {}

    function _onReceive(Message calldata inbound) internal override {
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

contract AgentStorageTest is Test {
    bytes internal constant UNIQUE_CONTENT =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    Agent internal agent;
    ReplyOnlyAgent internal alice;
    ReplyOnlyAgent internal bob;

    function setUp() public {
        agent = new Agent(address(0));
        alice = new ReplyOnlyAgent();
        bob = new ReplyOnlyAgent();
    }

    function _nativeRequest() internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = keccak256("ta3-conv");
        m.replyWith = keccak256("ta3-rw");
        m.content = UNIQUE_CONTENT;
    }

    function _assertNoStorageWrites(address target) internal view {
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0, "Agent must not SSTORE Message/content");
    }

    function _assertContentAbsentFromSlots(address target) internal view {
        bytes32 needle = bytes32(UNIQUE_CONTENT);
        for (uint256 i = 0; i < 64; i++) {
            assertTrue(vm.load(target, bytes32(i)) != needle);
        }
    }

    function test_handleDoesNotPersistContent() public {
        vm.record();
        agent.handle(_nativeRequest());
        _assertNoStorageWrites(address(agent));
        _assertContentAbsentFromSlots(address(agent));
    }

    function test_handleAndReplyDoesNotPersistContent() public {
        vm.record();
        vm.prank(address(alice));
        bob.handle(_nativeRequest());
        _assertNoStorageWrites(address(alice));
        _assertNoStorageWrites(address(bob));
        _assertContentAbsentFromSlots(address(alice));
        _assertContentAbsentFromSlots(address(bob));
    }

    function test_snapshot_handle() public {
        agent.handle(_nativeRequest());
    }

    function test_snapshot_handleAndReply() public {
        vm.prank(address(alice));
        bob.handle(_nativeRequest());
    }
}
