pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Agent} from "../../src/core/Agent.sol";
import {Message} from "../../src/core/Message.sol";

/// @dev Random handle attempts against a storage-free Agent (A-I1..I5).
contract AgentHandler is Test {
    Agent public native;
    Agent public withRelay;
    address public relay = address(0xBEEF);
    bytes internal constant NEEDLE =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    uint256 public nativeAcceptedWithLogical;
    uint256 public relayAcceptedAsNative;
    uint256 public protocolZeroIdAccepted;

    constructor() {
        native = new Agent(address(0));
        withRelay = new Agent(relay);
    }

    function handleNative(
        uint8 protocol,
        bytes32 conversationId,
        bytes32 logicalSender,
        uint8 contentLen
    ) external {
        Message memory m = _msg(protocol, conversationId, logicalSender, contentLen);
        address caller = address(uint160(uint256(keccak256(abi.encode(contentLen, protocol))) | 1));
        vm.prank(caller);
        try native.handle(m) {
            if (logicalSender != bytes32(0)) {
                nativeAcceptedWithLogical++;
            }
            if (protocol != 0 && conversationId == bytes32(0)) {
                protocolZeroIdAccepted++;
            }
        } catch {}
    }

    function handleWithRelay(
        bool asRelay,
        uint8 protocol,
        bytes32 conversationId,
        bytes32 logicalSender,
        uint8 contentLen
    ) external {
        Message memory m = _msg(protocol, conversationId, logicalSender, contentLen);
        address caller = asRelay
            ? relay
            : address(uint160(uint256(keccak256(abi.encode(asRelay, protocol))) | 1));
        vm.prank(caller);
        try withRelay.handle(m) {
            if (!asRelay && logicalSender != bytes32(0)) {
                nativeAcceptedWithLogical++;
            }
            if (asRelay && logicalSender == bytes32(0)) {
                relayAcceptedAsNative++;
            }
            if (protocol != 0 && conversationId == bytes32(0)) {
                protocolZeroIdAccepted++;
            }
        } catch {}
    }

    function assertAgentInvariants() external view {
        assertEq(nativeAcceptedWithLogical, 0, "A-I1/I3");
        assertEq(relayAcceptedAsNative, 0, "A-I2");
        assertEq(protocolZeroIdAccepted, 0, "A-I4");
        _noNeedle(address(native));
        _noNeedle(address(withRelay));
    }

    function _msg(uint8 protocol, bytes32 conversationId, bytes32 logicalSender, uint8 contentLen)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = 0;
        m.protocol = protocol;
        m.conversationId = conversationId;
        m.logicalSender = logicalSender;
        uint256 n = uint256(contentLen) % 65;
        m.content = new bytes(n);
        if (n >= 32) {
            bytes32 needle = bytes32(NEEDLE);
            for (uint256 i = 0; i < 32; i++) {
                m.content[i] = needle[i];
            }
        }
    }

    function _noNeedle(address target) internal view {
        bytes32 n = bytes32(NEEDLE);
        for (uint256 i = 0; i < 16; i++) {
            assertTrue(vm.load(target, bytes32(i)) != n, "A-I5");
        }
    }
}
