// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Action, Kind} from "../src/behavior/Action.sol";
import {BehaviorContext, Trigger} from "../src/behavior/Context.sol";
import {ExplicitExecutorGate} from "../src/behavior/ExplicitExecutorGate.sol";
import {IExternalApplicationStrategy} from "../src/behavior/IExternalApplicationStrategy.sol";
import {Agent} from "../src/core/Agent.sol";
import {Message} from "../src/core/Message.sol";

/// @dev Reusable read-only decision policy. The strategy proposes a delta; it never writes
///      Agent state.
///      Different deltas for Message/Explicit make the trigger provenance visible in the example.
contract IncrementBehaviorStrategy is IExternalApplicationStrategy {
    uint256 public immutable explicitDelta;
    uint256 public immutable messageDelta;

    constructor(uint256 explicitDelta_, uint256 messageDelta_) {
        explicitDelta = explicitDelta_;
        messageDelta = messageDelta_;
    }

    function decide(BehaviorContext calldata ctx) external view returns (Action memory a) {
        if (msg.sender != ctx.agent) revert("identity");
        a.kind = uint8(Kind.Application);
        if (ctx.trigger == uint8(Trigger.Explicit)) {
            a.data = abi.encode(explicitDelta);
            return a;
        }
        if (ctx.trigger == uint8(Trigger.Message)) {
            a.data = abi.encode(messageDelta);
            return a;
        }
        revert("trigger");
    }
}

/// @title Minimal end-to-end Behavior v1 application.
/// @dev Demonstrates product entry points only:
///      authorized Explicit / authenticated Message -> external strategy -> validated Application
///      Action -> trusted Agent-owned effect. It is not a scheduler and does not wake itself.
/// @dev `behaviorAdmin` is example application policy, not a BLADE Core owner concept.
contract ExampleBehaviorCounterAgent is ExplicitExecutorGate {
    address public immutable behaviorAdmin;
    address public immutable messageCaller;
    uint256 internal immutable _stepGas;
    uint256 public counter;

    error UnauthorizedBehaviorAdmin();
    error UnauthorizedMessageCaller();
    error InvalidCounterAction();

    event CounterIncremented(
        bytes32 indexed localId,
        uint256 delta,
        uint256 newValue,
        uint8 trigger,
        address transportCaller
    );

    constructor(
        address trustedRelay_,
        address explicitExecutor_,
        address behaviorAdmin_,
        address messageCaller_,
        uint256 stepGas_
    ) Agent(trustedRelay_) ExplicitExecutorGate(explicitExecutor_) {
        behaviorAdmin = behaviorAdmin_;
        messageCaller = messageCaller_;
        _stepGas = stepGas_;
    }

    function installOneShotBehavior(bytes32 localId, address implementation) external {
        _requireBehaviorAdmin();
        _installBehavior(localId, implementation);
    }

    function installCyclicBehavior(bytes32 localId, address implementation) external {
        _requireBehaviorAdmin();
        _installCyclicBehavior(localId, implementation);
    }

    function uninstallBehavior(bytes32 localId) external {
        _requireBehaviorAdmin();
        _uninstallBehavior(localId);
    }

    function _behaviorStepGas() internal view override returns (uint256) {
        return _stepGas;
    }

    function _authorizeInbound(Message calldata) internal view override {
        if (msg.sender != messageCaller) revert UnauthorizedMessageCaller();
    }

    function _onApplicationAction(
        bytes32 localId,
        BehaviorContext memory ctx,
        bytes memory data
    ) internal override {
        if (data.length != 32) revert InvalidCounterAction();
        uint256 delta = abi.decode(data, (uint256));
        counter += delta;
        emit CounterIncremented(localId, delta, counter, ctx.trigger, ctx.transportCaller);
    }

    function _requireBehaviorAdmin() private view {
        if (msg.sender != behaviorAdmin) revert UnauthorizedBehaviorAdmin();
    }
}
