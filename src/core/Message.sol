// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

/// @title Compact on-chain ACL.
/// @dev No `from`/`to`: caller is `msg.sender`, receiver is `address(this)`.
/// @dev `bytes32` keys are opaque identifiers, not invertible FIPA text.
struct Message {
    uint8 performative;
    uint8 protocol;
    bytes32 conversationId;
    bytes32 replyWith;
    bytes32 inReplyTo;
    uint64 replyBy;
    bytes32 logicalSender;
    bytes content;
}

library MessageLib {
    error ProtocolRequiresConversationId();

    function validate(Message memory m) internal pure {
        if (m.protocol != uint8(Protocol.None) && m.conversationId == bytes32(0)) {
            revert ProtocolRequiresConversationId();
        }
    }

    function performativeOf(Message memory m) internal pure returns (Performative) {
        return Performative(m.performative);
    }

    function protocolOf(Message memory m) internal pure returns (Protocol) {
        return Protocol(m.protocol);
    }

    /// @dev `logicalSender == 0` means native (identity = transport). Non-zero is set only by the trusted caller.
    function isNative(Message memory m) internal pure returns (bool) {
        return m.logicalSender == bytes32(0);
    }
}
