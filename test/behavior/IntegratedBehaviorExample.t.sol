pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    ExampleBehaviorCounterAgent,
    IncrementBehaviorStrategy
} from "../../examples/BehaviorExample.sol";
import {ExplicitExecutorGate} from "../../src/behavior/ExplicitExecutorGate.sol";
import {Message} from "../../src/core/Message.sol";

uint256 constant EXAMPLE_STEP_GAS = 500_000;

contract IntegratedBehaviorExampleTest is Test {
    ExampleBehaviorCounterAgent internal agent;
    IncrementBehaviorStrategy internal oneShot;
    IncrementBehaviorStrategy internal cyclic;
    address internal admin;
    address internal executor;
    address internal peer;
    address internal stranger;
    bytes32 internal oneShotId;
    bytes32 internal cyclicId;

    function setUp() public {
        admin = makeAddr("behavior-admin");
        executor = makeAddr("behavior-executor");
        peer = makeAddr("behavior-peer");
        stranger = makeAddr("behavior-stranger");
        agent = new ExampleBehaviorCounterAgent(address(0), executor, admin, peer, EXAMPLE_STEP_GAS);
        oneShot = new IncrementBehaviorStrategy(2, 20);
        cyclic = new IncrementBehaviorStrategy(3, 30);
        oneShotId = keccak256("example-one-shot");
        cyclicId = keccak256("example-cyclic");
    }

    function _installBoth() internal {
        vm.startPrank(admin);
        agent.installOneShotBehavior(oneShotId, address(oneShot));
        agent.installCyclicBehavior(cyclicId, address(cyclic));
        vm.stopPrank();
    }

    function test_endToEndExplicitThenMessageUsesProductEntrypoints() public {
        _installBoth();

        vm.prank(executor);
        agent.dispatchExplicitTrigger();
        assertEq(agent.counter(), 5);
        assertEq(agent.installedBehaviorCount(), 1);
        assertEq(agent.installedBehaviorAt(0), cyclicId);
        assertEq(agent.behaviorImplementation(oneShotId), address(0));
        assertEq(agent.behaviorImplementation(cyclicId), address(cyclic));

        Message memory inbound;
        inbound.conversationId = keccak256("example-message");
        vm.prank(peer);
        agent.handle(inbound);

        assertEq(agent.counter(), 35);
        assertEq(agent.installedBehaviorCount(), 1);
        assertEq(agent.installedBehaviorAt(0), cyclicId);
    }

    function test_cyclicReactsToLaterAuthorizedExplicitTrigger() public {
        vm.prank(admin);
        agent.installCyclicBehavior(cyclicId, address(cyclic));

        vm.prank(executor);
        agent.dispatchExplicitTrigger();
        vm.prank(executor);
        agent.dispatchExplicitTrigger();

        assertEq(agent.counter(), 6);
        assertEq(agent.installedBehaviorCount(), 1);
    }

    function test_unauthorizedExplicitCannotConsumeOneShotOrChangeCounter() public {
        _installBoth();
        vm.prank(stranger);
        vm.expectRevert(ExplicitExecutorGate.UnauthorizedExplicitTrigger.selector);
        agent.dispatchExplicitTrigger();

        assertEq(agent.counter(), 0);
        assertEq(agent.installedBehaviorCount(), 2);
        assertEq(agent.behaviorImplementation(oneShotId), address(oneShot));
    }

    function test_onlyApplicationAdminChangesMembership() public {
        vm.prank(stranger);
        vm.expectRevert(ExampleBehaviorCounterAgent.UnauthorizedBehaviorAdmin.selector);
        agent.installOneShotBehavior(oneShotId, address(oneShot));
        assertEq(agent.installedBehaviorCount(), 0);
    }

    function test_messageTriggerIsAuthenticatedAndAuthorizedNativeTransport() public {
        vm.prank(admin);
        agent.installCyclicBehavior(cyclicId, address(cyclic));
        Message memory inbound;
        inbound.conversationId = keccak256("native-peer");
        vm.prank(peer);
        agent.handle(inbound);
        assertEq(agent.counter(), 30);
    }

    function test_unauthorizedMessageCallerCannotTriggerEffect() public {
        vm.prank(admin);
        agent.installCyclicBehavior(cyclicId, address(cyclic));
        Message memory inbound;
        inbound.conversationId = keccak256("unauthorized-peer");
        vm.prank(stranger);
        vm.expectRevert(ExampleBehaviorCounterAgent.UnauthorizedMessageCaller.selector);
        agent.handle(inbound);
        assertEq(agent.counter(), 0);
        assertEq(agent.installedBehaviorCount(), 1);
    }
}
