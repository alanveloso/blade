pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Action, Kind} from "../../../src/behavior/Action.sol";
import {BehaviorEngine} from "../../../src/behavior/BehaviorEngine.sol";
import {BehaviorContext, ContextLib} from "../../../src/behavior/Context.sol";
import {IExternalApplicationStrategy} from "../../../src/behavior/IExternalApplicationStrategy.sol";
import {
    ExternalApplicationBehaviorHost
} from "../../../src/behavior/ExternalApplicationBehaviorHost.sol";

uint256 constant DECODER_STEP_GAS = 1_600_000;

contract DecoderNoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.None);
    }
}

contract DecoderApplicationStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(uint256(1));
    }
}

/// @dev Returns malformed successful returndata for decoder-safety checks.
contract DecoderMalformedStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory) {
        assembly ("memory-safe") {
            mstore(0x00, 0x20)
            mstore(0x20, 0x00)
            return(0x00, 0x40)
        }
    }
}

/// @dev Shared experimental engine shell. Product `src/` remains the control.
abstract contract AlternativeDecoderBehaviorEngine is BehaviorEngine {
    function _runAlternativeExternal(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        internal
        virtual;

    function _runAlternativeStep(BehaviorContext memory ctx, uint256 stepGas) internal {
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
            _runAlternativeExternal(snapshot[i], ctx, per);
        }
        for (uint256 i = 0; i < n; ++i) {
            if (_completesAfterSuccess(snapshot[i])) _uninstallBehavior(snapshot[i]);
        }
    }

    function _runAlternativeAtMost(BehaviorContext memory ctx, uint256 stepGas, uint256 maxToRun)
        internal
    {
        uint256 n = _orderedBehaviorIds.length;
        if (n == 0) return;
        if (maxToRun == 0) revert InvalidMaxToRun();
        uint256 k = maxToRun > n ? n : maxToRun;
        if (k == n) {
            _runAlternativeStep(ctx, stepGas);
            return;
        }
        if (stepGas == 0) revert InvalidStepGas();
        uint256 per = stepGas / k;
        if (per == 0) revert InvalidStepGas();

        uint256 remaining = gasleft();
        if (remaining <= ENGINE_OVERHEAD) revert InvalidStepGas();
        uint256 usable = remaining - ENGINE_OVERHEAD;
        if (POST_CALL_OVERHEAD > type(uint256).max / k) revert InvalidStepGas();
        uint256 hostReserve = k * POST_CALL_OVERHEAD;
        if (usable <= hostReserve || stepGas > usable - hostReserve) revert InvalidStepGas();

        uint256 start = _resumeIndex % n;
        bytes32[] memory selected = new bytes32[](k);
        for (uint256 i = 0; i < k; ++i) {
            selected[i] = _orderedBehaviorIds[(start + i) % n];
        }
        bytes32 nextId = _orderedBehaviorIds[(start + k) % n];

        for (uint256 i = 0; i < k; ++i) {
            _runAlternativeExternal(selected[i], ctx, per);
        }
        for (uint256 i = 0; i < k; ++i) {
            if (_completesAfterSuccess(selected[i])) _uninstallBehavior(selected[i]);
        }
        _resumeIndex = _alternativeIndexOf(nextId);
    }

    function _alternativeIndexOf(bytes32 localId) private view returns (uint256) {
        uint256 n = _orderedBehaviorIds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_orderedBehaviorIds[i] == localId) return i;
        }
        revert InvalidBehaviorIndex();
    }

    function _candidateCall(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        internal
        returns (address implementation, uint256 size)
    {
        implementation = _behaviors[localId];
        if (implementation == address(0)) revert NotInstalled();
        if (implementation.code.length == 0) revert NoStrategyCode();
        ContextLib.validate(ctx);
        if (ctx.agent != address(this)) revert ContextAgentMismatch();
        uint256 remaining = gasleft();
        if (
            gasBudget == 0 || remaining <= POST_CALL_OVERHEAD
                || gasBudget > remaining - POST_CALL_OVERHEAD
        ) revert InvalidGasBudget();

        bytes memory payload = abi.encodeCall(IExternalApplicationStrategy.decide, (ctx));
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gasBudget, implementation, add(payload, 0x20), mload(payload), 0, 0)
            size := returndatasize()
        }
        if (!ok) revert BehaviorExecutionFailed(localId, implementation);
        if (size == 0) revert InvalidStrategyReturn();
        if (size > MAX_STRATEGY_RETURN) revert StrategyReturnTooLarge();
    }
}

/// @dev C3 candidate: inspect/copy the 128-byte ABI header first, then copy payload only if valid.
abstract contract HeaderFirstDecoderBehaviorEngine is AlternativeDecoderBehaviorEngine {
    function _runAlternativeExternal(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        internal
        override
    {
        (, uint256 size) = _candidateCall(localId, ctx, gasBudget);
        if (size < 128) revert InvalidStrategyReturn();

        bytes memory header = new bytes(128);
        assembly ("memory-safe") {
            returndatacopy(add(header, 0x20), 0, 128)
        }

        uint256 outer;
        uint256 kindWord;
        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            outer := mload(add(header, 32))
            kindWord := mload(add(header, 64))
            offset := mload(add(header, 96))
            len := mload(add(header, 128))
        }
        if (outer != 32 || kindWord > type(uint8).max || offset != 64) {
            revert InvalidStrategyReturn();
        }
        if (len > size - 128) revert InvalidStrategyReturn();
        uint256 padded = (len + 31) & ~uint256(31);
        if (size != 128 + padded) revert InvalidStrategyReturn();

        Action memory a;
        // forge-lint: disable-next-line(unsafe-typecast)
        a.kind = uint8(kindWord);
        if (len != 0) {
            bytes memory data = new bytes(len);
            assembly ("memory-safe") {
                returndatacopy(add(data, 0x20), 128, len)
            }
            a.data = data;
        }
        _dispatchBehaviorAction(localId, ctx, a);
    }
}

/// @dev C3 semantic counterfactual: Solidity ABI decoder after bounded copy.
///      It is measured even if malformed-return behavior is worse than the product custom error.
abstract contract AbiDecodeBehaviorEngine is AlternativeDecoderBehaviorEngine {
    function _runAlternativeExternal(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        internal
        override
    {
        (, uint256 size) = _candidateCall(localId, ctx, gasBudget);
        bytes memory ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0, size)
        }
        Action memory a = abi.decode(ret, (Action));
        _dispatchBehaviorAction(localId, ctx, a);
    }
}

contract HeaderFirstCandidateAgent is HeaderFirstDecoderBehaviorEngine {
    uint256 public sink;

    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runAlternativeStep(ctx, DECODER_STEP_GAS);
    }

    function runAtMost(BehaviorContext memory ctx, uint256 maxToRun) external {
        _runAlternativeAtMost(ctx, DECODER_STEP_GAS, maxToRun);
    }

    function runSingle(bytes32 localId, BehaviorContext memory ctx) external {
        _runAlternativeExternal(localId, ctx, 160_000);
    }

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

contract AbiDecodeCandidateAgent is AbiDecodeBehaviorEngine {
    uint256 public sink;

    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runAlternativeStep(ctx, DECODER_STEP_GAS);
    }

    function runAtMost(BehaviorContext memory ctx, uint256 maxToRun) external {
        _runAlternativeAtMost(ctx, DECODER_STEP_GAS, maxToRun);
    }

    function runSingle(bytes32 localId, BehaviorContext memory ctx) external {
        _runAlternativeExternal(localId, ctx, 160_000);
    }

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

contract DecoderCandidatesTest is Test {
    DecoderNoneStrategy internal none;
    DecoderApplicationStrategy internal application;
    DecoderMalformedStrategy internal malformed;
    address internal keeper;

    function setUp() public {
        none = new DecoderNoneStrategy();
        application = new DecoderApplicationStrategy();
        malformed = new DecoderMalformedStrategy();
        keeper = makeAddr("decoder-candidate-keeper");
    }

    function testBenchmark_headerFirst_noneVector() public {
        _benchmarkHeader(false);
    }

    function testBenchmark_abiDecode_noneVector() public {
        _benchmarkAbi(false);
    }

    function testBenchmark_headerFirst_applicationVector() public {
        _benchmarkHeader(true);
    }

    function testBenchmark_abiDecode_applicationVector() public {
        _benchmarkAbi(true);
    }

    function test_headerFirstMalformedReturnKeepsCustomBoundaryError() public {
        HeaderFirstCandidateAgent agent = new HeaderFirstCandidateAgent();
        bytes32 id = keccak256("header-malformed");
        agent.installCyclic(id, address(malformed));
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        agent.runSingle(id, ContextLib.explicitTrigger(address(agent), keeper));
    }

    function test_abiDecodeMalformedReturnIsNotEquivalentCustomError() public {
        AbiDecodeCandidateAgent agent = new AbiDecodeCandidateAgent();
        bytes32 id = keccak256("abi-malformed");
        agent.installCyclic(id, address(malformed));
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        (bool ok, bytes memory reason) = address(agent)
            .call(abi.encodeWithSelector(AbiDecodeCandidateAgent.runSingle.selector, id, ctx));
        assertFalse(ok);
        if (reason.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 32))
            }
            assertTrue(selector != ExternalApplicationBehaviorHost.InvalidStrategyReturn.selector);
        }
    }

    function _benchmarkHeader(bool withApplication) internal {
        address strategy = withApplication ? address(application) : address(none);
        string memory prefix =
            withApplication ? "candidate.header.application" : "candidate.header.none";

        HeaderFirstCandidateAgent cyclic = new HeaderFirstCandidateAgent();
        _installHeader(cyclic, strategy, 8, false, "h-cyclic");
        _measureHeader(cyclic, string.concat(prefix, ".walkAll.cyclic.n8"));

        HeaderFirstCandidateAgent oneShot = new HeaderFirstCandidateAgent();
        _installHeader(oneShot, strategy, 8, true, "h-one-shot");
        _measureHeader(oneShot, string.concat(prefix, ".walkAll.oneShot.n8"));

        HeaderFirstCandidateAgent mixed = new HeaderFirstCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("h-mixed", withApplication, i));
            if (i % 2 == 0) mixed.installOneShot(id, strategy);
            else mixed.installCyclic(id, strategy);
        }
        _measureHeader(mixed, string.concat(prefix, ".walkAll.mixed.n8"));

        HeaderFirstCandidateAgent bounded = new HeaderFirstCandidateAgent();
        _installHeader(bounded, strategy, 8, false, "h-bounded");
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(bounded), keeper);
        uint256 beforeGas = gasleft();
        bounded.runAtMost(ctx, 1);
        emit log_named_uint(string.concat(prefix, ".atMost1.cyclic.n8"), beforeGas - gasleft());
    }

    function _benchmarkAbi(bool withApplication) internal {
        address strategy = withApplication ? address(application) : address(none);
        string memory prefix = withApplication ? "candidate.abi.application" : "candidate.abi.none";

        AbiDecodeCandidateAgent cyclic = new AbiDecodeCandidateAgent();
        _installAbi(cyclic, strategy, 8, false, "a-cyclic");
        _measureAbi(cyclic, string.concat(prefix, ".walkAll.cyclic.n8"));

        AbiDecodeCandidateAgent oneShot = new AbiDecodeCandidateAgent();
        _installAbi(oneShot, strategy, 8, true, "a-one-shot");
        _measureAbi(oneShot, string.concat(prefix, ".walkAll.oneShot.n8"));

        AbiDecodeCandidateAgent mixed = new AbiDecodeCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("a-mixed", withApplication, i));
            if (i % 2 == 0) mixed.installOneShot(id, strategy);
            else mixed.installCyclic(id, strategy);
        }
        _measureAbi(mixed, string.concat(prefix, ".walkAll.mixed.n8"));

        AbiDecodeCandidateAgent bounded = new AbiDecodeCandidateAgent();
        _installAbi(bounded, strategy, 8, false, "a-bounded");
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(bounded), keeper);
        uint256 beforeGas = gasleft();
        bounded.runAtMost(ctx, 1);
        emit log_named_uint(string.concat(prefix, ".atMost1.cyclic.n8"), beforeGas - gasleft());
    }

    function _installHeader(
        HeaderFirstCandidateAgent agent,
        address strategy,
        uint256 n,
        bool oneShot,
        string memory seed
    ) internal {
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = keccak256(abi.encodePacked(seed, i));
            if (oneShot) agent.installOneShot(id, strategy);
            else agent.installCyclic(id, strategy);
        }
    }

    function _installAbi(
        AbiDecodeCandidateAgent agent,
        address strategy,
        uint256 n,
        bool oneShot,
        string memory seed
    ) internal {
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = keccak256(abi.encodePacked(seed, i));
            if (oneShot) agent.installOneShot(id, strategy);
            else agent.installCyclic(id, strategy);
        }
    }

    function _measureHeader(HeaderFirstCandidateAgent agent, string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        emit log_named_uint(label, beforeGas - gasleft());
    }

    function _measureAbi(AbiDecodeCandidateAgent agent, string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        emit log_named_uint(label, beforeGas - gasleft());
    }
}
