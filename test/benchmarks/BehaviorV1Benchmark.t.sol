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

contract BenchmarkApplicationStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(uint256(1));
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

    function resumeIndex() external view returns (uint256) {
        return _resumeIndex;
    }
}

contract BehaviorActionBenchmarkAgent is BehaviorBenchmarkAgent {
    uint256 public sink;

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

/// @dev Engineering control baseline only. Values are not publication evidence until run under a
///      frozen campaign/toolchain. None and real Application rows are deliberately separated.
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
        _measureAll("behavior.none.walkAll.oneShot.n1");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllOneShot2() public {
        _installOneShot(2);
        _measureAll("behavior.none.walkAll.oneShot.n2");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllOneShot4() public {
        _installOneShot(4);
        _measureAll("behavior.none.walkAll.oneShot.n4");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllOneShot8() public {
        _installOneShot(8);
        _measureAll("behavior.none.walkAll.oneShot.n8");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_walkAllCyclic1() public {
        _installCyclic(1);
        _measureAll("behavior.none.walkAll.cyclic.n1");
        assertEq(agent.installedBehaviorCount(), 1);
    }

    function testBenchmark_walkAllCyclic2() public {
        _installCyclic(2);
        _measureAll("behavior.none.walkAll.cyclic.n2");
        assertEq(agent.installedBehaviorCount(), 2);
    }

    function testBenchmark_walkAllCyclic4() public {
        _installCyclic(4);
        _measureAll("behavior.none.walkAll.cyclic.n4");
        assertEq(agent.installedBehaviorCount(), 4);
    }

    function testBenchmark_walkAllCyclic8() public {
        _installCyclic(8);
        _measureAll("behavior.none.walkAll.cyclic.n8");
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_atMost1Of8Cyclic() public {
        _installCyclic(8);
        _measureAtMost("behavior.none.atMost1.cyclic.n8.cold", 1);
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_atMost1Of8CyclicCursorCycle() public {
        _installCyclic(8);
        for (uint256 i = 0; i < 9; ++i) {
            _measureAtMost(_cursorLabel(i), 1);
        }
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_storageTrafficOneShot8() public {
        _installOneShot(8);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        vm.record();
        agent.runAll(ctx);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(agent));
        emit log_named_uint("behavior.none.storage.oneShot.n8.readSlots", reads.length);
        emit log_named_uint("behavior.none.storage.oneShot.n8.writeSlots", writes.length);
    }

    function testBenchmark_storageTrafficCyclic8() public {
        _installCyclic(8);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        vm.record();
        agent.runAll(ctx);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(agent));
        emit log_named_uint("behavior.none.storage.cyclic.n8.readSlots", reads.length);
        emit log_named_uint("behavior.none.storage.cyclic.n8.writeSlots", writes.length);
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
        _measureAll("behavior.none.walkAll.mixed.n8");
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

    function _measureAtMost(string memory label, uint256 maxToRun) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAtMost(ctx, maxToRun);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint(label, used);
    }

    function _cursorLabel(uint256 i) private pure returns (string memory) {
        if (i == 0) return "behavior.none.atMost1.cursor.step1.zero-to-nonzero";
        if (i == 1) return "behavior.none.atMost1.cursor.step2.nonzero-to-nonzero";
        if (i == 2) return "behavior.none.atMost1.cursor.step3.nonzero-to-nonzero";
        if (i == 3) return "behavior.none.atMost1.cursor.step4.nonzero-to-nonzero";
        if (i == 4) return "behavior.none.atMost1.cursor.step5.nonzero-to-nonzero";
        if (i == 5) return "behavior.none.atMost1.cursor.step6.nonzero-to-nonzero";
        if (i == 6) return "behavior.none.atMost1.cursor.step7.nonzero-to-nonzero";
        if (i == 7) return "behavior.none.atMost1.cursor.step8.nonzero-to-zero";
        return "behavior.none.atMost1.cursor.step9.zero-to-nonzero";
    }
}

contract BehaviorActionBenchmarkTest is Test {
    BehaviorActionBenchmarkAgent internal agent;
    BenchmarkApplicationStrategy internal strategy;
    address internal keeper;

    function setUp() public {
        agent = new BehaviorActionBenchmarkAgent();
        strategy = new BenchmarkApplicationStrategy();
        keeper = makeAddr("benchmark-action-keeper");
    }

    function testBenchmarkAction_walkAllCyclic8() public {
        _installCyclic(8);
        _measureAll("behavior.application.walkAll.cyclic.n8");
        assertEq(agent.sink(), 8);
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmarkAction_walkAllOneShot8() public {
        _installOneShot(8);
        _measureAll("behavior.application.walkAll.oneShot.n8");
        assertEq(agent.sink(), 8);
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmarkAction_mixed8() public {
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("application-mixed-", i));
            if (i % 2 == 0) agent.installOneShot(id, address(strategy));
            else agent.installCyclic(id, address(strategy));
        }
        _measureAll("behavior.application.walkAll.mixed.n8");
        assertEq(agent.sink(), 8);
        assertEq(agent.installedBehaviorCount(), 4);
    }

    function testBenchmarkAction_atMost1Of8CyclicColdAndSteady() public {
        _installCyclic(8);
        _measureAtMost("behavior.application.atMost1.cyclic.n8.cold", 1);
        _measureAtMost("behavior.application.atMost1.cyclic.n8.steady", 1);
        assertEq(agent.sink(), 2);
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function _installOneShot(uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) {
            agent.installOneShot(
                keccak256(abi.encodePacked("application-one-shot-", i)), address(strategy)
            );
        }
    }

    function _installCyclic(uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) {
            agent.installCyclic(
                keccak256(abi.encodePacked("application-cyclic-", i)), address(strategy)
            );
        }
    }

    function _measureAll(string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        emit log_named_uint(label, beforeGas - gasleft());
    }

    function _measureAtMost(string memory label, uint256 maxToRun) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAtMost(ctx, maxToRun);
        emit log_named_uint(label, beforeGas - gasleft());
    }
}
