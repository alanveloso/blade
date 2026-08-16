pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Message, MessageLib} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

contract MessageTest is Test {
    using MessageLib for Message;

    function _base() internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.None);
        m.content = hex"0102";
    }

    function test_validate_protocolRequiresConversationId() public {
        Message memory m = _base();
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = bytes32(0);
        vm.expectRevert(MessageLib.ProtocolRequiresConversationId.selector);
        this.externalValidate(m);
    }

    function externalValidate(Message memory m) external pure {
        m.validate();
    }

    function test_validate_protocolWithConversationIdOk() public pure {
        Message memory m = _base();
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = keccak256("opaque-key");
        m.validate();
        assertEq(uint256(m.protocolOf()), uint256(Protocol.FipaRequest));
    }

    function test_nativeLogicalSenderIsZero() public pure {
        Message memory m = _base();
        assertTrue(m.isNative());
        m.validate();
    }

    function test_relayReservedLogicalSenderIsNonZeroOpaque() public pure {
        Message memory m = _base();
        m.logicalSender = keccak256("not-an-address-not-a-fipa-name");
        assertFalse(m.isNative());
        m.validate();
    }

    function test_contentIsOpaqueBytesRoundTrip() public pure {
        Message memory m = _base();
        m.content = bytes("not FIPA00070 parsing");
        m.validate();
        assertEq(m.content, bytes("not FIPA00070 parsing"));
    }

    function test_omittedReplyFieldsAreZero() public pure {
        Message memory m = _base();
        assertEq(m.replyWith, bytes32(0));
        assertEq(m.inReplyTo, bytes32(0));
        assertEq(m.replyBy, uint64(0));
        m.validate();
    }

    function test_noFromToInAbiEncoding() public pure {
        Message memory m = _base();
        m.conversationId = bytes32(uint256(1));
        bytes memory encoded = abi.encode(m);
        assertTrue(encoded.length > 0);
        assertEq(uint256(m.performativeOf()), uint256(Performative.Request));
    }

    function testFuzz_protocolRequiresConversationId(uint8 protocol) public {
        vm.assume(protocol != 0);
        Message memory m = _base();
        m.protocol = protocol;
        m.conversationId = bytes32(0);
        vm.expectRevert(MessageLib.ProtocolRequiresConversationId.selector);
        this.externalValidate(m);
    }
}
