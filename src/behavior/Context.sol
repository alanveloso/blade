// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Message} from "../core/Message.sol";

/// @dev Discriminator for how this execution was provoked. Envelope only — not a frozen API.
/// @dev `None` is uninitialized. Zero must not mean `Message` (`Performative.Request` is also 0).
enum Trigger {
    None,
    Message,
    Explicit
}

/// @dev Bit 0 = Message, bit 1 = Explicit. Zero mask is invalid.
uint8 constant TRIGGER_MESSAGE = 1;
uint8 constant TRIGGER_EXPLICIT = 2;
/// @dev Wildcard for `protocol` / `performative`. Not `0`: `Performative.Request` is 0.
uint8 constant FILTER_ANY = type(uint8).max;

/// @dev Per-installation eligibility. Not a JADE MessageTemplate. Not protocol-role dispatch.
struct BehaviorFilter {
    uint8 triggerMask;
    uint8 protocol;
    uint8 performative;
}

/// @dev Agent-authored view a Behavior may observe. No `content`. Not a FIPA AID.
/// @dev `ContextLib.validate` is shape/canonicalization, not authentication. The Agent is the trust source.
struct BehaviorContext {
    uint8 trigger;
    address agent;
    address transportCaller;
    bytes32 logicalSender;
    uint8 performative;
    uint8 protocol;
    bytes32 conversationId;
    bytes32 replyWith;
    bytes32 inReplyTo;
    uint64 replyBy;
}

library ContextLib {
    error UninitializedTrigger();
    error UnknownTrigger();
    error AgentRequired();
    error MessageRequiresTransportCaller();
    error ExplicitRequiresZeroLogicalSender();
    error ExplicitRequiresEmptyEnvelope();

    /// @dev Structural checks only. Does not authenticate `transportCaller` or `logicalSender`.
    /// @dev Trigger is checked before identity/envelope rules.
    function validateFields(
        uint8 trigger,
        address agent,
        address transportCaller,
        bytes32 logicalSender,
        uint8 performative,
        uint8 protocol,
        bytes32 conversationId,
        bytes32 replyWith,
        bytes32 inReplyTo,
        uint64 replyBy
    ) internal pure {
        if (trigger == uint8(Trigger.None)) {
            revert UninitializedTrigger();
        }
        if (trigger != uint8(Trigger.Message) && trigger != uint8(Trigger.Explicit)) {
            revert UnknownTrigger();
        }
        if (agent == address(0)) {
            revert AgentRequired();
        }
        if (trigger == uint8(Trigger.Message)) {
            if (transportCaller == address(0)) {
                revert MessageRequiresTransportCaller();
            }
            return;
        }
        if (logicalSender != bytes32(0)) {
            revert ExplicitRequiresZeroLogicalSender();
        }
        if (
            performative != 0 || protocol != 0 || conversationId != bytes32(0)
                || replyWith != bytes32(0) || inReplyTo != bytes32(0) || replyBy != 0
        ) {
            revert ExplicitRequiresEmptyEnvelope();
        }
    }

    function validate(BehaviorContext memory ctx) internal pure {
        validateFields(
            ctx.trigger,
            ctx.agent,
            ctx.transportCaller,
            ctx.logicalSender,
            ctx.performative,
            ctx.protocol,
            ctx.conversationId,
            ctx.replyWith,
            ctx.inReplyTo,
            ctx.replyBy
        );
    }

    function triggerOf(BehaviorContext memory ctx) internal pure returns (Trigger) {
        validate(ctx);
        if (ctx.trigger == uint8(Trigger.Message)) {
            return Trigger.Message;
        }
        return Trigger.Explicit;
    }

    /// @dev Canonical Message trigger. Caller must already have authenticated the facts.
    /// @dev Copies envelope fields. Never copies `m.content`.
    function messageTrigger(address agent, address transportCaller, Message calldata m)
        internal
        pure
        returns (BehaviorContext memory ctx)
    {
        ctx.trigger = uint8(Trigger.Message);
        ctx.agent = agent;
        ctx.transportCaller = transportCaller;
        ctx.logicalSender = m.logicalSender;
        ctx.performative = m.performative;
        ctx.protocol = m.protocol;
        ctx.conversationId = m.conversationId;
        ctx.replyWith = m.replyWith;
        ctx.inReplyTo = m.inReplyTo;
        ctx.replyBy = m.replyBy;
        validate(ctx);
    }

    /// @dev Canonical Explicit trigger. `transportCaller` is who provoked this execution, not a logical peer.
    function explicitTrigger(address agent, address transportCaller)
        internal
        pure
        returns (BehaviorContext memory ctx)
    {
        ctx.trigger = uint8(Trigger.Explicit);
        ctx.agent = agent;
        ctx.transportCaller = transportCaller;
        validate(ctx);
    }
}

library FilterLib {
    error InvalidBehaviorFilter();

    function anyFilter() internal pure returns (BehaviorFilter memory f) {
        f.triggerMask = TRIGGER_MESSAGE | TRIGGER_EXPLICIT;
        f.protocol = FILTER_ANY;
        f.performative = FILTER_ANY;
    }

    function validate(BehaviorFilter memory f) internal pure {
        uint8 allowed = TRIGGER_MESSAGE | TRIGGER_EXPLICIT;
        if (f.triggerMask == 0 || (f.triggerMask & ~allowed) != 0) {
            revert InvalidBehaviorFilter();
        }
        if (
            f.triggerMask == TRIGGER_EXPLICIT
                && (f.protocol != FILTER_ANY || f.performative != FILTER_ANY)
        ) {
            revert InvalidBehaviorFilter();
        }
    }

    /// @dev Envelope fields apply only to Message triggers. Explicit matches the mask alone.
    function matches(BehaviorFilter memory f, BehaviorContext memory ctx)
        internal
        pure
        returns (bool)
    {
        uint8 bit;
        if (ctx.trigger == uint8(Trigger.Message)) {
            bit = TRIGGER_MESSAGE;
        } else if (ctx.trigger == uint8(Trigger.Explicit)) {
            bit = TRIGGER_EXPLICIT;
        } else {
            return false;
        }
        if ((f.triggerMask & bit) == 0) {
            return false;
        }
        if (ctx.trigger == uint8(Trigger.Explicit)) {
            return true;
        }
        if (f.protocol != FILTER_ANY && f.protocol != ctx.protocol) {
            return false;
        }
        if (f.performative != FILTER_ANY && f.performative != ctx.performative) {
            return false;
        }
        return true;
    }
}
