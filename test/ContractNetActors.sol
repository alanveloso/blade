pragma solidity ^0.8.26;

import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {ContractNetParticipant} from "../src/core/ContractNetParticipant.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";

/// @dev Test/application wrappers. Production decision primitives stay internal.
contract ExposedContractNetManager is ContractNetManager {
    constructor(address trustedRelay_) ContractNetManager(trustedRelay_) {}

    function cfp(address[] calldata participants, Message memory message) external {
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

contract ExposedContractNetParticipant is ContractNetParticipant {
    constructor(address trustedRelay_) ContractNetParticipant(trustedRelay_) {}

    function respond(Message calldata inbound, address to, Message memory outbound) external {
        _respond(inbound, to, outbound);
    }
}

contract AutoCompleteParticipant is ExposedContractNetParticipant {
    uint8 public immutable completeWith;

    constructor(uint8 completeWith_) ExposedContractNetParticipant(address(0)) {
        completeWith = completeWith_;
    }

    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative == uint8(Performative.AcceptProposal)) {
            Message memory outbound;
            outbound.performative = completeWith;
            outbound.protocol = inbound.protocol;
            outbound.conversationId = inbound.conversationId;
            outbound.inReplyTo = inbound.replyWith;
            _reply(inbound, msg.sender, outbound);
        }
    }
}

contract RevertOnAcceptParticipant is ExposedContractNetParticipant {
    constructor() ExposedContractNetParticipant(address(0)) {}

    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative == uint8(Performative.AcceptProposal)) {
            revert("accept-handle-revert");
        }
    }
}

contract RevertOnCfpParticipant is ExposedContractNetParticipant {
    constructor() ExposedContractNetParticipant(address(0)) {}

    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative == uint8(Performative.Cfp)) {
            revert("cfp-handle-revert");
        }
    }
}

contract MaliciousReentrantParticipant is ExposedContractNetParticipant {
    constructor() ExposedContractNetParticipant(address(0)) {}

    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative == uint8(Performative.AcceptProposal)) {
            Message memory outbound;
            outbound.performative = uint8(Performative.Propose);
            outbound.protocol = inbound.protocol;
            outbound.conversationId = inbound.conversationId;
            outbound.inReplyTo = inbound.replyWith;
            _reply(inbound, msg.sender, outbound);
        }
    }
}
