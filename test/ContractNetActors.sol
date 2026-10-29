pragma solidity ^0.8.26;

import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {ContractNetParticipant} from "../src/core/ContractNetParticipant.sol";
import {Agent} from "../src/core/Agent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";

/// @dev Test/application wrappers. Production decision primitives stay internal.
contract ExposedContractNetManager is ContractNetManager {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}

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
    constructor(address trustedRelay_) Agent(trustedRelay_) {}

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

/// @dev Reentry through the participant's own `_reply`: its FSM (ACCEPTED -> Propose) rejects the
/// act before any call reaches the manager. Kept as a participant-side regression only.
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

/// @dev Adversarial participant. When it receives `trigger` from the manager it performs an
/// arbitrary low-level call (typically `manager.handle(...)`, `evaluate`, or `cfp`) without going
/// through its own Contract Net FSM, records what the target returned, and optionally bubbles it.
contract DirectReentrantParticipant is ExposedContractNetParticipant {
    uint8 public trigger;
    address public target;
    bytes public payload;
    bool public bubble;
    bool public armed;

    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;
    uint8 public slotSeenDuringReentry;
    bool public evaluatedSeenDuringReentry;

    constructor() ExposedContractNetParticipant(address(0)) {}

    function arm(uint8 trigger_, address target_, bytes calldata payload_, bool bubble_) external {
        trigger = trigger_;
        target = target_;
        payload = payload_;
        bubble = bubble_;
        armed = true;
    }

    function _onReceive(Message calldata inbound) internal override {
        if (!armed || attempted || inbound.performative != trigger) {
            return;
        }
        attempted = true;
        ContractNetManager m = ContractNetManager(msg.sender);
        slotSeenDuringReentry = m.slotOf(inbound.conversationId, address(this));
        evaluatedSeenDuringReentry = m.conversation(inbound.conversationId).evaluated;
        (bool ok, bytes memory ret) = target.call(payload);
        reentrySucceeded = ok;
        reentryReturnData = ret;
        if (!ok && bubble) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @dev Reverts on every manager decision (accept and reject), after proposing normally.
contract RevertOnDecisionParticipant is ExposedContractNetParticipant {
    constructor() ExposedContractNetParticipant(address(0)) {}

    function _onReceive(Message calldata inbound) internal override {
        if (
            inbound.performative == uint8(Performative.AcceptProposal)
                || inbound.performative == uint8(Performative.RejectProposal)
        ) {
            revert("decision-revert");
        }
    }
}

/// @dev Consumes gas on AcceptProposal. `reserve == 0` loops until out of gas.
contract GasBurnerParticipant is ExposedContractNetParticipant {
    uint256 public immutable reserve;
    uint256 public sink;

    constructor(uint256 reserve_) ExposedContractNetParticipant(address(0)) {
        reserve = reserve_;
    }

    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative != uint8(Performative.AcceptProposal)) {
            return;
        }
        uint256 x;
        while (reserve == 0 || gasleft() > reserve) {
            unchecked {
                x++;
            }
        }
        sink = x;
    }
}

/// @dev Application wrapper that evaluates two conversations in one transaction.
contract BatchingContractNetManager is ExposedContractNetManager {
    constructor() ExposedContractNetManager(address(0)) {}

    function evaluateTwo(
        bytes32 a,
        address[] calldata acceptA,
        bytes32 b,
        address[] calldata acceptB
    ) external {
        address[] calldata none = acceptA[0:0];
        _evaluate(a, acceptA, none, none);
        _evaluate(b, acceptB, none, none);
    }
}

/// @dev Application wrapper that gates the decision primitives (the Core does not).
contract OwnerGatedContractNetManager is ContractNetManager {
    address public immutable owner;

    error NotOwner();

    constructor() Agent(address(0)) {
        owner = msg.sender;
    }

    function cfp(address[] calldata participants, Message memory message) external {
        if (msg.sender != owner) revert NotOwner();
        _cfp(participants, message);
    }

    function evaluate(
        bytes32 conversationId,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external {
        if (msg.sender != owner) revert NotOwner();
        _evaluate(conversationId, accept, reject, silent);
    }
}

/// @dev Test-only participant that records manager decision metadata.
contract DecisionRecordingParticipant is ExposedContractNetParticipant {
    uint8 public lastDecision;
    uint64 public lastDecisionReplyBy;

    constructor() ExposedContractNetParticipant(address(0)) {}

    function _onReceive(Message calldata inbound) internal override {
        if (
            inbound.performative == uint8(Performative.AcceptProposal)
                || inbound.performative == uint8(Performative.RejectProposal)
        ) {
            lastDecision = inbound.performative;
            lastDecisionReplyBy = inbound.replyBy;
        }
    }
}

/// @dev Deployable Core role with no application `cfp`/`evaluate` selectors.
contract BareContractNetManager is ContractNetManager {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}
}

/// @dev Deployable Core role with no application `respond` selector.
contract BareContractNetParticipant is ContractNetParticipant {
    constructor(address trustedRelay_) Agent(trustedRelay_) {}
}
