pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BehaviorContext, ContextLib, Trigger} from "../../src/behavior/Context.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {ContractNetManager} from "../../src/core/ContractNetManager.sol";
import {Message} from "../../src/core/Message.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {Performative} from "../../src/core/Performative.sol";

contract ScriptedRequest is RequestAgent {
    constructor() Agent(address(0)) {}
}

contract ScriptedManager is ContractNetManager {
    constructor() Agent(address(0)) {}
}

/// @dev External wrapper so `expectRevert` sees a deeper call than the test.
contract ContextHarness {
    function validate(BehaviorContext memory ctx) external pure {
        ContextLib.validate(ctx);
    }

    function triggerOf(BehaviorContext memory ctx) external pure returns (Trigger) {
        return ContextLib.triggerOf(ctx);
    }

    function messageTrigger(address agent, address transportCaller, Message calldata m)
        external
        pure
        returns (BehaviorContext memory)
    {
        return ContextLib.messageTrigger(agent, transportCaller, m);
    }

    function explicitTrigger(address agent, address transportCaller)
        external
        pure
        returns (BehaviorContext memory)
    {
        return ContextLib.explicitTrigger(agent, transportCaller);
    }
}

/// @dev Increments `effects` only after a successful structural `validate`.
contract ValidateProbe {
    uint256 public effects;

    function validate(BehaviorContext memory ctx) external {
        ContextLib.validate(ctx);
        effects++;
    }
}

/// @dev Ordinary-call stand-in for future `decide`. Records identity; does not treat caller as remote peer.
contract DecideProbe {
    address public seenSender;
    address public seenAgent;
    address public seenTransport;
    bytes32 public seenLogical;
    uint8 public seenTrigger;

    function decide(BehaviorContext memory ctx) external {
        ContextLib.validate(ctx);
        seenSender = msg.sender;
        seenAgent = ctx.agent;
        seenTransport = ctx.transportCaller;
        seenLogical = ctx.logicalSender;
        seenTrigger = ctx.trigger;
    }
}

contract ContextAuthor {
    function publishMessage(address transportCaller, Message calldata m, DecideProbe probe)
        external
    {
        probe.decide(ContextLib.messageTrigger(address(this), transportCaller, m));
    }

    function publishExplicit(address transportCaller, DecideProbe probe) external {
        probe.decide(ContextLib.explicitTrigger(address(this), transportCaller));
    }
}

contract ContextTest is Test {
    Agent internal agent;
    ScriptedRequest internal requester;
    ScriptedManager internal manager;
    ContextHarness internal harness;
    ValidateProbe internal probe;
    DecideProbe internal decideProbe;
    ContextAuthor internal author;

    address internal inboundCaller;
    address internal keeper;

    function setUp() public {
        agent = new Agent(address(0));
        requester = new ScriptedRequest();
        manager = new ScriptedManager();
        harness = new ContextHarness();
        probe = new ValidateProbe();
        decideProbe = new DecideProbe();
        author = new ContextAuthor();
        inboundCaller = makeAddr("inbound");
        keeper = makeAddr("keeper");
    }

    function _message() internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Inform);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = keccak256("conversation");
        m.replyWith = keccak256("reply-with");
        m.inReplyTo = keccak256("in-reply-to");
        m.replyBy = 1;
        m.content = bytes(hex"c0ffee");
    }

    function test_zeroedStructIsNoneAndReverts() public {
        BehaviorContext memory ctx;
        assertEq(ctx.trigger, uint8(Trigger.None));
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        harness.validate(ctx);
    }

    function test_noneWithFilledFieldsStillRevertsUninitialized() public {
        BehaviorContext memory ctx;
        ctx.trigger = uint8(Trigger.None);
        ctx.agent = address(agent);
        ctx.transportCaller = inboundCaller;
        ctx.logicalSender = keccak256("logical");
        ctx.performative = uint8(Performative.Request);
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        harness.validate(ctx);
    }

    function test_unknownTriggerReverts() public {
        BehaviorContext memory ctx;
        ctx.trigger = uint8(Trigger.Explicit) + 1;
        ctx.agent = address(agent);
        ctx.transportCaller = inboundCaller;
        vm.expectRevert(ContextLib.UnknownTrigger.selector);
        harness.validate(ctx);
    }

    function testFuzz_unknownTriggerReverts(uint8 trigger) public {
        vm.assume(trigger != uint8(Trigger.None));
        vm.assume(trigger != uint8(Trigger.Message));
        vm.assume(trigger != uint8(Trigger.Explicit));
        BehaviorContext memory ctx;
        ctx.trigger = trigger;
        ctx.agent = address(agent);
        ctx.transportCaller = inboundCaller;
        vm.expectRevert(ContextLib.UnknownTrigger.selector);
        harness.validate(ctx);
    }

    function test_noneCheckedBeforeAgentRule() public {
        BehaviorContext memory ctx;
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        harness.validate(ctx);
    }

    function test_messageTriggerCopiesEnvelopeNotContent() public view {
        Message memory m = _message();
        bytes memory unique = abi.encodePacked(keccak256("unique-payload-absent-from-context"));
        m.content = unique;
        BehaviorContext memory ctx = harness.messageTrigger(address(agent), inboundCaller, m);
        assertEq(uint8(harness.triggerOf(ctx)), uint8(Trigger.Message));
        assertEq(ctx.agent, address(agent));
        assertEq(ctx.transportCaller, inboundCaller);
        assertEq(ctx.logicalSender, m.logicalSender);
        assertEq(ctx.performative, m.performative);
        assertEq(ctx.protocol, m.protocol);
        assertEq(ctx.conversationId, m.conversationId);
        assertEq(ctx.replyWith, m.replyWith);
        assertEq(ctx.inReplyTo, m.inReplyTo);
        assertEq(ctx.replyBy, m.replyBy);
        assertFalse(_contains(abi.encode(ctx), unique));
    }

    function test_messageNativeLogicalSenderMayBeZero() public view {
        Message memory m = _message();
        m.logicalSender = bytes32(0);
        BehaviorContext memory ctx = harness.messageTrigger(address(agent), inboundCaller, m);
        assertEq(ctx.logicalSender, bytes32(0));
    }

    function test_messageRelayShapedLogicalSenderCopied() public view {
        Message memory m = _message();
        m.logicalSender = keccak256("opaque-logical");
        BehaviorContext memory ctx = harness.messageTrigger(address(agent), inboundCaller, m);
        assertEq(ctx.logicalSender, m.logicalSender);
    }

    function test_messageRequiresTransportCaller() public {
        Message memory m = _message();
        vm.expectRevert(ContextLib.MessageRequiresTransportCaller.selector);
        harness.messageTrigger(address(agent), address(0), m);
    }

    function test_messageRequiresAgent() public {
        Message memory m = _message();
        vm.expectRevert(ContextLib.AgentRequired.selector);
        harness.messageTrigger(address(0), inboundCaller, m);
    }

    function test_messageDoesNotDuplicateProtocolConversationRule() public view {
        Message memory m;
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = bytes32(0);
        BehaviorContext memory ctx = harness.messageTrigger(address(agent), inboundCaller, m);
        assertEq(ctx.protocol, uint8(Protocol.FipaRequest));
        assertEq(ctx.conversationId, bytes32(0));
    }

    function test_explicitTriggerZerosEnvelopeKeepsExecutionCaller() public view {
        BehaviorContext memory ctx = harness.explicitTrigger(address(agent), keeper);
        assertEq(uint8(harness.triggerOf(ctx)), uint8(Trigger.Explicit));
        assertEq(ctx.agent, address(agent));
        assertEq(ctx.transportCaller, keeper);
        assertEq(ctx.logicalSender, bytes32(0));
        assertEq(ctx.performative, 0);
        assertEq(ctx.protocol, 0);
        assertEq(ctx.conversationId, bytes32(0));
        assertEq(ctx.replyWith, bytes32(0));
        assertEq(ctx.inReplyTo, bytes32(0));
        assertEq(ctx.replyBy, 0);
    }

    function test_explicitZeroPerformativeIsUnusedNotRequest() public view {
        BehaviorContext memory ctx = harness.explicitTrigger(address(agent), keeper);
        assertEq(ctx.trigger, uint8(Trigger.Explicit));
        assertEq(ctx.performative, uint8(Performative.Request));
        assertTrue(ctx.trigger != uint8(Trigger.Message));
    }

    function test_explicitNonZeroLogicalSenderReverts() public {
        BehaviorContext memory ctx = harness.explicitTrigger(address(agent), keeper);
        ctx.logicalSender = keccak256("smuggle");
        vm.expectRevert(ContextLib.ExplicitRequiresZeroLogicalSender.selector);
        harness.validate(ctx);
    }

    function test_explicitEnvelopeResidueReverts() public {
        BehaviorContext memory ctx = harness.explicitTrigger(address(agent), keeper);
        ctx.conversationId = keccak256("smuggle-envelope");
        vm.expectRevert(ContextLib.ExplicitRequiresEmptyEnvelope.selector);
        harness.validate(ctx);
    }

    function test_explicitRequiresAgent() public {
        vm.expectRevert(ContextLib.AgentRequired.selector);
        harness.explicitTrigger(address(0), keeper);
    }

    function test_explicitAllowsZeroTransportCaller() public view {
        BehaviorContext memory ctx = harness.explicitTrigger(address(agent), address(0));
        assertEq(ctx.transportCaller, address(0));
        assertEq(ctx.logicalSender, bytes32(0));
    }

    function test_invalidDoesNotIncrementEffects() public {
        BehaviorContext memory ctx;
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        probe.validate(ctx);
        assertEq(probe.effects(), 0);
    }

    function test_validMessageIncrementsEffects() public {
        probe.validate(harness.messageTrigger(address(agent), inboundCaller, _message()));
        assertEq(probe.effects(), 1);
    }

    function test_identityProbeMessageDoesNotTreatDecideSenderAsRemotePeer() public {
        author.publishMessage(inboundCaller, _message(), decideProbe);
        assertEq(decideProbe.seenSender(), address(author));
        assertEq(decideProbe.seenAgent(), address(author));
        assertEq(decideProbe.seenTransport(), inboundCaller);
        assertEq(decideProbe.seenTrigger(), uint8(Trigger.Message));
        assertTrue(decideProbe.seenSender() != decideProbe.seenTransport());
    }

    function test_identityProbeExplicitKeeperIsTransportNotLogical() public {
        author.publishExplicit(keeper, decideProbe);
        assertEq(decideProbe.seenSender(), address(author));
        assertEq(decideProbe.seenAgent(), address(author));
        assertEq(decideProbe.seenTransport(), keeper);
        assertEq(decideProbe.seenLogical(), bytes32(0));
        assertEq(decideProbe.seenTrigger(), uint8(Trigger.Explicit));
        assertTrue(decideProbe.seenTransport() != address(0));
    }

    function test_buildersDoNotWriteAgentRequestOrContractNet() public {
        bytes32 id = keccak256("context-none");
        vm.record();
        harness.messageTrigger(address(agent), inboundCaller, _message());
        harness.explicitTrigger(address(agent), keeper);
        _assertNoWrites(address(agent));
        _assertNoWrites(address(requester));
        _assertNoWrites(address(manager));
        RequestAgent.Status memory st = requester.requestStatus(id);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
        assertEq(manager.slotOf(id, address(requester)), 0);
        assertEq(agent.trustedRelay(), address(0));
    }

    function test_kernelContractsStillAcceptHandleAfterContextLib() public {
        harness.explicitTrigger(address(agent), keeper);
        Message memory m;
        m.performative = 0;
        m.conversationId = keccak256("still-handle");
        agent.handle(m);
    }

    function _assertNoWrites(address target) internal view {
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) {
            return false;
        }
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }
        return false;
    }
}
