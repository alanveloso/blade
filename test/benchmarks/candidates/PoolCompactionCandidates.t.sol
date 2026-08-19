pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Action, Kind} from "../../../src/behavior/Action.sol";
import {BehaviorEngine} from "../../../src/behavior/BehaviorEngine.sol";
import {BehaviorContext, ContextLib} from "../../../src/behavior/Context.sol";
import {IExternalApplicationStrategy} from "../../../src/behavior/IExternalApplicationStrategy.sol";

uint256 constant CANDIDATE_STEP_GAS = 1_600_000;

contract CandidateNoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.None);
    }
}

contract CandidateApplicationStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(uint256(1));
    }
}

/// @dev Experimental C4 only. Product `src/` remains the control.
///      Decisions still use the full snapshot in insertion order; completion compacts survivors
///      once, preserving their relative order, instead of shift+pop per completed OneShot.
abstract contract BatchCompactionBehaviorEngine is BehaviorEngine {
    function _runBehaviorStepBatch(BehaviorContext memory ctx, uint256 stepGas) internal {
        uint256 n = _orderedBehaviorIds.length;
        if (n == 0) return;
        if (stepGas == 0) revert InvalidStepGas();
        uint256 per = stepGas / n;
        if (per == 0) revert InvalidStepGas();

        uint256 remaining = gasleft();
        if (remaining <= ENGINE_OVERHEAD) revert InvalidStepGas();
        uint256 usable = remaining - ENGINE_OVERHEAD;
        if (POST_CALL_OVERHEAD > type(uint256).max / n) revert InvalidStepGas();
        uint256 hostReserve = n * POST_CALL_OVERHEAD;
        if (usable <= hostReserve || stepGas > usable - hostReserve) revert InvalidStepGas();

        bytes32[] memory snapshot = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            snapshot[i] = _orderedBehaviorIds[i];
        }
        for (uint256 i = 0; i < n; ++i) {
            _runExternalBehavior(snapshot[i], ctx, per);
        }

        _batchCompletePreservingOrder(snapshot);
    }

    function _batchCompletePreservingOrder(bytes32[] memory snapshot) private {
        uint256 writeIndex;
        for (uint256 i = 0; i < snapshot.length; ++i) {
            bytes32 localId = snapshot[i];
            if (_completesAfterSuccess(localId)) {
                address implementation = _behaviors[localId];
                if (implementation == address(0)) revert NotInstalled();
                delete _behaviors[localId];
                delete _cyclic[localId];
                emit BehaviorUninstalled(localId, implementation);
            } else {
                if (writeIndex != i) _orderedBehaviorIds[writeIndex] = localId;
                ++writeIndex;
            }
        }
        while (_orderedBehaviorIds.length > writeIndex) _orderedBehaviorIds.pop();
    }
}

/// @dev Experimental C5 only. Intentionally changes future selection order.
///      It is a semantic lower-bound candidate, not an equivalent product optimization.
abstract contract SwapAndPopBehaviorEngine is BehaviorEngine {
    function _uninstallBehavior(bytes32 localId) internal virtual override {
        address implementation = _behaviors[localId];
        if (implementation == address(0)) revert NotInstalled();
        delete _behaviors[localId];
        emit BehaviorUninstalled(localId, implementation);

        uint256 n = _orderedBehaviorIds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_orderedBehaviorIds[i] == localId) {
                uint256 last = n - 1;
                if (i != last) _orderedBehaviorIds[i] = _orderedBehaviorIds[last];
                _orderedBehaviorIds.pop();
                delete _cyclic[localId];
                return;
            }
        }
        revert NotInstalled();
    }
}

contract BatchCandidateAgent is BatchCompactionBehaviorEngine {
    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runBehaviorStepBatch(ctx, CANDIDATE_STEP_GAS);
    }

    function runAtMost(BehaviorContext memory ctx, uint256 maxToRun) external {
        _runBehaviorStepAtMost(ctx, CANDIDATE_STEP_GAS, maxToRun);
    }
}

contract SwapCandidateAgent is SwapAndPopBehaviorEngine {
    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runBehaviorStep(ctx, CANDIDATE_STEP_GAS);
    }

    function runAtMost(BehaviorContext memory ctx, uint256 maxToRun) external {
        _runBehaviorStepAtMost(ctx, CANDIDATE_STEP_GAS, maxToRun);
    }
}

contract BatchActionCandidateAgent is BatchCandidateAgent {
    uint256 public sink;

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

contract SwapActionCandidateAgent is SwapCandidateAgent {
    uint256 public sink;

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

contract PoolCompactionCandidatesTest is Test {
    CandidateNoneStrategy internal strategy;
    CandidateApplicationStrategy internal application;
    address internal keeper;

    function setUp() public {
        strategy = new CandidateNoneStrategy();
        application = new CandidateApplicationStrategy();
        keeper = makeAddr("pool-candidate-keeper");
    }

    function testBenchmark_batch_walkAllCyclic8() public {
        BatchCandidateAgent agent = new BatchCandidateAgent();
        _installBatch(agent, 8, false);
        _measureBatch(agent, "candidate.batch.none.walkAll.cyclic.n8");
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_batch_walkAllOneShot8() public {
        BatchCandidateAgent agent = new BatchCandidateAgent();
        _installBatch(agent, 8, true);
        _measureBatch(agent, "candidate.batch.none.walkAll.oneShot.n8");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_batch_mixed8() public {
        BatchCandidateAgent agent = new BatchCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("batch-mixed-", i));
            if (i % 2 == 0) agent.installOneShot(id, address(strategy));
            else agent.installCyclic(id, address(strategy));
        }
        _measureBatch(agent, "candidate.batch.none.walkAll.mixed.n8");
        assertEq(agent.installedBehaviorCount(), 4);
    }

    function testBenchmark_batch_atMost1Of8Cyclic() public {
        BatchCandidateAgent agent = new BatchCandidateAgent();
        _installBatch(agent, 8, false);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAtMost(ctx, 1);
        emit log_named_uint("candidate.batch.none.atMost1.cyclic.n8", beforeGas - gasleft());
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_batch_storageTrafficOneShot8() public {
        BatchCandidateAgent agent = new BatchCandidateAgent();
        _installBatch(agent, 8, true);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        vm.record();
        agent.runAll(ctx);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(agent));
        emit log_named_uint("candidate.batch.none.storage.oneShot.n8.readSlots", reads.length);
        emit log_named_uint("candidate.batch.none.storage.oneShot.n8.writeSlots", writes.length);
    }

    function test_batchPreservesSurvivorOrder() public {
        BatchCandidateAgent agent = new BatchCandidateAgent();
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        bytes32 c = keccak256("C");
        bytes32 d = keccak256("D");
        agent.installOneShot(a, address(strategy));
        agent.installCyclic(b, address(strategy));
        agent.installOneShot(c, address(strategy));
        agent.installCyclic(d, address(strategy));
        agent.runAll(ContextLib.explicitTrigger(address(agent), keeper));
        assertEq(agent.installedBehaviorCount(), 2);
        assertEq(agent.installedBehaviorAt(0), b);
        assertEq(agent.installedBehaviorAt(1), d);
    }

    function testBenchmark_swap_walkAllCyclic8() public {
        SwapCandidateAgent agent = new SwapCandidateAgent();
        _installSwap(agent, 8, false);
        _measureSwap(agent, "candidate.swap.none.walkAll.cyclic.n8");
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_swap_walkAllOneShot8() public {
        SwapCandidateAgent agent = new SwapCandidateAgent();
        _installSwap(agent, 8, true);
        _measureSwap(agent, "candidate.swap.none.walkAll.oneShot.n8");
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function testBenchmark_swap_mixed8() public {
        SwapCandidateAgent agent = new SwapCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("swap-mixed-", i));
            if (i % 2 == 0) agent.installOneShot(id, address(strategy));
            else agent.installCyclic(id, address(strategy));
        }
        _measureSwap(agent, "candidate.swap.none.walkAll.mixed.n8");
        assertEq(agent.installedBehaviorCount(), 4);
    }

    function testBenchmark_swap_atMost1Of8Cyclic() public {
        SwapCandidateAgent agent = new SwapCandidateAgent();
        _installSwap(agent, 8, false);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAtMost(ctx, 1);
        emit log_named_uint("candidate.swap.none.atMost1.cyclic.n8", beforeGas - gasleft());
        assertEq(agent.installedBehaviorCount(), 8);
    }

    function testBenchmark_swap_storageTrafficOneShot8() public {
        SwapCandidateAgent agent = new SwapCandidateAgent();
        _installSwap(agent, 8, true);
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        vm.record();
        agent.runAll(ctx);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(agent));
        emit log_named_uint("candidate.swap.none.storage.oneShot.n8.readSlots", reads.length);
        emit log_named_uint("candidate.swap.none.storage.oneShot.n8.writeSlots", writes.length);
    }

    function test_swapChangesFutureSelectionOrderByDesign() public {
        SwapCandidateAgent agent = new SwapCandidateAgent();
        bytes32 a = keccak256("A");
        bytes32 b = keccak256("B");
        bytes32 c = keccak256("C");
        bytes32 d = keccak256("D");
        agent.installOneShot(a, address(strategy));
        agent.installCyclic(b, address(strategy));
        agent.installOneShot(c, address(strategy));
        agent.installCyclic(d, address(strategy));
        agent.runAll(ContextLib.explicitTrigger(address(agent), keeper));
        assertEq(agent.installedBehaviorCount(), 2);
        assertEq(agent.installedBehaviorAt(0), d);
        assertEq(agent.installedBehaviorAt(1), b);
    }

    function testBenchmark_batch_applicationVector() public {
        BatchActionCandidateAgent cyclic = new BatchActionCandidateAgent();
        _installBatchAction(cyclic, 8, false, "batch-app-cyclic");
        _measureBatch(cyclic, "candidate.batch.application.walkAll.cyclic.n8");
        assertEq(cyclic.sink(), 8);

        BatchActionCandidateAgent oneShot = new BatchActionCandidateAgent();
        _installBatchAction(oneShot, 8, true, "batch-app-one-shot");
        _measureBatch(oneShot, "candidate.batch.application.walkAll.oneShot.n8");
        assertEq(oneShot.sink(), 8);

        BatchActionCandidateAgent mixed = new BatchActionCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("batch-app-mixed", i));
            if (i % 2 == 0) mixed.installOneShot(id, address(application));
            else mixed.installCyclic(id, address(application));
        }
        _measureBatch(mixed, "candidate.batch.application.walkAll.mixed.n8");
        assertEq(mixed.sink(), 8);

        BatchActionCandidateAgent bounded = new BatchActionCandidateAgent();
        _installBatchAction(bounded, 8, false, "batch-app-bounded");
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(bounded), keeper);
        uint256 beforeGas = gasleft();
        bounded.runAtMost(ctx, 1);
        emit log_named_uint("candidate.batch.application.atMost1.cyclic.n8", beforeGas - gasleft());
        assertEq(bounded.sink(), 1);
    }

    function testBenchmark_swap_applicationVector() public {
        SwapActionCandidateAgent cyclic = new SwapActionCandidateAgent();
        _installSwapAction(cyclic, 8, false, "swap-app-cyclic");
        _measureSwap(cyclic, "candidate.swap.application.walkAll.cyclic.n8");
        assertEq(cyclic.sink(), 8);

        SwapActionCandidateAgent oneShot = new SwapActionCandidateAgent();
        _installSwapAction(oneShot, 8, true, "swap-app-one-shot");
        _measureSwap(oneShot, "candidate.swap.application.walkAll.oneShot.n8");
        assertEq(oneShot.sink(), 8);

        SwapActionCandidateAgent mixed = new SwapActionCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("swap-app-mixed", i));
            if (i % 2 == 0) mixed.installOneShot(id, address(application));
            else mixed.installCyclic(id, address(application));
        }
        _measureSwap(mixed, "candidate.swap.application.walkAll.mixed.n8");
        assertEq(mixed.sink(), 8);

        SwapActionCandidateAgent bounded = new SwapActionCandidateAgent();
        _installSwapAction(bounded, 8, false, "swap-app-bounded");
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(bounded), keeper);
        uint256 beforeGas = gasleft();
        bounded.runAtMost(ctx, 1);
        emit log_named_uint("candidate.swap.application.atMost1.cyclic.n8", beforeGas - gasleft());
        assertEq(bounded.sink(), 1);
    }

    function _installBatchAction(
        BatchActionCandidateAgent agent,
        uint256 n,
        bool oneShot,
        string memory seed
    ) internal {
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = keccak256(abi.encodePacked(seed, i));
            if (oneShot) agent.installOneShot(id, address(application));
            else agent.installCyclic(id, address(application));
        }
    }

    function _installSwapAction(
        SwapActionCandidateAgent agent,
        uint256 n,
        bool oneShot,
        string memory seed
    ) internal {
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = keccak256(abi.encodePacked(seed, i));
            if (oneShot) agent.installOneShot(id, address(application));
            else agent.installCyclic(id, address(application));
        }
    }

    function _installBatch(BatchCandidateAgent agent, uint256 n, bool oneShot) internal {
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = keccak256(abi.encodePacked("batch-", oneShot, i));
            if (oneShot) agent.installOneShot(id, address(strategy));
            else agent.installCyclic(id, address(strategy));
        }
    }

    function _installSwap(SwapCandidateAgent agent, uint256 n, bool oneShot) internal {
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = keccak256(abi.encodePacked("swap-", oneShot, i));
            if (oneShot) agent.installOneShot(id, address(strategy));
            else agent.installCyclic(id, address(strategy));
        }
    }

    function _measureBatch(BatchCandidateAgent agent, string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        emit log_named_uint(label, beforeGas - gasleft());
    }

    function _measureSwap(SwapCandidateAgent agent, string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        emit log_named_uint(label, beforeGas - gasleft());
    }
}
