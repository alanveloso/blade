pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BehaviorEngine} from "../../src/behavior/BehaviorEngine.sol";
import {
    ExternalApplicationBehaviorHost
} from "../../src/behavior/ExternalApplicationBehaviorHost.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {Action, ActionLib, Kind} from "../../src/behavior/Action.sol";
import {BehaviorContext, ContextLib} from "../../src/behavior/Context.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";

/// @dev Harness-only. Production engine has no hidden default step budget.
uint256 constant DEFAULT_STEP_GAS = 200_000;

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

contract CapProbe is IExternalApplicationStrategy {
    uint256 public immutable maxGas;

    constructor(uint256 maxGas_) {
        maxGas = maxGas_;
    }

    function decide(BehaviorContext calldata) external view returns (Action memory a) {
        if (gasleft() > maxGas) {
            revert("overfunded");
        }
        a.kind = uint8(Kind.None);
    }
}

contract UnknownKindStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = 1;
    }
}

contract LoopStrategy {
    function decide(BehaviorContext calldata) external pure {
        assembly {
            for {} 1 {} {}
        }
    }
}

contract RevertingStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory) {
        revert("nope");
    }
}

contract HostOnly is ExternalApplicationBehaviorHost {
    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }
}

contract EngineAgent is Agent, BehaviorEngine {
    uint256 public effects;

    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function uninstallBehavior(bytes32 localId) external {
        _uninstallBehavior(localId);
    }

    function runBehaviorStep(BehaviorContext memory ctx, uint256 stepGas) external {
        _runBehaviorStep(ctx, stepGas);
        effects++;
    }

    function runFromMessage(address transportCaller, Message calldata m, uint256 stepGas) external {
        _runBehaviorStep(ContextLib.messageTrigger(address(this), transportCaller, m), stepGas);
        effects++;
    }

    function catchStep(BehaviorContext memory ctx, uint256 stepGas)
        external
        returns (bytes memory reason, uint256 gasRemaining)
    {
        try this.runBehaviorStep(ctx, stepGas) {
            return ("", gasleft());
        } catch (bytes memory r) {
            return (r, gasleft());
        }
    }
}

contract EngineRequest is RequestAgent, BehaviorEngine {
    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function runBehaviorStep(BehaviorContext memory ctx, uint256 stepGas) external {
        _runBehaviorStep(ctx, stepGas);
    }
}

contract BehaviorEngineTest is Test {
    EngineAgent internal agent;
    EngineRequest internal requester;
    HostOnly internal hostOnly;
    NoneStrategy internal noneA;
    NoneStrategyB internal noneB;
    UnknownKindStrategy internal unknownKind;
    LoopStrategy internal looping;
    RevertingStrategy internal reverting;

    bytes32 internal idA;
    bytes32 internal idB;
    bytes32 internal idC;
    address internal keeper;

    function setUp() public {
        agent = new EngineAgent();
        requester = new EngineRequest();
        hostOnly = new HostOnly();
        noneA = new NoneStrategy();
        noneB = new NoneStrategyB();
        unknownKind = new UnknownKindStrategy();
        looping = new LoopStrategy();
        reverting = new RevertingStrategy();
        idA = keccak256("A");
        idB = keccak256("B");
        idC = keccak256("C");
        keeper = makeAddr("keeper");
    }

    function _explicit() internal view returns (BehaviorContext memory) {
        return ContextLib.explicitTrigger(address(agent), keeper);
    }

    function test_emptyPoolIsNoOpEvenWithZeroOrMaxStepGas() public {
        agent.runBehaviorStep(_explicit(), 0);
        agent.runBehaviorStep(_explicit(), type(uint256).max);
        assertEq(agent.effects(), 2);
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function test_oneHonestNone() public {
        agent.installBehavior(idA, address(noneA));
        agent.runBehaviorStep(_explicit(), DEFAULT_STEP_GAS);
        assertEq(agent.effects(), 1);
        assertEq(agent.installedBehaviorCount(), 1);
        assertEq(agent.installedBehaviorAt(0), idA);
    }

    function test_twoHonestNoneInInstallOrder() public {
        agent.installBehavior(idA, address(noneA));
        agent.installBehavior(idB, address(noneB));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector)
        );
        vm.expectCall(
            address(noneB), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector)
        );
        agent.runBehaviorStep(_explicit(), DEFAULT_STEP_GAS);
        assertEq(agent.effects(), 1);
        assertEq(agent.installedBehaviorAt(0), idA);
        assertEq(agent.installedBehaviorAt(1), idB);
    }

    function test_equalSplitDoesNotOverfundStrategy() public {
        uint256 per = DEFAULT_STEP_GAS / 2;
        CapProbe probe = new CapProbe(per);
        agent.installBehavior(idA, address(probe));
        agent.installBehavior(idB, address(probe));
        agent.runBehaviorStep(_explicit(), DEFAULT_STEP_GAS);
        assertEq(agent.effects(), 1);
    }

    function test_failFastLoopDoesNotCallSecond() public {
        agent.installBehavior(idA, address(looping));
        agent.installBehavior(idB, address(noneB));
        vm.expectCall(
            address(noneB), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        (bytes memory reason, uint256 gasRemaining) = agent.catchStep(_explicit(), DEFAULT_STEP_GAS);
        assertEq(
            reason,
            abi.encodeWithSelector(
                ExternalApplicationBehaviorHost.BehaviorExecutionFailed.selector,
                idA,
                address(looping)
            )
        );
        assertGt(gasRemaining, 10_000);
        assertEq(agent.effects(), 0);
    }

    function test_failFastActionLibDoesNotCallSecond() public {
        agent.installBehavior(idA, address(unknownKind));
        agent.installBehavior(idB, address(reverting));
        vm.expectCall(
            address(reverting),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        vm.expectRevert(ActionLib.UnknownKind.selector);
        agent.runBehaviorStep(_explicit(), DEFAULT_STEP_GAS);
        assertEq(agent.effects(), 0);
    }

    function test_zeroStepGasWithBehaviorsReverts() public {
        agent.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.expectRevert(BehaviorEngine.InvalidStepGas.selector);
        agent.runBehaviorStep(_explicit(), 0);
        assertEq(agent.effects(), 0);
    }

    function test_perZeroRevertsInvalidStepGas() public {
        agent.installBehavior(idA, address(noneA));
        agent.installBehavior(idB, address(noneB));
        vm.expectRevert(BehaviorEngine.InvalidStepGas.selector);
        agent.runBehaviorStep(_explicit(), 1);
        assertEq(agent.effects(), 0);
    }

    function test_maxStepGasRevertsInvalidStepGasNotPanic() public {
        agent.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        vm.expectRevert(BehaviorEngine.InvalidStepGas.selector);
        agent.runBehaviorStep(_explicit(), type(uint256).max);
        assertEq(agent.effects(), 0);
    }

    function test_uninstallMiddlePreservesRelativeOrder() public {
        agent.installBehavior(idA, address(noneA));
        agent.installBehavior(idB, address(noneB));
        agent.installBehavior(idC, address(noneA));
        agent.uninstallBehavior(idB);
        assertEq(agent.installedBehaviorCount(), 2);
        assertEq(agent.installedBehaviorAt(0), idA);
        assertEq(agent.installedBehaviorAt(1), idC);
        assertEq(agent.behaviorImplementation(idB), address(0));
        vm.expectCall(
            address(noneB), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        agent.runBehaviorStep(_explicit(), DEFAULT_STEP_GAS);
        assertEq(agent.effects(), 1);
        agent.installBehavior(idB, address(noneB));
        assertEq(agent.installedBehaviorAt(0), idA);
        assertEq(agent.installedBehaviorAt(1), idC);
        assertEq(agent.installedBehaviorAt(2), idB);
    }

    function test_ninthEngineInstallReverts() public {
        for (uint256 i = 0; i < 8; ++i) {
            agent.installBehavior(bytes32(i + 1), address(noneA));
        }
        vm.expectRevert(BehaviorEngine.TooManyBehaviors.selector);
        agent.installBehavior(bytes32(uint256(9)), address(noneA));
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function test_hostWithoutEngineHasNoCap8() public {
        for (uint256 i = 0; i < 9; ++i) {
            hostOnly.installBehavior(bytes32(i + 1), address(noneA));
        }
        assertEq(hostOnly.behaviorImplementation(bytes32(uint256(9))), address(noneA));
    }

    function test_messageContextRunsInstalled() public {
        agent.installBehavior(idA, address(noneA));
        Message memory m;
        m.performative = uint8(Performative.Inform);
        m.logicalSender = keccak256("logical");
        agent.runFromMessage(makeAddr("inbound"), m, DEFAULT_STEP_GAS);
        assertEq(agent.effects(), 1);
    }

    function test_handleDoesNotInvokeDecide() public {
        agent.installBehavior(idA, address(noneA));
        vm.expectCall(
            address(noneA), abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector), 0
        );
        Message memory m;
        m.conversationId = keccak256("no-dispatch");
        agent.handle(m);
        assertEq(agent.effects(), 0);
    }

    function test_noneStepDoesNotWriteRequestSession() public {
        bytes32 conversationId = keccak256("engine-none");
        requester.installBehavior(idA, address(noneA));
        requester.runBehaviorStep(
            ContextLib.explicitTrigger(address(requester), keeper), DEFAULT_STEP_GAS
        );
        RequestAgent.Status memory st = requester.requestStatus(conversationId);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
    }

    function test_uninitializedContextRevertsWhenPoolNonEmpty() public {
        agent.installBehavior(idA, address(noneA));
        BehaviorContext memory ctx;
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        agent.runBehaviorStep(ctx, DEFAULT_STEP_GAS);
    }
}
