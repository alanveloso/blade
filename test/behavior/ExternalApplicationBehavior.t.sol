pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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

contract RunAgent is Agent, ExternalApplicationBehaviorHost {
    uint256 public effects;

    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function runExternalBehavior(bytes32 localId, BehaviorContext memory ctx) external {
        _runExternalBehavior(localId, ctx);
        effects++;
    }

    function runFromMessage(bytes32 localId, address transportCaller, Message calldata m) external {
        _runExternalBehavior(localId, ContextLib.messageTrigger(address(this), transportCaller, m));
        effects++;
    }
}

contract RunRequest is RequestAgent, ExternalApplicationBehaviorHost {
    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function runExternalBehavior(bytes32 localId, BehaviorContext memory ctx) external {
        _runExternalBehavior(localId, ctx);
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
        idX = keccak256("X");
        idY = keccak256("Y");
        inbound = makeAddr("inbound");
        keeper = makeAddr("keeper");
    }

    function _explicitCtx(address agentAddr) internal view returns (BehaviorContext memory) {
        return ContextLib.explicitTrigger(agentAddr, keeper);
    }

    function test_honestNoneIsNoOp() public {
        agent.installBehavior(idX, address(noneStrategy));
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 1);
        assertEq(agent.trustedRelay(), address(0));
    }

    function test_honestNoneDoesNotWriteRequestOrCreateSession() public {
        bytes32 conversationId = keccak256("run-none");
        requester.installBehavior(idX, address(noneStrategy));
        requester.runExternalBehavior(idX, _explicitCtx(address(requester)));
        RequestAgent.Status memory st = requester.requestStatus(conversationId);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
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
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
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
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_emptyReturnRevertsInvalidStrategyReturn() public {
        agent.installBehavior(idX, address(emptyRet));
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_malformedReturnReverts() public {
        agent.installBehavior(idX, address(malformed));
        vm.expectRevert();
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_unknownActionKindRevertsBeforeEffect() public {
        agent.installBehavior(idX, address(unknownKind));
        vm.expectRevert(ActionLib.UnknownKind.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_noneWithDataRevertsBeforeEffect() public {
        agent.installBehavior(idX, address(noneData));
        vm.expectRevert(ActionLib.NoneRequiresEmptyData.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 0);
    }

    function test_notInstalledReverts() public {
        vm.expectRevert(ExternalApplicationBehaviorHost.NotInstalled.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
    }

    function test_installedEoaFailsAtRun() public {
        address eoa = makeAddr("eoa-strategy");
        agent.installBehavior(idX, eoa);
        vm.expectRevert(ExternalApplicationBehaviorHost.NoStrategyCode.selector);
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
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
        vm.expectRevert(ExternalApplicationBehaviorHost.ContextAgentMismatch.selector);
        agent.runExternalBehavior(idX, ctx);
        assertEq(agent.effects(), 0);
    }

    function test_identityMessagePath() public {
        agent.installBehavior(idX, address(noneStrategy));
        Message memory m;
        m.performative = uint8(Performative.Inform);
        m.logicalSender = keccak256("logical");
        agent.runFromMessage(idX, inbound, m);
        assertEq(agent.effects(), 1);
    }

    function test_twoIdsSameStrategy() public {
        agent.installBehavior(idX, address(noneStrategy));
        agent.installBehavior(idY, address(noneStrategy));
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        agent.runExternalBehavior(idY, _explicitCtx(address(agent)));
        assertEq(agent.effects(), 2);
    }

    function test_twoAgentsShareStrategyIndependently() public {
        agent.installBehavior(idX, address(noneStrategy));
        agentB.installBehavior(idX, address(noneStrategy));
        agent.runExternalBehavior(idX, _explicitCtx(address(agent)));
        agentB.runExternalBehavior(idX, _explicitCtx(address(agentB)));
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
        agent.runExternalBehavior(idX, ctx);
    }
}
