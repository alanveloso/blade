pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BehaviorRuntime} from "../../src/behavior/BehaviorRuntime.sol";
import {BehaviorEngine} from "../../src/behavior/BehaviorEngine.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {Action, ActionLib, Kind} from "../../src/behavior/Action.sol";
import {BehaviorContext, Trigger} from "../../src/behavior/Context.sol";
import {Agent} from "../../src/core/Agent.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";

uint256 constant DEFAULT_STEP_GAS = 200_000;

error InboundDenied();

/// @dev View strategy: STATICCALL-safe identity/envelope assertions.
contract ContextExpect is IExternalApplicationStrategy {
    address public immutable expectedAgent;
    address public immutable expectedTransport;
    bytes32 public immutable expectedLogical;
    uint8 public immutable expectedTrigger;
    bool public immutable requireEmptyEnvelope;

    constructor(
        address expectedAgent_,
        address expectedTransport_,
        bytes32 expectedLogical_,
        uint8 expectedTrigger_,
        bool requireEmptyEnvelope_
    ) {
        expectedAgent = expectedAgent_;
        expectedTransport = expectedTransport_;
        expectedLogical = expectedLogical_;
        expectedTrigger = expectedTrigger_;
        requireEmptyEnvelope = requireEmptyEnvelope_;
    }

    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) {
            revert("identity");
        }
        if (ctx.agent != expectedAgent) {
            revert("agent");
        }
        if (ctx.transportCaller != expectedTransport) {
            revert("transport");
        }
        if (ctx.logicalSender != expectedLogical) {
            revert("logical");
        }
        if (ctx.trigger != expectedTrigger) {
            revert("trigger");
        }
        if (requireEmptyEnvelope) {
            if (
                ctx.performative != 0 || ctx.protocol != 0 || ctx.conversationId != bytes32(0)
                    || ctx.replyWith != bytes32(0) || ctx.inReplyTo != bytes32(0)
                    || ctx.replyBy != 0
            ) {
                revert("envelope");
            }
        }
        a.kind = uint8(Kind.None);
    }
}

contract NoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) {
            revert("identity");
        }
        a.kind = uint8(Kind.None);
    }
}

contract NoneStrategyB is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) {
            revert("identity");
        }
        a.kind = uint8(Kind.None);
    }
}

contract UnknownKindStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = 1;
    }
}

/// @dev Test leaf. `exposedDispatch` is harness-only, not a product Explicit endpoint.
contract RuntimeAgent is BehaviorRuntime {
    uint256 internal immutable _stepGas;

    constructor(address trustedRelay_, uint256 stepGas_) Agent(trustedRelay_) {
        _stepGas = stepGas_;
    }

    function _behaviorStepGas() internal view override returns (uint256) {
        return _stepGas;
    }

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclicBehavior(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function exposedDispatch(uint256 stepGas) external {
        _dispatchExplicitTrigger(stepGas);
    }
}

contract GatedRuntime is RuntimeAgent {
    address public immutable allowed;

    constructor(address allowed_) RuntimeAgent(address(0), DEFAULT_STEP_GAS) {
        allowed = allowed_;
    }

    function _authorizeInbound(Message calldata) internal view override {
        if (msg.sender != allowed) {
            revert InboundDenied();
        }
    }
}

/// @dev Engine composed with Agent but without runtime `_onReceive` dispatch.
contract EngineNoRuntime is Agent, BehaviorEngine {
    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }
}

contract BehaviorRuntimeTest is Test {
    RuntimeAgent internal runtime;
    RuntimeAgent internal relayed;
    EngineNoRuntime internal engineOnly;
    NoneStrategy internal noneA;
    NoneStrategyB internal noneB;
    UnknownKindStrategy internal unknownKind;
    bytes32 internal idA;
    bytes32 internal idB;
    bytes32 internal idC;
    address internal peer;
    address internal relay;
    address internal stranger;
    bytes32 internal logical;

    function setUp() public {
        peer = makeAddr("peer");
        relay = makeAddr("relay");
        stranger = makeAddr("stranger");
        logical = keccak256("logical-sender");
        runtime = new RuntimeAgent(address(0), DEFAULT_STEP_GAS);
        relayed = new RuntimeAgent(relay, DEFAULT_STEP_GAS);
        engineOnly = new EngineNoRuntime();
        noneA = new NoneStrategy();
        noneB = new NoneStrategyB();
        unknownKind = new UnknownKindStrategy();
        idA = keccak256("A");
        idB = keccak256("B");
        idC = keccak256("C");
    }

    function _inform() internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Inform);
        m.protocol = uint8(Protocol.None);
        m.conversationId = keccak256("runtime-msg");
        m.content = hex"c0ffee";
    }

    function test_nativeHandleAuthorsAuthenticatedContext() public {
        ContextExpect expect =
            new ContextExpect(address(runtime), peer, bytes32(0), uint8(Trigger.Message), false);
        runtime.installBehavior(idA, address(expect));
        vm.expectEmit(true, true, false, true, address(runtime));
        emit Agent.Received(
            peer,
            keccak256("runtime-msg"),
            bytes32(0),
            uint8(Performative.Inform),
            uint8(Protocol.None),
            bytes32(0),
            bytes32(0),
            0,
            hex"c0ffee"
        );
        vm.prank(peer);
        runtime.handle(_inform());
        assertEq(runtime.installedBehaviorCount(), 0);
    }

    function test_relayHandleAuthorsRelayTransportAndLogicalSender() public {
        ContextExpect expect =
            new ContextExpect(address(relayed), relay, logical, uint8(Trigger.Message), false);
        relayed.installBehavior(idA, address(expect));
        Message memory m = _inform();
        m.logicalSender = logical;
        vm.prank(relay);
        relayed.handle(m);
        assertEq(relayed.installedBehaviorCount(), 0);
    }

    function test_nonRelayCannotSetLogicalSenderBeforeDispatch() public {
        runtime.installBehavior(idA, address(noneA));
        Message memory m = _inform();
        m.logicalSender = logical;
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(peer);
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        runtime.handle(m);
        assertEq(runtime.installedBehaviorCount(), 1);
    }

    function test_explicitAuthorsEmptyEnvelopeFromCaller() public {
        ContextExpect expect = new ContextExpect(
            address(runtime), stranger, bytes32(0), uint8(Trigger.Explicit), true
        );
        runtime.installBehavior(idA, address(expect));
        vm.prank(stranger);
        runtime.exposedDispatch(DEFAULT_STEP_GAS);
        assertEq(runtime.installedBehaviorCount(), 0);
    }

    function test_runtimeHasNoPublicUnrestrictedExplicitEndpoint() public {
        (bool ok,) = address(runtime)
            .call(abi.encodeWithSignature("dispatchExplicitTrigger(uint256)", DEFAULT_STEP_GAS));
        assertFalse(ok);
        (ok,) = address(runtime)
            .call(
                abi.encodeWithSignature(
                    "runBehaviorStep((uint8,address,address,bytes32,uint8,uint8,bytes32,bytes32,bytes32,uint64),uint256)"
                )
            );
        assertFalse(ok);
    }

    function test_mixedPoolOneExplicitTriggerWalksAll() public {
        runtime.installBehavior(idA, address(noneA));
        runtime.installCyclicBehavior(idB, address(noneB));
        runtime.installBehavior(idC, address(noneA));
        runtime.exposedDispatch(DEFAULT_STEP_GAS);
        assertEq(runtime.installedBehaviorCount(), 1);
        assertEq(runtime.installedBehaviorAt(0), idB);
    }

    function test_mixedPoolOneHandleTriggerWalksAll() public {
        runtime.installBehavior(idA, address(noneA));
        runtime.installCyclicBehavior(idB, address(noneB));
        runtime.installBehavior(idC, address(noneA));
        vm.prank(peer);
        runtime.handle(_inform());
        assertEq(runtime.installedBehaviorCount(), 1);
        assertEq(runtime.installedBehaviorAt(0), idB);
    }

    function test_handleDoesNotUseAtMostWindow() public {
        runtime.installBehavior(idA, address(noneA));
        runtime.installCyclicBehavior(idB, address(noneB));
        runtime.installBehavior(idC, address(noneA));
        vm.prank(peer);
        runtime.handle(_inform());
        assertEq(runtime.behaviorImplementation(idA), address(0));
        assertEq(runtime.behaviorImplementation(idC), address(0));
        assertEq(runtime.installedBehaviorAt(0), idB);
    }

    function test_emptyPoolHandleEmitsReceivedWithoutDecide() public {
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.expectEmit(true, true, false, true, address(runtime));
        emit Agent.Received(
            peer,
            keccak256("runtime-msg"),
            bytes32(0),
            uint8(Performative.Inform),
            uint8(Protocol.None),
            bytes32(0),
            bytes32(0),
            0,
            hex"c0ffee"
        );
        vm.prank(peer);
        runtime.handle(_inform());
        assertEq(runtime.installedBehaviorCount(), 0);
    }

    function test_zeroStepGasWithInstalledRevertsHandle() public {
        RuntimeAgent zeroGas = new RuntimeAgent(address(0), 0);
        zeroGas.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.expectRevert(BehaviorEngine.InvalidStepGas.selector);
        vm.prank(peer);
        zeroGas.handle(_inform());
        assertEq(zeroGas.installedBehaviorCount(), 1);
    }

    function test_failFastHandleRevertsReceivedAndKeepsOneShot() public {
        runtime.installBehavior(idA, address(unknownKind));
        vm.expectRevert(ActionLib.UnknownKind.selector);
        vm.prank(peer);
        runtime.handle(_inform());
        assertEq(runtime.installedBehaviorCount(), 1);
        assertEq(runtime.behaviorImplementation(idA), address(unknownKind));
    }

    function test_authorizeInboundCanDenyBeforeDispatch() public {
        GatedRuntime gated = new GatedRuntime(peer);
        gated.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(stranger);
        vm.expectRevert(InboundDenied.selector);
        gated.handle(_inform());
        assertEq(gated.installedBehaviorCount(), 1);
    }

    function test_authorizeInboundAllowsConfiguredCallerToDispatch() public {
        GatedRuntime gated = new GatedRuntime(peer);
        gated.installBehavior(idA, address(noneA));
        vm.prank(peer);
        gated.handle(_inform());
        assertEq(gated.installedBehaviorCount(), 0);
    }

    function test_engineWithoutRuntimeHandleDoesNotDecide() public {
        engineOnly.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(peer);
        engineOnly.handle(_inform());
        assertEq(engineOnly.installedBehaviorCount(), 1);
        assertEq(engineOnly.behaviorImplementation(idA), address(noneA));
    }

    function test_snapshotAgentHandleDoesNotNeedEngine() public {
        Agent bare = new Agent(address(0));
        vm.prank(peer);
        bare.handle(_inform());
    }

    function test_oneHandleIsOneStepDecideOnce() public {
        runtime.installCyclicBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 1
        );
        vm.prank(peer);
        runtime.handle(_inform());
        assertEq(runtime.installedBehaviorCount(), 1);
    }
}
