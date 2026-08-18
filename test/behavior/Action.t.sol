pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Action, ActionLib, Kind} from "../../src/behavior/Action.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {ContractNetManager} from "../../src/core/ContractNetManager.sol";
import {Message} from "../../src/core/Message.sol";

contract ScriptedRequest is RequestAgent {
    constructor() Agent(address(0)) {}
}

contract ScriptedManager is ContractNetManager {
    constructor() Agent(address(0)) {}
}

/// @dev External wrapper so `expectRevert` sees a deeper call than the test.
contract ActionHarness {
    function validate(Action memory action) external pure {
        ActionLib.validate(action);
    }

    function kindOf(Action memory action) external pure returns (Kind) {
        return ActionLib.kindOf(action);
    }

    function applyAction(Action memory action) external pure {
        ActionLib.applyAction(action);
    }
}

/// @dev Increments `effects` only after a successful `ActionLib.applyAction`.
contract ApplyProbe {
    uint256 public effects;

    function applyAction(Action memory action) external {
        ActionLib.applyAction(action);
        effects++;
    }
}

contract ActionTest is Test {
    Agent internal agent;
    ScriptedRequest internal requester;
    ScriptedManager internal manager;
    ApplyProbe internal probe;
    ActionHarness internal harness;

    function setUp() public {
        agent = new Agent(address(0));
        requester = new ScriptedRequest();
        manager = new ScriptedManager();
        probe = new ApplyProbe();
        harness = new ActionHarness();
    }

    function _none() internal pure returns (Action memory a) {
        a.kind = uint8(Kind.None);
    }

    function test_noneEmptyIsValid() public view {
        harness.validate(_none());
        assertEq(uint8(harness.kindOf(_none())), uint8(Kind.None));
    }

    function test_noneWithDataReverts() public {
        Action memory a = _none();
        a.data = hex"00";
        vm.expectRevert(ActionLib.NoneRequiresEmptyData.selector);
        harness.validate(a);
    }

    function test_unknownKindReverts() public {
        Action memory a;
        a.kind = 1;
        vm.expectRevert(ActionLib.UnknownKind.selector);
        harness.validate(a);
    }

    function testFuzz_unknownKindReverts(uint8 kind, bytes calldata data) public {
        vm.assume(kind != uint8(Kind.None));
        Action memory a;
        a.kind = kind;
        a.data = data;
        vm.expectRevert(ActionLib.UnknownKind.selector);
        harness.validate(a);
    }

    function test_unknownKindWithDataRevertsUnknownKindNotNoneRule() public {
        Action memory a;
        a.kind = 2;
        a.data = hex"dead";
        vm.expectRevert(ActionLib.UnknownKind.selector);
        harness.validate(a);
    }

    function test_applyNoneIsNoOpOnProbe() public {
        probe.applyAction(_none());
        assertEq(probe.effects(), 1);
    }

    function test_invalidDoesNotIncrementEffects() public {
        Action memory a;
        a.kind = 1;
        vm.expectRevert(ActionLib.UnknownKind.selector);
        probe.applyAction(a);
        assertEq(probe.effects(), 0);
    }

    function test_noneWithDataDoesNotIncrementEffects() public {
        Action memory a = _none();
        a.data = hex"01";
        vm.expectRevert(ActionLib.NoneRequiresEmptyData.selector);
        probe.applyAction(a);
        assertEq(probe.effects(), 0);
    }

    function test_applyNoneDoesNotWriteAgentRequestOrContractNet() public {
        bytes32 id = keccak256("action-none");
        vm.record();
        harness.applyAction(_none());
        _assertNoWrites(address(agent));
        _assertNoWrites(address(requester));
        _assertNoWrites(address(manager));
        RequestAgent.Status memory st = requester.requestStatus(id);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
        assertEq(manager.slotOf(id, address(requester)), 0);
        assertEq(agent.trustedRelay(), address(0));
    }

    function test_kernelContractsStillAcceptHandleAfterActionLib() public {
        harness.applyAction(_none());
        Message memory m;
        m.performative = 0;
        m.conversationId = keccak256("still-handle");
        agent.handle(m);
    }

    function _assertNoWrites(address target) internal view {
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0);
    }
}
