pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Action, Kind} from "../../src/behavior/Action.sol";
import {BehaviorContext, ContextLib} from "../../src/behavior/Context.sol";
import {
    ExternalApplicationBehaviorHost
} from "../../src/behavior/ExternalApplicationBehaviorHost.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {EmbeddedApplicationBehaviorHost} from "../baselines/EmbeddedApplicationBehaviorHost.sol";

uint256 constant ARCH_STRATEGY_GAS = 160_000;

contract MatchedExternalStrategy is IExternalApplicationStrategy {
    uint256 public immutable delta;

    constructor(uint256 delta_) {
        delta = delta_;
    }

    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(delta);
    }
}

abstract contract MatchedEffectSink {
    uint256 public sink;

    function _applyMatched(bytes memory data) internal {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

contract MatchedExternalAgent is ExternalApplicationBehaviorHost, MatchedEffectSink {
    function install(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function run(bytes32 localId, BehaviorContext memory ctx) external {
        _runExternalBehavior(localId, ctx, ARCH_STRATEGY_GAS);
    }

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        _applyMatched(data);
    }
}

contract MatchedEmbeddedAgent is EmbeddedApplicationBehaviorHost, MatchedEffectSink {
    uint256 internal immutable _delta;

    constructor(uint256 delta_) {
        _delta = delta_;
    }

    function install(bytes32 localId) external {
        _installEmbeddedBehavior(localId);
    }

    function run(bytes32 localId, BehaviorContext memory ctx) external {
        _runEmbeddedBehavior(localId, ctx);
    }

    function _embeddedDecide(bytes32, BehaviorContext memory ctx)
        internal
        view
        override
        returns (Action memory a)
    {
        if (ctx.agent != address(this)) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(_delta);
    }

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        _applyMatched(data);
    }
}

/// @dev Paired engineering counterfactual. Not a BLADE release comparison and not JAAMAS evidence.
///      The same Context and Application Action reach the same trusted effect; only the decide
///      locus differs.
contract BehaviorArchitectureBenchmarkTest is Test {
    MatchedExternalAgent internal externalAgent;
    MatchedEmbeddedAgent internal embeddedAgent;
    MatchedExternalStrategy internal strategy;
    bytes32 internal id;
    address internal keeper;

    function setUp() public {
        strategy = new MatchedExternalStrategy(1);
        externalAgent = new MatchedExternalAgent();
        embeddedAgent = new MatchedEmbeddedAgent(1);
        id = keccak256("matched-behavior");
        keeper = makeAddr("architecture-keeper");
        externalAgent.install(id, address(strategy));
        embeddedAgent.install(id);
    }

    function testBenchmark_matchedApplicationExternal() public {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(externalAgent), keeper);
        uint256 beforeGas = gasleft();
        externalAgent.run(id, ctx);
        emit log_named_uint("behavior.arch.external.application.step", beforeGas - gasleft());
        assertEq(externalAgent.sink(), 1);
    }

    function testBenchmark_matchedApplicationEmbedded() public {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(embeddedAgent), keeper);
        uint256 beforeGas = gasleft();
        embeddedAgent.run(id, ctx);
        emit log_named_uint("behavior.arch.embedded.application.step", beforeGas - gasleft());
        assertEq(embeddedAgent.sink(), 1);
    }

    function test_semanticEffectMatchesAcrossLoci() public {
        BehaviorContext memory externalCtx =
            ContextLib.explicitTrigger(address(externalAgent), keeper);
        BehaviorContext memory embeddedCtx =
            ContextLib.explicitTrigger(address(embeddedAgent), keeper);
        externalAgent.run(id, externalCtx);
        embeddedAgent.run(id, embeddedCtx);
        assertEq(externalAgent.sink(), embeddedAgent.sink());
        assertEq(externalAgent.sink(), 1);
    }
}
