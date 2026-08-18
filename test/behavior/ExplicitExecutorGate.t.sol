pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ExplicitExecutorGate} from "../../src/behavior/ExplicitExecutorGate.sol";
import {BehaviorRuntime} from "../../src/behavior/BehaviorRuntime.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {Action, ActionLib, Kind} from "../../src/behavior/Action.sol";
import {BehaviorContext, Trigger} from "../../src/behavior/Context.sol";
import {Agent} from "../../src/core/Agent.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";

uint256 constant DEFAULT_STEP_GAS = 200_000;

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

contract GateAgent is ExplicitExecutorGate {
    uint256 internal immutable _stepGas;

    constructor(address trustedRelay_, address explicitExecutor_, uint256 stepGas_)
        Agent(trustedRelay_)
        ExplicitExecutorGate(explicitExecutor_)
    {
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
}

/// @dev Runtime without the gate: isolation oracle for no public Explicit.
contract RuntimeOnly is BehaviorRuntime {
    constructor() Agent(address(0)) {}

    function _behaviorStepGas() internal view override returns (uint256) {
        return DEFAULT_STEP_GAS;
    }

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }
}

contract ExplicitExecutorGateTest is Test {
    GateAgent internal gate;
    GateAgent internal denied;
    GateAgent internal split;
    RuntimeOnly internal runtimeOnly;
    NoneStrategy internal noneA;
    NoneStrategyB internal noneB;
    UnknownKindStrategy internal unknownKind;
    bytes32 internal idA;
    bytes32 internal idB;
    bytes32 internal idC;
    address internal executor;
    address internal stranger;
    address internal relay;
    bytes32 internal logical;

    function setUp() public {
        executor = makeAddr("executor");
        stranger = makeAddr("stranger");
        relay = makeAddr("relay");
        logical = keccak256("logical-sender");
        gate = new GateAgent(address(0), executor, DEFAULT_STEP_GAS);
        denied = new GateAgent(address(0), address(0), DEFAULT_STEP_GAS);
        split = new GateAgent(relay, executor, DEFAULT_STEP_GAS);
        runtimeOnly = new RuntimeOnly();
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
        m.conversationId = keccak256("gate-msg");
    }

    function test_rolesAreIndependentImmutables() public {
        assertEq(split.trustedRelay(), relay);
        assertEq(split.explicitExecutor(), executor);
        assertTrue(relay != executor);
        assertEq(denied.explicitExecutor(), address(0));
        assertEq(gate.explicitExecutor(), executor);
        assertEq(gate.trustedRelay(), address(0));
    }

    function test_authorizedExecutorRunsExplicitStep() public {
        gate.installBehavior(idA, address(noneA));
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 0);
    }

    function test_strangerRevertsBeforeDecide() public {
        gate.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(stranger);
        vm.expectRevert(ExplicitExecutorGate.UnauthorizedExplicitTrigger.selector);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 1);
        assertEq(gate.behaviorImplementation(idA), address(noneA));
    }

    function test_zeroExecutorDeniesEveryone() public {
        denied.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(executor);
        vm.expectRevert(ExplicitExecutorGate.UnauthorizedExplicitTrigger.selector);
        denied.dispatchExplicitTrigger();
        vm.prank(stranger);
        vm.expectRevert(ExplicitExecutorGate.UnauthorizedExplicitTrigger.selector);
        denied.dispatchExplicitTrigger();
        assertEq(denied.installedBehaviorCount(), 1);
    }

    function test_relayCannotExplicitOnlyByBeingRelay() public {
        split.installBehavior(idA, address(noneA));
        Message memory m = _inform();
        m.logicalSender = logical;
        vm.prank(relay);
        split.handle(m);
        assertEq(split.installedBehaviorCount(), 0);
        split.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(relay);
        vm.expectRevert(ExplicitExecutorGate.UnauthorizedExplicitTrigger.selector);
        split.dispatchExplicitTrigger();
        assertEq(split.installedBehaviorCount(), 1);
    }

    function test_executorDoesNotGainRelayPrivilege() public {
        Message memory m = _inform();
        m.logicalSender = logical;
        vm.prank(executor);
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        split.handle(m);
    }

    function test_executorMaySubmitNativeMessage() public {
        split.installBehavior(idA, address(noneA));
        vm.prank(executor);
        split.handle(_inform());
        assertEq(split.installedBehaviorCount(), 0);
    }

    function test_explicitContextIsExecutorNotPeer() public {
        ContextExpect expect =
            new ContextExpect(address(gate), executor, bytes32(0), uint8(Trigger.Explicit), true);
        gate.installBehavior(idA, address(expect));
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 0);
    }

    function test_unauthorizedCallerCannotConsumeOneShot() public {
        gate.installBehavior(idA, address(noneA));
        vm.prank(stranger);
        vm.expectRevert(ExplicitExecutorGate.UnauthorizedExplicitTrigger.selector);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 1);
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 0);
    }

    function test_cyclicRemainsAfterAuthorizedTrigger() public {
        gate.installCyclicBehavior(idA, address(noneA));
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 1);
        assertEq(gate.installedBehaviorAt(0), idA);
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 1);
        assertEq(gate.installedBehaviorAt(0), idA);
    }

    function test_behaviorFailureIsFailFast() public {
        gate.installBehavior(idA, address(unknownKind));
        gate.installCyclicBehavior(idB, address(noneB));
        vm.expectCall(
            address(noneB), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.prank(executor);
        vm.expectRevert(ActionLib.UnknownKind.selector);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 2);
    }

    function test_mixedPoolOneAuthorizedTriggerWalksAll() public {
        gate.installBehavior(idA, address(noneA));
        gate.installCyclicBehavior(idB, address(noneB));
        gate.installBehavior(idC, address(noneA));
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 1);
        assertEq(gate.installedBehaviorAt(0), idB);
    }

    function test_runtimeAloneHasNoPublicExplicitEndpoint() public {
        (bool ok,) = address(runtimeOnly).call(abi.encodeWithSignature("dispatchExplicitTrigger()"));
        assertFalse(ok);
        (ok,) = address(runtimeOnly)
            .call(abi.encodeWithSignature("dispatchExplicitTrigger(uint256)", DEFAULT_STEP_GAS));
        assertFalse(ok);
    }

    function test_callerCannotSupplyStepGas() public {
        gate.installBehavior(idA, address(noneA));
        (bool ok,) = address(gate)
            .call(abi.encodeWithSignature("dispatchExplicitTrigger(uint256)", uint256(1)));
        assertFalse(ok);
        assertEq(gate.installedBehaviorCount(), 1);
        vm.prank(executor);
        gate.dispatchExplicitTrigger();
        assertEq(gate.installedBehaviorCount(), 0);
    }
}
