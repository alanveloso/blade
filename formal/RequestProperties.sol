// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {RequestAgent, RequestRole, RequestPhase} from "../src/core/RequestAgent.sol";
import {Agent} from "../src/core/Agent.sol";
import {Performative} from "../src/core/Performative.sol";
import {Message} from "../src/core/Message.sol";

/// @dev Harness invokes actual inherited implementation. Assertions describe successful returns.
/// Arbitrary roles/phases are allowed; no copied/abstract transition implementation.
contract RequestProperties is RequestAgent {
    constructor(address relay) Agent(relay) {}

    function participantCannotContinue(RequestPhase phase, Performative act) external pure {
        RequestPhase next = _nextInbound(RequestRole.Participant, phase, act);
        assert(act == Performative.NotUnderstood);
        assert(next == RequestPhase.Terminal);
    }

    function agreeRequiresRequested(RequestPhase phase, Performative act) external pure {
        RequestPhase next = _nextInbound(RequestRole.Initiator, phase, act);
        if (next == RequestPhase.Agreed) {
            assert(phase == RequestPhase.Requested && act == Performative.Agree);
        }
        assert(next == RequestPhase.Agreed || next == RequestPhase.Terminal);
    }

    function authorization(Message calldata m) external view {
        _authenticate(m);
        assert(m.logicalSender == bytes32(0) || msg.sender == trustedRelay);
        assert(
            msg.sender != trustedRelay || trustedRelay == address(0)
                || m.logicalSender != bytes32(0)
        );
    }

    function correlation(bytes32 id, bytes32 token, bool initiator, bytes32 rw, bytes32 irt)
        external
    {
        _request[id].replyWith = token;
        _assertCorrelated(_request[id], initiator, rw, irt);
        assert((initiator ? rw : irt) == token);
    }

    function peer(bytes32 id, address transport, bytes32 logical, Message calldata m) external {
        _request[id].transportPeer = transport;
        _request[id].logicalPeer = logical;
        _assertPeer(_request[id], m);
        assert(
            logical == bytes32(0)
                ? msg.sender == transport && m.logicalSender == bytes32(0)
                : msg.sender == trustedRelay && m.logicalSender == logical
        );
    }
}
