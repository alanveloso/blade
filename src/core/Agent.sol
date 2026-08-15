// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgent} from "./IAgent.sol";
import {Message, MessageLib} from "./Message.sol";

/// @title Generic on-chain agent.
/// @dev Transport sender is `msg.sender`; receiver is `address(this)`. Does not store `Message`/`content`.
contract Agent is IAgent {
    using MessageLib for Message;

    address public immutable trustedAcc;

    error AccMustSetLogicalSender();
    error UnauthorizedLogicalSender();
    error OnlySelf();
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

    constructor(address trustedAcc_) {
        trustedAcc = trustedAcc_;
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

    /// @dev Only this contract may send (via `this.reply`), so `msg.sender` at the peer is this Agent.
    function reply(address to, Message memory message) public {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
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
        this.reply(to, outbound);
    }

    function _authenticate(Message calldata message) internal view {
        if (trustedAcc != address(0) && msg.sender == trustedAcc) {
            if (message.logicalSender == bytes32(0)) {
                revert AccMustSetLogicalSender();
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
