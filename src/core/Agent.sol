// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgent} from "./IAgent.sol";
import {Message, MessageLib} from "./Message.sol";

/// @title Generic on-chain agent.
/// @dev Transport sender is `msg.sender`; receiver is `address(this)`. Does not store `Message`/`content`.
contract Agent is IAgent {
    using MessageLib for Message;

    address public immutable trustedRelay;

    error RelayMustSetLogicalSender();
    error UnauthorizedLogicalSender();
    error ConversationMismatch();
    error ReplyWithMismatch();

    event Received(
        address indexed transportCaller,
        bytes32 indexed conversationId,
        bytes32 logicalSender,
        uint8 performative,
        uint8 protocol,
        bytes32 replyWith,
        bytes32 inReplyTo,
        uint64 replyBy,
        bytes content
    );

    constructor(address trustedRelay_) {
        trustedRelay = trustedRelay_;
    }

    /// @dev Named `handle` because Solidity reserves `receive` for the ETH receive function.
    function handle(Message calldata message) external {
        message.validate();
        _authenticate(message);
        _onInbound(message);
        emit Received(
            msg.sender,
            message.conversationId,
            message.logicalSender,
            message.performative,
            message.protocol,
            message.replyWith,
            message.inReplyTo,
            message.replyBy,
            message.content
        );
        _onReceive(message);
    }

    /// @dev Native outbound: `logicalSender` must be 0. Peer sees `msg.sender == address(this)`.
    function _send(address to, Message memory message) internal virtual {
        if (message.logicalSender != bytes32(0)) {
            revert UnauthorizedLogicalSender();
        }
        message.validate();
        IAgent(to).handle(message);
    }

    /// @dev Reply must keep the inbound conversation key; `inReplyTo` mirrors `replyWith` when set.
    function _reply(Message calldata inbound, address to, Message memory outbound)
        internal
        virtual
    {
        if (inbound.conversationId != outbound.conversationId) {
            revert ConversationMismatch();
        }
        if (inbound.replyWith != bytes32(0) && outbound.inReplyTo != inbound.replyWith) {
            revert ReplyWithMismatch();
        }
        _send(to, outbound);
    }

    function _authenticate(Message calldata message) internal view {
        if (trustedRelay != address(0) && msg.sender == trustedRelay) {
            if (message.logicalSender == bytes32(0)) {
                revert RelayMustSetLogicalSender();
            }
            return;
        }
        if (message.logicalSender != bytes32(0)) {
            revert UnauthorizedLogicalSender();
        }
    }

    function _onInbound(Message calldata message) internal virtual {}

    function _onReceive(Message calldata message) internal virtual {}
}
