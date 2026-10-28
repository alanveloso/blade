// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "../src/core/Agent.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {ContractNetParticipant} from "../src/core/ContractNetParticipant.sol";
import {Message} from "../src/core/Message.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {RequestAgent} from "../src/core/RequestAgent.sol";

/// @dev Test/example leaf: Request + CN manager + CN participant, one `Agent` instance.
/// @dev Routing only. Request/CN transitions stay in the protocol modules.
/// @dev Unsupported: this contract as CN manager and CN participant of the same `conversationId`.
/// That overlap is rejected (`InvalidTransition` / `UnexpectedPeer`), not dual-routed.
contract CompositeAgent is RequestAgent, ContractNetManager, ContractNetParticipant {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}

    function startRequest(address to, Message memory outbound) external {
        _startRequest(to, outbound);
    }

    function respond(Message calldata inbound, address to, Message memory outbound) external {
        _reply(inbound, to, outbound);
    }

    function cfp(address[] calldata participants, Message memory message) external {
        if (_cn[message.conversationId].phase != ContractNetLib.PART_NONE) {
            revert ContractNetLib.InvalidTransition();
        }
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

    function _onInbound(Message calldata message)
        internal
        override(RequestAgent, ContractNetManager, ContractNetParticipant)
    {
        if (_handleRequestInbound(message)) {
            return;
        }
        if (_handleContractNetManagerInbound(message)) {
            return;
        }
        if (_handleContractNetParticipantInbound(message)) {
            return;
        }
        if (message.protocol == uint8(Protocol.FipaContractNet)) {
            revert ContractNetLib.InvalidTransition();
        }
    }

    function _reply(Message calldata inbound, address to, Message memory outbound)
        internal
        override(Agent, RequestAgent, ContractNetParticipant)
    {
        if (!_handleRequestReply(inbound, to, outbound)) {
            _handleContractNetParticipantReply(inbound, to, outbound);
        }
        Agent._reply(inbound, to, outbound);
    }
}
