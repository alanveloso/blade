pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ExplicitExecutorGate} from "../../src/behavior/ExplicitExecutorGate.sol";
import {BehaviorContext, ContextLib} from "../../src/behavior/Context.sol";
import {IExternalApplicationStrategy} from "../../src/behavior/IExternalApplicationStrategy.sol";
import {Action, Kind} from "../../src/behavior/Action.sol";
import {Agent} from "../../src/core/Agent.sol";
import {Message} from "../../src/core/Message.sol";

uint256 constant INVARIANT_STEP_GAS = 800_000;
uint256 constant INVARIANT_ID_COUNT = 8;

contract InvariantNoneStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.None);
    }
}

contract InvariantRevertingStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory) {
        revert("strategy");
    }
}

contract InvariantInvalidStrategy is IExternalApplicationStrategy {
    function decide(BehaviorContext calldata) external pure returns (Action memory a) {
        a.kind = type(uint8).max;
    }
}

/// @dev Test-only inspection/execution surface for stateful Behavior invariants.
contract BehaviorInvariantAgent is ExplicitExecutorGate {
    uint256 internal immutable _stepGas;

    constructor(address executor_, uint256 stepGas_)
        Agent(address(0))
        ExplicitExecutorGate(executor_)
    {
        _stepGas = stepGas_;
    }

    function _behaviorStepGas() internal view override returns (uint256) {
        return _stepGas;
    }

    function installOneShot(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function installCyclic(bytes32 localId, address implementation) external {
        _installCyclicBehavior(localId, implementation);
    }

    function uninstall(bytes32 localId) external {
        _uninstallBehavior(localId);
    }

    function runAtMost(uint256 maxToRun) external {
        _runBehaviorStepAtMost(
            ContextLib.explicitTrigger(address(this), msg.sender), _stepGas, maxToRun
        );
    }

    function cyclicOf(bytes32 localId) external view returns (bool) {
        return _cyclic[localId];
    }

    function resumeIndex() external view returns (uint256) {
        return _resumeIndex;
    }
}

/// @dev Random install/uninstall/trigger sequences. Invalid operations are caught; the handler
///      checks rollback immediately and exposes a structural invariant oracle.
contract BehaviorHandler is Test {
    BehaviorInvariantAgent public agent;
    InvariantNoneStrategy public noneStrategy;
    InvariantRevertingStrategy public revertingStrategy;
    InvariantInvalidStrategy public invalidStrategy;

    bytes32[INVARIANT_ID_COUNT] internal ids;
    address internal constant STRANGER = address(0xBADD1E);

    uint256 public calls;
    uint256 public successfulSteps;

    constructor() {
        agent = new BehaviorInvariantAgent(address(this), INVARIANT_STEP_GAS);
        noneStrategy = new InvariantNoneStrategy();
        revertingStrategy = new InvariantRevertingStrategy();
        invalidStrategy = new InvariantInvalidStrategy();
        for (uint256 i = 0; i < INVARIANT_ID_COUNT; ++i) {
            ids[i] = keccak256(abi.encodePacked("behavior-invariant-", i));
        }
    }

    function installOneShot(uint8 idSel, uint8 strategySel) external {
        try agent.installOneShot(_id(idSel), _strategy(strategySel)) {} catch {}
        calls++;
    }

    function installCyclic(uint8 idSel, uint8 strategySel) external {
        try agent.installCyclic(_id(idSel), _strategy(strategySel)) {} catch {}
        calls++;
    }

    function uninstall(uint8 idSel) external {
        try agent.uninstall(_id(idSel)) {} catch {}
        calls++;
    }

    function authorizedExplicit() external {
        bytes32 before = _digest();
        try agent.dispatchExplicitTrigger() {
            successfulSteps++;
        } catch {
            assertEq(_digest(), before, "B-I4 failed Explicit mutated state");
        }
        calls++;
    }

    function unauthorizedExplicit() external {
        bytes32 before = _digest();
        vm.prank(STRANGER);
        try agent.dispatchExplicitTrigger() {
            revert("unauthorized Explicit succeeded");
        } catch {}
        assertEq(_digest(), before, "B-I3 unauthorized Explicit mutated state");
        calls++;
    }

    function messageTrigger(uint8 nonce) external {
        Message memory m;
        m.conversationId = keccak256(abi.encodePacked("behavior-message-", nonce));
        bytes32 before = _digest();
        try agent.handle(m) {
            successfulSteps++;
        } catch {
            assertEq(_digest(), before, "B-I4 failed Message step mutated state");
        }
        calls++;
    }

    function boundedStep(uint8 maxToRun) external {
        bytes32 before = _digest();
        try agent.runAtMost(uint256(maxToRun)) {
            successfulSteps++;
        } catch {
            assertEq(_digest(), before, "B-I4 failed bounded step mutated state");
        }
        calls++;
    }

    function assertBehaviorInvariants() external view {
        uint256 n = agent.installedBehaviorCount();
        assertLe(n, INVARIANT_ID_COUNT, "B-I1 pool cap");

        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = agent.installedBehaviorAt(i);
            assertTrue(agent.behaviorImplementation(id) != address(0), "B-I2 list without mapping");
            for (uint256 j = i + 1; j < n; ++j) {
                assertTrue(id != agent.installedBehaviorAt(j), "B-I2 duplicate id");
            }
        }

        for (uint256 i = 0; i < INVARIANT_ID_COUNT; ++i) {
            bytes32 id = ids[i];
            address implementation = agent.behaviorImplementation(id);
            uint256 occurrences;
            for (uint256 j = 0; j < n; ++j) {
                if (agent.installedBehaviorAt(j) == id) occurrences++;
            }
            if (implementation == address(0)) {
                assertEq(occurrences, 0, "B-I2 orphan list entry");
                assertFalse(agent.cyclicOf(id), "B-I5 cyclic lifetime leaked after uninstall");
            } else {
                assertEq(occurrences, 1, "B-I2 mapping/list mismatch");
            }
        }
    }

    function _id(uint8 sel) internal view returns (bytes32) {
        return ids[uint256(sel) % INVARIANT_ID_COUNT];
    }

    function _strategy(uint8 sel) internal view returns (address) {
        uint256 mode = uint256(sel) % 3;
        if (mode == 0) return address(noneStrategy);
        if (mode == 1) return address(revertingStrategy);
        return address(invalidStrategy);
    }

    function _digest() internal view returns (bytes32) {
        uint256 n = agent.installedBehaviorCount();
        bytes memory state = abi.encode(n, agent.resumeIndex());
        for (uint256 i = 0; i < INVARIANT_ID_COUNT; ++i) {
            bytes32 id = ids[i];
            state = bytes.concat(
                state, abi.encode(id, agent.behaviorImplementation(id), agent.cyclicOf(id))
            );
        }
        for (uint256 i = 0; i < n; ++i) {
            state = bytes.concat(state, abi.encode(agent.installedBehaviorAt(i)));
        }
        return keccak256(state);
    }
}
