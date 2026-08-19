pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Action, ActionLib, Kind} from "../../src/behavior/Action.sol";
import {BehaviorActionDispatcher} from "../../src/behavior/BehaviorActionDispatcher.sol";
import {BehaviorEngine} from "../../src/behavior/BehaviorEngine.sol";
import {BehaviorContext, ContextLib, Trigger} from "../../src/behavior/Context.sol";
import {
    ExternalApplicationBehaviorHost
} from "../../src/behavior/ExternalApplicationBehaviorHost.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";

uint256 constant DISPATCH_STEP_GAS = 400_000;
uint256 constant DISPATCH_STRATEGY_GAS = 120_000;

contract ApplicationValueStrategy is IExternalApplicationStrategy {
    uint256 public immutable value;

    constructor(uint256 value_) {
        value = value_;
    }

    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(value);
    }
}

contract DispatchNoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = uint8(Kind.None);
    }
}

contract DispatchUnknownKindStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = type(uint8).max;
    }
}

contract BadApplicationPayloadStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = uint8(Kind.Application);
        a.data = hex"01";
    }
}

contract ActionDispatchEngine is BehaviorEngine {
    error InvalidApplicationPayload();

    uint256 public total;
    bytes32 public lastLocalId;
    uint8 public lastTrigger;
    address public lastTransportCaller;

    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runBehaviorStep(ctx, DISPATCH_STEP_GAS);
    }

    function runExternal(bytes32 localId, BehaviorContext memory ctx) external {
        _runExternalBehavior(localId, ctx, DISPATCH_STRATEGY_GAS);
    }

    function _onApplicationAction(bytes32 localId, BehaviorContext memory ctx, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert InvalidApplicationPayload();
        total += abi.decode(data, (uint256));
        lastLocalId = localId;
        lastTrigger = ctx.trigger;
        lastTransportCaller = ctx.transportCaller;
    }
}

contract DefaultDispatchHost is ExternalApplicationBehaviorHost {
    function install(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function run(bytes32 localId, BehaviorContext memory ctx) external {
        _runExternalBehavior(localId, ctx, DISPATCH_STRATEGY_GAS);
    }
}

contract BehaviorActionDispatchTest is Test {
    ActionDispatchEngine internal engine;
    DefaultDispatchHost internal defaultHost;
    ApplicationValueStrategy internal add7;
    DispatchNoneStrategy internal none;
    DispatchUnknownKindStrategy internal unknown;
    BadApplicationPayloadStrategy internal badPayload;
    address internal executor;
    bytes32 internal idA;
    bytes32 internal idB;

    function setUp() public {
        engine = new ActionDispatchEngine();
        defaultHost = new DefaultDispatchHost();
        add7 = new ApplicationValueStrategy(7);
        none = new DispatchNoneStrategy();
        unknown = new DispatchUnknownKindStrategy();
        badPayload = new BadApplicationPayloadStrategy();
        executor = makeAddr("action-executor");
        idA = keccak256("action-A");
        idB = keccak256("action-B");
    }

    function _explicit(address agent) internal view returns (BehaviorContext memory) {
        return ContextLib.explicitTrigger(agent, executor);
    }

    function test_applicationProposalRunsOnlyThroughTrustedHook() public {
        engine.installCyclic(idA, address(add7));
        engine.runExternal(idA, _explicit(address(engine)));
        assertEq(engine.total(), 7);
        assertEq(engine.lastLocalId(), idA);
        assertEq(engine.lastTrigger(), uint8(Trigger.Explicit));
        assertEq(engine.lastTransportCaller(), executor);
        assertEq(engine.behaviorImplementation(idA), address(add7));
    }

    function test_noneRemainsTrueNoOpAtDispatchBoundary() public {
        engine.installCyclic(idA, address(none));
        engine.runExternal(idA, _explicit(address(engine)));
        assertEq(engine.total(), 0);
        assertEq(engine.lastLocalId(), bytes32(0));
    }

    function test_applicationDefaultDeniesWhenLeafHasNoHandler() public {
        defaultHost.install(idA, address(add7));
        vm.expectRevert(BehaviorActionDispatcher.UnsupportedApplicationAction.selector);
        defaultHost.run(idA, _explicit(address(defaultHost)));
        assertEq(defaultHost.behaviorImplementation(idA), address(add7));
    }

    function test_leafRejectsMalformedApplicationPayload() public {
        engine.installCyclic(idA, address(badPayload));
        vm.expectRevert(ActionDispatchEngine.InvalidApplicationPayload.selector);
        engine.runExternal(idA, _explicit(address(engine)));
        assertEq(engine.total(), 0);
        assertEq(engine.behaviorImplementation(idA), address(badPayload));
    }

    function test_invalidKindRejectedBeforeTrustedHook() public {
        engine.installCyclic(idA, address(unknown));
        vm.expectRevert(ActionLib.UnknownKind.selector);
        engine.runExternal(idA, _explicit(address(engine)));
        assertEq(engine.total(), 0);
        assertEq(engine.lastLocalId(), bytes32(0));
    }

    function test_failFastRollsBackEarlierApplicationEffectAndCompletion() public {
        engine.installOneShot(idA, address(add7));
        engine.installOneShot(idB, address(unknown));
        vm.expectRevert(ActionLib.UnknownKind.selector);
        engine.runAll(_explicit(address(engine)));
        assertEq(engine.total(), 0);
        assertEq(engine.installedBehaviorCount(), 2);
        assertEq(engine.installedBehaviorAt(0), idA);
        assertEq(engine.installedBehaviorAt(1), idB);
        assertEq(engine.behaviorImplementation(idA), address(add7));
        assertEq(engine.behaviorImplementation(idB), address(unknown));
    }

    function test_successfulOneShotEffectCommitsThenCompletes() public {
        engine.installOneShot(idA, address(add7));
        engine.runAll(_explicit(address(engine)));
        assertEq(engine.total(), 7);
        assertEq(engine.installedBehaviorCount(), 0);
        assertEq(engine.behaviorImplementation(idA), address(0));
    }
}
