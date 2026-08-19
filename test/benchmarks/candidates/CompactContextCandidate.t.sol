pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Action, Kind} from "../../../src/behavior/Action.sol";
import {BehaviorEngine} from "../../../src/behavior/BehaviorEngine.sol";
import {BehaviorContext, ContextLib, Trigger} from "../../../src/behavior/Context.sol";

uint256 constant COMPACT_STEP_GAS = 1_600_000;

/// @dev Experimental C2 ABI only. Four small envelope fields are packed into one 256-bit word.
///      This is not the product BehaviorContext and is not an adoption decision.
struct CompactBehaviorContext {
    address agent;
    address transportCaller;
    bytes32 logicalSender;
    bytes32 envelope;
    bytes32 conversationId;
    bytes32 replyWith;
    bytes32 inReplyTo;
}

library CompactContextLib {
    uint256 private constant TRIGGER_SHIFT = 0;
    uint256 private constant PERFORMATIVE_SHIFT = 8;
    uint256 private constant PROTOCOL_SHIFT = 16;
    uint256 private constant REPLY_BY_SHIFT = 24;

    /// @dev Caller validates the canonical BehaviorContext once before packing.
    function pack(BehaviorContext memory ctx)
        internal
        pure
        returns (CompactBehaviorContext memory c)
    {
        uint256 envelope = uint256(ctx.trigger) << TRIGGER_SHIFT;
        envelope |= uint256(ctx.performative) << PERFORMATIVE_SHIFT;
        envelope |= uint256(ctx.protocol) << PROTOCOL_SHIFT;
        envelope |= uint256(ctx.replyBy) << REPLY_BY_SHIFT;
        c.agent = ctx.agent;
        c.transportCaller = ctx.transportCaller;
        c.logicalSender = ctx.logicalSender;
        c.envelope = bytes32(envelope);
        c.conversationId = ctx.conversationId;
        c.replyWith = ctx.replyWith;
        c.inReplyTo = ctx.inReplyTo;
    }

    function trigger(CompactBehaviorContext calldata c) internal pure returns (uint8) {
        return uint8(uint256(c.envelope));
    }

    function performative(CompactBehaviorContext calldata c) internal pure returns (uint8) {
        return uint8(uint256(c.envelope) >> PERFORMATIVE_SHIFT);
    }

    function protocol(CompactBehaviorContext calldata c) internal pure returns (uint8) {
        return uint8(uint256(c.envelope) >> PROTOCOL_SHIFT);
    }

    function replyBy(CompactBehaviorContext calldata c) internal pure returns (uint64) {
        return uint64(uint256(c.envelope) >> REPLY_BY_SHIFT);
    }
}

interface ICompactBehaviorStrategy {
    function decideCompact(CompactBehaviorContext calldata ctx)
        external
        view
        returns (Action memory);
}

contract CompactNoneStrategy is ICompactBehaviorStrategy {
    function decideCompact(CompactBehaviorContext calldata ctx)
        external
        view
        returns (Action memory a)
    {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.None);
    }
}

contract CompactApplicationStrategy is ICompactBehaviorStrategy {
    function decideCompact(CompactBehaviorContext calldata ctx)
        external
        view
        returns (Action memory a)
    {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        a.data = abi.encode(uint256(1));
    }
}

contract CompactSemanticProbe is ICompactBehaviorStrategy {
    uint8 internal immutable _trigger;
    uint8 internal immutable _performative;
    uint8 internal immutable _protocol;
    uint64 internal immutable _replyBy;

    constructor(uint8 trigger_, uint8 performative_, uint8 protocol_, uint64 replyBy_) {
        _trigger = trigger_;
        _performative = performative_;
        _protocol = protocol_;
        _replyBy = replyBy_;
    }

    function decideCompact(CompactBehaviorContext calldata ctx)
        external
        view
        returns (Action memory a)
    {
        if (CompactContextLib.trigger(ctx) != _trigger) revert("trigger");
        if (CompactContextLib.performative(ctx) != _performative) revert("performative");
        if (CompactContextLib.protocol(ctx) != _protocol) revert("protocol");
        if (CompactContextLib.replyBy(ctx) != _replyBy) revert("replyBy");
        a.kind = uint8(Kind.None);
    }
}

/// @dev C2 engine shell: product membership/lifetime, alternate strategy ABI only.
abstract contract CompactContextBehaviorEngine is BehaviorEngine {
    function _runCompactStep(BehaviorContext memory ctx, uint256 stepGas) internal {
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
            _runCompactExternal(snapshot[i], ctx, per);
        }
        for (uint256 i = 0; i < n; ++i) {
            if (_completesAfterSuccess(snapshot[i])) _uninstallBehavior(snapshot[i]);
        }
    }

    function _runCompactAtMost(BehaviorContext memory ctx, uint256 stepGas, uint256 maxToRun)
        internal
    {
        uint256 n = _orderedBehaviorIds.length;
        if (n == 0) return;
        if (maxToRun == 0) revert InvalidMaxToRun();
        uint256 k = maxToRun > n ? n : maxToRun;
        if (k == n) {
            _runCompactStep(ctx, stepGas);
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
            _runCompactExternal(selected[i], ctx, per);
        }
        for (uint256 i = 0; i < k; ++i) {
            if (_completesAfterSuccess(selected[i])) _uninstallBehavior(selected[i]);
        }
        _resumeIndex = _compactIndexOf(nextId);
    }

    function _runCompactExternal(bytes32 localId, BehaviorContext memory ctx, uint256 gasBudget)
        internal
    {
        address implementation = _behaviors[localId];
        if (implementation == address(0)) revert NotInstalled();
        if (implementation.code.length == 0) revert NoStrategyCode();
        ContextLib.validate(ctx);
        if (ctx.agent != address(this)) revert ContextAgentMismatch();
        uint256 remaining = gasleft();
        if (
            gasBudget == 0 || remaining <= POST_CALL_OVERHEAD
                || gasBudget > remaining - POST_CALL_OVERHEAD
        ) revert InvalidGasBudget();

        CompactBehaviorContext memory compact = CompactContextLib.pack(ctx);
        bytes memory payload = abi.encodeCall(ICompactBehaviorStrategy.decideCompact, (compact));
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gasBudget, implementation, add(payload, 0x20), mload(payload), 0, 0)
        }
        if (!ok) revert BehaviorExecutionFailed(localId, implementation);

        uint256 size;
        assembly ("memory-safe") {
            size := returndatasize()
        }
        if (size == 0) revert InvalidStrategyReturn();
        if (size > MAX_STRATEGY_RETURN) revert StrategyReturnTooLarge();
        bytes memory ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0, size)
        }
        _dispatchBehaviorAction(localId, ctx, _decodeCompactAction(ret));
    }

    function _decodeCompactAction(bytes memory ret) private pure returns (Action memory a) {
        uint256 size = ret.length;
        if (size < 128) revert InvalidStrategyReturn();
        uint256 outer;
        uint256 kindWord;
        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            outer := mload(add(ret, 32))
            kindWord := mload(add(ret, 64))
            offset := mload(add(ret, 96))
            len := mload(add(ret, 128))
        }
        if (outer != 32 || kindWord > type(uint8).max || offset != 64) {
            revert InvalidStrategyReturn();
        }
        if (len > size - 128) revert InvalidStrategyReturn();
        uint256 padded = (len + 31) & ~uint256(31);
        if (size != 128 + padded) revert InvalidStrategyReturn();
        // forge-lint: disable-next-line(unsafe-typecast)
        a.kind = uint8(kindWord);
        if (len != 0) {
            bytes memory data = new bytes(len);
            assembly ("memory-safe") {
                mcopy(add(data, 32), add(ret, 160), len)
            }
            a.data = data;
        }
    }

    function _compactIndexOf(bytes32 localId) private view returns (uint256) {
        uint256 n = _orderedBehaviorIds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_orderedBehaviorIds[i] == localId) return i;
        }
        revert InvalidBehaviorIndex();
    }
}

contract CompactCandidateAgent is CompactContextBehaviorEngine {
    uint256 public sink;

    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function runAll(BehaviorContext memory ctx) external {
        _runCompactStep(ctx, COMPACT_STEP_GAS);
    }

    function runAtMost(BehaviorContext memory ctx, uint256 maxToRun) external {
        _runCompactAtMost(ctx, COMPACT_STEP_GAS, maxToRun);
    }

    function runSingle(bytes32 localId, BehaviorContext memory ctx) external {
        _runCompactExternal(localId, ctx, 160_000);
    }

    function _onApplicationAction(bytes32, BehaviorContext memory, bytes memory data)
        internal
        override
    {
        if (data.length != 32) revert("payload");
        sink += abi.decode(data, (uint256));
    }
}

contract CompactContextCandidateTest is Test {
    CompactNoneStrategy internal none;
    CompactApplicationStrategy internal application;
    address internal keeper;

    function setUp() public {
        none = new CompactNoneStrategy();
        application = new CompactApplicationStrategy();
        keeper = makeAddr("compact-candidate-keeper");
    }

    function test_messageTriggerRemainsDistinctWhenPerformativeIsZero() public {
        CompactCandidateAgent agent = new CompactCandidateAgent();
        BehaviorContext memory ctx;
        ctx.trigger = uint8(Trigger.Message);
        ctx.agent = address(agent);
        ctx.transportCaller = keeper;
        ctx.performative = 0;
        ctx.protocol = 0;
        ctx.replyBy = 777;
        CompactSemanticProbe probe = new CompactSemanticProbe(uint8(Trigger.Message), 0, 0, 777);
        bytes32 id = keccak256("compact-semantic");
        agent.installCyclic(id, address(probe));
        agent.runSingle(id, ctx);
    }

    function testBenchmark_compact_noneVector() public {
        _benchmark(false);
    }

    function testBenchmark_compact_applicationVector() public {
        _benchmark(true);
    }

    function _benchmark(bool withApplication) internal {
        address strategy = withApplication ? address(application) : address(none);
        string memory prefix =
            withApplication ? "candidate.compact.application" : "candidate.compact.none";

        CompactCandidateAgent cyclic = new CompactCandidateAgent();
        _install(cyclic, strategy, 8, false, "compact-cyclic");
        _measureAll(cyclic, string.concat(prefix, ".walkAll.cyclic.n8"));

        CompactCandidateAgent oneShot = new CompactCandidateAgent();
        _install(oneShot, strategy, 8, true, "compact-one-shot");
        _measureAll(oneShot, string.concat(prefix, ".walkAll.oneShot.n8"));

        CompactCandidateAgent mixed = new CompactCandidateAgent();
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 id = keccak256(abi.encodePacked("compact-mixed", withApplication, i));
            if (i % 2 == 0) mixed.installOneShot(id, strategy);
            else mixed.installCyclic(id, strategy);
        }
        _measureAll(mixed, string.concat(prefix, ".walkAll.mixed.n8"));

        CompactCandidateAgent bounded = new CompactCandidateAgent();
        _install(bounded, strategy, 8, false, "compact-bounded");
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(bounded), keeper);
        uint256 beforeGas = gasleft();
        bounded.runAtMost(ctx, 1);
        emit log_named_uint(string.concat(prefix, ".atMost1.cyclic.n8"), beforeGas - gasleft());
    }

    function _install(
        CompactCandidateAgent agent,
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

    function _measureAll(CompactCandidateAgent agent, string memory label) internal {
        BehaviorContext memory ctx = ContextLib.explicitTrigger(address(agent), keeper);
        uint256 beforeGas = gasleft();
        agent.runAll(ctx);
        emit log_named_uint(label, beforeGas - gasleft());
    }
}
