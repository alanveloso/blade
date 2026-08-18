pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    ExternalApplicationBehaviorHost
} from "../../src/behavior/ExternalApplicationBehaviorHost.sol";
import {BehaviorMembership} from "../../src/behavior/BehaviorMembership.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {Action, ActionLib, Kind} from "../../src/behavior/Action.sol";
import {BehaviorContext, ContextLib} from "../../src/behavior/Context.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";

/// @dev Harness-only. Production primitive has no hidden default stipend.
uint256 constant DEFAULT_EXTERNAL_BEHAVIOR_GAS = 100_000;

contract NoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) {
            revert("identity");
        }
        a.kind = uint8(Kind.None);
    }
}

contract MutatingStrategy {
    uint256 public written;

    function decide(BehaviorContext calldata) external returns (Action memory a) {
        written = 1;
        a.kind = uint8(Kind.None);
    }
}

contract RevertingStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory) {
        revert(string(new bytes(2048)));
    }
}

contract EmptyReturnStrategy {
    function decide(BehaviorContext calldata) external pure {
        assembly {
            return(0, 0)
        }
    }
}

contract MalformedReturnStrategy {
    function decide(BehaviorContext calldata) external pure returns (uint256) {
        return 1;
    }
}

contract UnknownKindStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = 1;
    }
}

contract NoneWithDataStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = uint8(Kind.None);
        a.data = hex"00";
    }
}

contract HugeReturnStrategy {
    function decide(BehaviorContext calldata) external pure {
        assembly {
            return(0, 2048)
        }
    }
}

contract LoopStrategy {
    function decide(BehaviorContext calldata) external pure {
        assembly {
            for {} 1 {} {}
        }
    }
}

contract RawReturnStrategy {
    bytes internal _payload;

    constructor(bytes memory payload) {
        _payload = payload;
    }

    function decide(BehaviorContext calldata) external view {
        bytes memory p = _payload;
        assembly {
            return(add(p, 32), mload(p))
        }
    }
}

contract RunAgent is Agent, ExternalApplicationBehaviorHost {
    uint256 public effects;

    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function runExternalBehavior(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        external
    {
        _runExternalBehavior(localId, ctx, gasBudget);
        effects++;
    }

    function runFromMessage(
        bytes32 localId,
        address transportCaller,
        Message calldata m,
        uint256 gasBudget
    ) external {
        _runExternalBehavior(
            localId, ContextLib.messageTrigger(address(this), transportCaller, m), gasBudget
        );
        effects++;
    }

    function catchRun(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        external
        returns (bytes memory reason, uint256 gasRemaining)
    {
        try this.runExternalBehavior(localId, ctx, gasBudget) {
            return ("", gasleft());
        } catch (bytes memory r) {
            return (r, gasleft());
        }
    }
}

contract RunRequest is RequestAgent, ExternalApplicationBehaviorHost {
    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function runExternalBehavior(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        external
    {
        _runExternalBehavior(localId, ctx, gasBudget);
    }
}

contract ExternalApplicationBehaviorTest is Test {
    RunAgent internal agent;
    RunAgent internal agentB;
    RunRequest internal requester;
    NoneStrategy internal noneStrategy;
    MutatingStrategy internal mutating;
    RevertingStrategy internal reverting;
    EmptyReturnStrategy internal emptyRet;
    MalformedReturnStrategy internal malformed;
    UnknownKindStrategy internal unknownKind;
    NoneWithDataStrategy internal noneData;
    HugeReturnStrategy internal hugeRet;
    LoopStrategy internal looping;

    bytes32 internal idX;
    bytes32 internal idY;
    address internal inbound;
    address internal keeper;

    function setUp() public {
        agent = new RunAgent();
        agentB = new RunAgent();
        requester = new RunRequest();
        noneStrategy = new NoneStrategy();
        mutating = new MutatingStrategy();
        reverting = new RevertingStrategy();
        emptyRet = new EmptyReturnStrategy();
        malformed = new MalformedReturnStrategy();
        unknownKind = new UnknownKindStrategy();
        noneData = new NoneWithDataStrategy();
        hugeRet = new HugeReturnStrategy();
        looping = new LoopStrategy();
        idX = keccak256("X");
        idY = keccak256("Y");
        inbound = makeAddr("inbound");
        keeper = makeAddr("keeper");
    }

    function _explicitCtx(address agentAddr) internal view returns (BehaviorContext memory) {
        return ContextLib.explicitTrigger(agentAddr, keeper);
    }

    function _run(RunAgent target, bytes32 id, BehaviorContext memory ctx) internal {
        target.runExternalBehavior(id, ctx, DEFAULT_EXTERNAL_BEHAVIOR_GAS);
    }

    function _expectInvalidReturn(bytes memory raw) internal {
        RawReturnStrategy s = new RawReturnStrategy(raw);
        agent.installBehavior(idX, address(s));
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_canonicalAbiEncodeNoneApplies() public {
        Action memory a;
        RawReturnStrategy s = new RawReturnStrategy(abi.encode(a));
        agent.installBehavior(idX, address(s));
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 1);
    }

    function test_honestNoneIsNoOp() public {
        agent.installBehavior(idX, address(noneStrategy));
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 1);
        assertEq(agent.trustedRelay(), address(0));
    }

    function test_honestNoneDoesNotWriteRequestOrCreateSession() public {
        bytes32 conversationId = keccak256("run-none");
        requester.installBehavior(idX, address(noneStrategy));
        requester.runExternalBehavior(
            idX, _explicitCtx(address(requester)), DEFAULT_EXTERNAL_BEHAVIOR_GAS
        );
        RequestAgent.Status memory st = requester.requestStatus(conversationId);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
    }

    function test_zeroGasBudgetRevertsBeforeStaticcall() public {
        agent.installBehavior(idX, address(noneStrategy));
        vm.expectCall(
            address(noneStrategy),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidGasBudget.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)), 0);
        assertEq(agent.effects(), 0);
    }

    function test_insufficientHostGasRevertsInvalidGasBudget() public {
        agent.installBehavior(idX, address(noneStrategy));
        vm.expectCall(
            address(noneStrategy),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidGasBudget.selector);
        agent.runExternalBehavior{gas: 80_000}(
            idX, _explicitCtx(address(agent)), DEFAULT_EXTERNAL_BEHAVIOR_GAS
        );
        assertEq(agent.effects(), 0);
    }

    function test_maxGasBudgetRevertsInvalidGasBudgetNotPanic() public {
        agent.installBehavior(idX, address(noneStrategy));
        vm.expectCall(
            address(noneStrategy),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidGasBudget.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)), type(uint256).max);
        assertEq(agent.effects(), 0);
    }

    function test_mutatingDecideFailsWithBladeError() public {
        agent.installBehavior(idX, address(mutating));
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalApplicationBehaviorHost.BehaviorExecutionFailed.selector,
                idX,
                address(mutating)
            )
        );
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(mutating.written(), 0);
        assertEq(agent.effects(), 0);
    }

    function test_strategyRevertDoesNotBubbleRawData() public {
        agent.installBehavior(idX, address(reverting));
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalApplicationBehaviorHost.BehaviorExecutionFailed.selector,
                idX,
                address(reverting)
            )
        );
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_emptyReturnRevertsInvalidStrategyReturn() public {
        agent.installBehavior(idX, address(emptyRet));
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_malformedReturnRevertsInvalidStrategyReturn() public {
        agent.installBehavior(idX, address(malformed));
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_truncatedAbiRevertsInvalidStrategyReturn() public {
        _expectInvalidReturn(new bytes(32));
    }

    function test_unwrappedTupleEncodingRevertsInvalidStrategyReturn() public {
        bytes memory raw = new bytes(96);
        assembly {
            mstore(add(raw, 64), 64)
        }
        _expectInvalidReturn(raw);
    }

    function test_invalidDynamicOffsetRevertsInvalidStrategyReturn() public {
        bytes memory raw = new bytes(128);
        assembly {
            mstore(add(raw, 32), 32)
            mstore(add(raw, 96), 0xFFFFFF)
        }
        _expectInvalidReturn(raw);
    }

    function test_impossibleBytesLengthRevertsInvalidStrategyReturn() public {
        bytes memory raw = new bytes(128);
        assembly {
            mstore(add(raw, 32), 32)
            mstore(add(raw, 96), 64)
            mstore(add(raw, 128), not(0))
        }
        _expectInvalidReturn(raw);
    }

    function test_trailingBytesRevertsInvalidStrategyReturn() public {
        Action memory a;
        _expectInvalidReturn(bytes.concat(abi.encode(a), hex"00"));
    }

    function test_kindWordOverflowRevertsInvalidStrategyReturn() public {
        bytes memory raw = new bytes(128);
        assembly {
            mstore(add(raw, 32), 32)
            mstore(add(raw, 64), 256)
            mstore(add(raw, 96), 64)
        }
        _expectInvalidReturn(raw);
    }

    function test_oversizedReturnDoesNotCopy() public {
        agent.installBehavior(idX, address(hugeRet));
        vm.expectRevert(ExternalApplicationBehaviorHost.StrategyReturnTooLarge.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_returnSizeAtCapPassesSizeBarrier() public {
        RawReturnStrategy s = new RawReturnStrategy(new bytes(1024));
        agent.installBehavior(idX, address(s));
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_returnSizeOnePastCapIsTooLarge() public {
        RawReturnStrategy s = new RawReturnStrategy(new bytes(1025));
        agent.installBehavior(idX, address(s));
        vm.expectRevert(ExternalApplicationBehaviorHost.StrategyReturnTooLarge.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_loopExhaustsBudgetHostStillEmitsBladeError() public {
        agent.installBehavior(idX, address(looping));
        (bytes memory reason, uint256 gasRemaining) =
            agent.catchRun(idX, _explicitCtx(address(agent)), DEFAULT_EXTERNAL_BEHAVIOR_GAS);
        assertEq(
            reason,
            abi.encodeWithSelector(
                ExternalApplicationBehaviorHost.BehaviorExecutionFailed.selector,
                idX,
                address(looping)
            )
        );
        assertGt(gasRemaining, 10_000);
        assertEq(agent.effects(), 0);
    }

    function test_unknownActionKindRevertsBeforeEffect() public {
        agent.installBehavior(idX, address(unknownKind));
        vm.expectRevert(ActionLib.UnknownKind.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_noneWithDataRevertsBeforeEffect() public {
        agent.installBehavior(idX, address(noneData));
        vm.expectRevert(ActionLib.NoneRequiresEmptyData.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_notInstalledReverts() public {
        vm.expectRevert(BehaviorMembership.NotInstalled.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
    }

    function test_installedEoaFailsAtRun() public {
        address eoa = makeAddr("eoa-strategy");
        agent.installBehavior(idX, eoa);
        vm.expectRevert(ExternalApplicationBehaviorHost.NoStrategyCode.selector);
        _run(agent, idX, _explicitCtx(address(agent)));
        assertEq(agent.behaviorImplementation(idX), eoa);
        assertEq(agent.effects(), 0);
    }

    function test_contextAgentMismatchRevertsBeforeStaticcall() public {
        agent.installBehavior(idX, address(noneStrategy));
        BehaviorContext memory ctx = _explicitCtx(address(agentB));
        vm.expectCall(
            address(noneStrategy),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        vm.expectRevert(BehaviorMembership.ContextAgentMismatch.selector);
        _run(agent, idX, ctx);
        assertEq(agent.effects(), 0);
    }

    function test_identityMessagePath() public {
        agent.installBehavior(idX, address(noneStrategy));
        Message memory m;
        m.performative = uint8(Performative.Inform);
        m.logicalSender = keccak256("logical");
        agent.runFromMessage(idX, inbound, m, DEFAULT_EXTERNAL_BEHAVIOR_GAS);
        assertEq(agent.effects(), 1);
    }

    function test_twoIdsSameStrategy() public {
        agent.installBehavior(idX, address(noneStrategy));
        agent.installBehavior(idY, address(noneStrategy));
        _run(agent, idX, _explicitCtx(address(agent)));
        _run(agent, idY, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 2);
    }

    function test_twoAgentsShareStrategyIndependently() public {
        agent.installBehavior(idX, address(noneStrategy));
        agentB.installBehavior(idX, address(noneStrategy));
        _run(agent, idX, _explicitCtx(address(agent)));
        _run(agentB, idX, _explicitCtx(address(agentB)));
        assertEq(agent.effects(), 1);
        assertEq(agentB.effects(), 1);
    }

    function test_handleDoesNotInvokeDecide() public {
        agent.installBehavior(idX, address(noneStrategy));
        vm.expectCall(
            address(noneStrategy),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        Message memory m;
        m.conversationId = keccak256("no-dispatch");
        agent.handle(m);
        assertEq(agent.effects(), 0);
    }

    function test_uninitializedContextRevertsBeforeStaticcall() public {
        agent.installBehavior(idX, address(noneStrategy));
        BehaviorContext memory ctx;
        vm.expectCall(
            address(noneStrategy),
            abi.encodeWithSelector(IExternalApplicationStrategy.decide.selector),
            0
        );
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        _run(agent, idX, ctx);
    }
}
