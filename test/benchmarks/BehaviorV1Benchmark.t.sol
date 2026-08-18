pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BehaviorEngine} from "../../src/behavior/BehaviorEngine.sol";
import {BehaviorContext, ContextLib} from "../../src/behavior/Context.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {Action, Kind} from "../../src/behavior/Action.sol";

uint256 constant BENCH_STEP_GAS = 1_600_000;

contract BenchmarkNoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.None);
    }
}

contract BehaviorBenchmarkAgent is BehaviorEngine {
    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runBehaviorStep(ctx, BENCH_STEP_GAS);
    }

    function runAtMost(BehaviorContext memory ctx, uint256 maxToRun) external {
        _runBehaviorStepAtMost(ctx, BENCH_STEP_GAS, maxToRun);
    }
}

/// @dev Engineering baseline only. Values are not publication evidence until run under a frozen
///      campaign/toolchain. Use `scripts/behavior-optimization-baseline.sh`.
contract BehaviorV1BenchmarkTest is Test {
    BehaviorBenchmarkAgent internal agent;
    BenchmarkNoneStrategy internal strategy;
    address internal keeper;

    function setUp() public {
        agent = new BehaviorBenchmarkAgent();
        strategy = new BenchmarkNoneStrategy();
        keeper = makeAddr("benchmark-keeper");
    }

    function testBenchmark_walkAllOneShot1() public {
        _installOneShot(1);
        _measureAll("behavior.walkAll.oneShot.n1");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllOneShot2() public {
        _installOneShot(2);
        _measureAll("behavior.walkAll.oneShot.n2");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllOneShot4() public {
        _installOneShot(4);
        _measureAll("behavior.walkAll.oneShot.n4");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllOneShot8() public {
        _installOneShot(8);
        _measureAll("behavior.walkAll.oneShot.n8");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllCyclic1() public {
        _installCyclic(1);
        _measureAll("behavior.walkAll.cyclic.n1");
        assertEq(agent.installedBehaviorCount(), 1);
    }

    function testBenchmark_walkAllCyclic2() public {
        _installCyclic(2);
        _measureAll("behavior.walkAll.cyclic.n2");
        assertEq(agent.installedBehaviorCount(), 2);
    }

    function testBenchmark_walkAllCyclic4() public {
        _installCyclic(4);
        _measureAll("behavior.walkAll.cyclic.n4");
        assertEq(agent.installedBehaviorCount(), 4);
    }

    function testBenchmark_walkAllCyclic8() public {
        _installCyclic(8);
        _measureAll("behavior.walkAll.cyclic.n8");
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_atMost1Of8Cyclic() public {
        _installCyclic(8);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAtMost(ctx, 1);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("behavior.atMost1.cyclic.n8", used);
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_mixed8() public {
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("mixed-", i));
            if (i % 2 == 0) {
                agent.installOneShot(id, address(strategy));
            } else {
                agent.installCyclic(id, address(strategy));
            }
        }
        _measureAll("behavior.walkAll.mixed.n8");
        assertEq(agent.installedBehaviorCount(), 4);
    }

    function _installOneShot(uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) {
            agent.installOneShot(keccak256(abi.encodePacked("one-shot-", i)), address(strategy));
        }
    }

    function _installCyclic(uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) {
            agent.installCyclic(keccak256(abi.encodePacked("cyclic-", i)), address(strategy));
        }
    }

    function _measureAll(string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint(label, used);
    }
}
