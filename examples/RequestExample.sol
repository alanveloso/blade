// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RequestAgent} from "../src/core/RequestAgent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

/// @dev Application wrapper: Core keeps `_startRequest` internal.
contract ExampleRequester is RequestAgent {
    constructor(address trustedRelay_) RequestAgent(trustedRelay_) {}

    function request(address participant, bytes32 conversationId, bytes calldata content) external {
        Message memory outbound;
        outbound.performative = uint8(Performative.Request);
        outbound.protocol = uint8(Protocol.FipaRequest);
        outbound.conversationId = conversationId;
        outbound.content = content;
        _startRequest(participant, outbound);
    }
}

/// @dev Application policy: always inform-done. Authorization is not a Core concern.
contract ExampleParticipant is RequestAgent {
    constructor(address trustedRelay_) RequestAgent(trustedRelay_) {}

    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative != uint8(Performative.Request)) {
            return;
        }
        Message memory outbound;
        outbound.performative = uint8(Performative.Inform);
        outbound.protocol = inbound.protocol;
        outbound.conversationId = inbound.conversationId;
        outbound.inReplyTo = inbound.replyWith;
        _reply(inbound, msg.sender, outbound);
    }
}
