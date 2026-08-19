pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EmbeddedApplicationBehaviorHost} from "../baselines/EmbeddedApplicationBehaviorHost.sol";
import {BehaviorEngine} from "../../src/behavior/BehaviorEngine.sol";
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

uint256 constant DEFAULT_EXTERNAL_BEHAVIOR_GAS = 100_000;
uint256 constant DEFAULT_STEP_GAS = 200_000;

contract NoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) {
            revert("identity");
        }
        a.kind = uint8(Kind.None);
    }
}

contract ScriptedEmbedded is Agent, EmbeddedApplicationBehaviorHost {
    uint256 public effects;
    uint256 public applicationTotal;
    mapping(bytes32 => uint8) internal _kind;
    mapping(bytes32 => bytes) internal _data;
    mapping(bytes32 => bool) internal _revertHook;

    constructor() Agent(address(0)) {}

    function installEmbeddedBehavior(bytes32 localId) external {
        _installEmbeddedBehavior(localId);
    }

    function uninstallEmbeddedBehavior(bytes32 localId) external {
        _uninstallEmbeddedBehavior(localId);
    }

    function script(bytes32 localId, uint8 kind, bytes calldata data, bool revertHook) external {
        _kind[localId] = kind;
        _data[localId] = data;
        _revertHook[localId] = revertHook;
    }

    function runEmbeddedBehavior(bytes32 localId, BehaviorContext memory ctx) external {
        _runEmbeddedBehavior(localId, ctx);
        effects++;
    }

    function _embeddedDecide(bytes32 localId, BehaviorContext memory ctx)
        internal
        view
        override
        returns (Action memory a)
    {
        if (ctx.agent != address(this)) {
            revert("identity");
        }
        if (_revertHook[localId]) {
            revert("hook");
        }
        a.kind = _kind[localId];
        a.data = _data[localId];
    }

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        applicationTotal += abi.decode(data, (uint256));
    }
}

contract DualLocusAgent is Agent, BehaviorEngine, EmbeddedApplicationBehaviorHost {
    uint256 public embeddedEffects;
    uint256 public stepEffects;

    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installEmbeddedBehavior(bytes32 localId) external {
        _installEmbeddedBehavior(localId);
    }

    function runBehaviorStep(BehaviorContext memory ctx, uint256 stepGas) external {
        _runBehaviorStep(ctx, stepGas);
        stepEffects++;
    }

    function runEmbeddedBehavior(bytes32 localId, BehaviorContext memory ctx) external {
        _runEmbeddedBehavior(localId, ctx);
        embeddedEffects++;
    }

    function runExternalBehavior(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        external
    {
        _runExternalBehavior(localId, ctx, gasBudget);
    }

    function _embeddedDecide(bytes32 localId, BehaviorContext memory)
        internal
        view
        override
        returns (Action memory a)
    {
        if (localId == keccak256("hook-marker")) {
            revert("embedded-hook");
        }
        a.kind = uint8(Kind.None);
    }
}

contract EmbeddedRequest is RequestAgent, EmbeddedApplicationBehaviorHost {
    constructor() Agent(address(0)) {}

    function installEmbeddedBehavior(bytes32 localId) external {
        _installEmbeddedBehavior(localId);
    }

    function runEmbeddedBehavior(bytes32 localId, BehaviorContext memory ctx) external {
        _runEmbeddedBehavior(localId, ctx);
    }

    function _embeddedDecide(bytes32, BehaviorContext memory)
        internal
        pure
        override
        returns (Action memory a)
    {
        a.kind = uint8(Kind.None);
    }
}

contract EmbeddedApplicationBehaviorTest is Test {
    ScriptedEmbedded internal embedded;
    DualLocusAgent internal dual;
    EmbeddedRequest internal requester;
    NoneStrategy internal noneStrategy;
    bytes32 internal idA;
    bytes32 internal idB;
    address internal keeper;

    function setUp() public {
        embedded = new ScriptedEmbedded();
        dual = new DualLocusAgent();
        requester = new EmbeddedRequest();
        noneStrategy = new NoneStrategy();
        idA = keccak256("A");
        idB = keccak256("B");
        keeper = makeAddr("keeper");
    }

    function _explicit(address agentAddr) internal view returns (BehaviorContext memory) {
        return ContextLib.explicitTrigger(agentAddr, keeper);
    }

    function test_installLookupUninstall() public {
        vm.expectEmit(true, false, false, true, address(embedded));
        emit EmbeddedApplicationBehaviorHost.EmbeddedBehaviorInstalled(idA);
        embedded.installEmbeddedBehavior(idA);
        assertTrue(embedded.embeddedBehaviorInstalled(idA));
        vm.expectEmit(true, false, false, true, address(embedded));
        emit EmbeddedApplicationBehaviorHost.EmbeddedBehaviorUninstalled(idA);
        embedded.uninstallEmbeddedBehavior(idA);
        assertFalse(embedded.embeddedBehaviorInstalled(idA));
    }

    function test_zeroLocalIdReverts() public {
        vm.expectRevert(BehaviorMembership.InvalidLocalId.selector);
        embedded.installEmbeddedBehavior(bytes32(0));
    }

    function test_duplicateInstallReverts() public {
        embedded.installEmbeddedBehavior(idA);
        vm.expectRevert(BehaviorMembership.AlreadyInstalled.selector);
        embedded.installEmbeddedBehavior(idA);
    }

    function test_honestNoneIsNoOp() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        assertEq(embedded.effects(), 1);
    }

    function test_applicationActionUsesSameTrustedDispatchBoundary() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, uint8(Kind.Application), abi.encode(uint256(5)), false);
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        assertEq(embedded.applicationTotal(), 5);
        assertEq(embedded.effects(), 1);
    }

    function test_pairedNoneSameActionAndEffect() public {
        dual.installBehavior(idA, address(noneStrategy));
        dual.installEmbeddedBehavior(idB);
        BehaviorContext memory ctx = _explicit(address(dual));
        dual.runExternalBehavior(idA, ctx, DEFAULT_EXTERNAL_BEHAVIOR_GAS);
        dual.runEmbeddedBehavior(idB, ctx);
        assertEq(dual.embeddedEffects(), 1);
        assertEq(dual.behaviorImplementation(idA), address(noneStrategy));
        assertTrue(dual.embeddedBehaviorInstalled(idB));
    }

    function test_unknownKindRevertsActionLib() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, type(uint8).max, "", false);
        vm.expectRevert(ActionLib.UnknownKind.selector);
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        assertEq(embedded.effects(), 0);
    }

    function test_noneWithDataRevertsActionLib() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, uint8(Kind.None), hex"00", false);
        vm.expectRevert(ActionLib.NoneRequiresEmptyData.selector);
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        assertEq(embedded.effects(), 0);
    }

    function test_notInstalledDoesNotCallHook() public {
        embedded.script(idA, 0, "", true);
        vm.expectRevert(BehaviorMembership.NotInstalled.selector);
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        assertEq(embedded.effects(), 0);
    }

    function test_hookRevertPropagatesNaturally() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, 0, "", true);
        vm.expectRevert(bytes("hook"));
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        assertEq(embedded.effects(), 0);
    }

    function test_invalidContextRejectedBeforeDecide() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, 0, "", true);
        BehaviorContext memory ctx;
        vm.expectRevert(ContextLib.UninitializedTrigger.selector);
        embedded.runEmbeddedBehavior(idA, ctx);
        assertEq(embedded.effects(), 0);
    }

    function test_contextAgentMismatchRejectedBeforeDecide() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, 0, "", true);
        vm.expectRevert(BehaviorMembership.ContextAgentMismatch.selector);
        embedded.runEmbeddedBehavior(idA, _explicit(address(dual)));
        assertEq(embedded.effects(), 0);
    }

    function test_twoLocalIdsDistinctDecisions() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.installEmbeddedBehavior(idB);
        embedded.script(idA, uint8(Kind.None), "", false);
        embedded.script(idB, type(uint8).max, "", false);
        embedded.runEmbeddedBehavior(idA, _explicit(address(embedded)));
        vm.expectRevert(ActionLib.UnknownKind.selector);
        embedded.runEmbeddedBehavior(idB, _explicit(address(embedded)));
        assertEq(embedded.effects(), 1);
    }

    function test_handleDoesNotInvokeEmbeddedDecide() public {
        embedded.installEmbeddedBehavior(idA);
        embedded.script(idA, 0, "", true);
        Message memory m;
        m.conversationId = keccak256("no-dispatch");
        embedded.handle(m);
        assertEq(embedded.effects(), 0);
        assertTrue(embedded.embeddedBehaviorInstalled(idA));
    }

    function test_noneDoesNotWriteRequestSession() public {
        bytes32 conversationId = keccak256("embedded-none");
        requester.installEmbeddedBehavior(idA);
        requester.runEmbeddedBehavior(idA, _explicit(address(requester)));
        RequestAgent.Status memory st = requester.requestStatus(conversationId);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
    }

    function test_engineStepDoesNotRunEmbeddedHook() public {
        bytes32 hookId = keccak256("hook-marker");
        dual.installEmbeddedBehavior(hookId);
        dual.installBehavior(idA, address(noneStrategy));
        dual.runBehaviorStep(_explicit(address(dual)), DEFAULT_STEP_GAS);
        assertEq(dual.stepEffects(), 1);
        assertEq(dual.embeddedEffects(), 0);
        vm.expectRevert(bytes("embedded-hook"));
        dual.runEmbeddedBehavior(hookId, _explicit(address(dual)));
    }

    function test_snapshotAgentHasNoEmbeddedApi() public {
        Agent bare = new Agent(address(0));
        (bool ok,) =
            address(bare).call(abi.encodeWithSignature("installEmbeddedBehavior(bytes32)", idA));
        assertFalse(ok);
    }
}
