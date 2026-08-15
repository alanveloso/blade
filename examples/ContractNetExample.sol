// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {ContractNetParticipant} from "../src/core/ContractNetParticipant.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

/// @dev Application wrapper around `_cfp` / `_evaluate`. Selection policy lives here, not in Core.
contract ExampleManager is ContractNetManager {
    constructor(address trustedRelay_) ContractNetManager(trustedRelay_) {}

    function cfp(address[] calldata participants, bytes32 conversationId, uint64 replyBy) external {
        Message memory message;
        message.performative = uint8(Performative.Cfp);
        message.protocol = uint8(Protocol.FipaContractNet);
        message.conversationId = conversationId;
        message.replyBy = replyBy;
        _cfp(participants, message);
    }

    function evaluate(
        bytes32 conversationId,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external {
        _evaluate(conversationId, accept, reject, silent);
    }
}

/// @dev Application wrapper around `_respond`. Whether to propose is an application decision.
contract ExampleParticipant is ContractNetParticipant {
    constructor(address trustedRelay_) ContractNetParticipant(trustedRelay_) {}

    function propose(Message calldata inbound, address manager) external {
        Message memory outbound;
        outbound.performative = uint8(Performative.Propose);
        outbound.protocol = inbound.protocol;
        outbound.conversationId = inbound.conversationId;
        outbound.inReplyTo = inbound.replyWith;
        _respond(inbound, manager, outbound);
    }

    function informDone(Message calldata inbound, address manager) external {
        Message memory outbound;
        outbound.performative = uint8(Performative.Inform);
        outbound.protocol = inbound.protocol;
        outbound.conversationId = inbound.conversationId;
        outbound.inReplyTo = inbound.replyWith;
        _respond(inbound, manager, outbound);
    }
}
