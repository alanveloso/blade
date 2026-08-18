pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    ExternalApplicationBehaviorHost
} from "../../src/behavior/ExternalApplicationBehaviorHost.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {Message} from "../../src/core/Message.sol";

/// @dev Mixin-only: proves the host does not require `Agent`.
contract HostHarness is ExternalApplicationBehaviorHost {
    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function uninstallBehavior(bytes32 localId) external {
        _uninstallBehavior(localId);
    }
}

contract ComposedAgent is Agent, ExternalApplicationBehaviorHost {
    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }

    function uninstallBehavior(bytes32 localId) external {
        _uninstallBehavior(localId);
    }
}

contract ComposedRequest is RequestAgent, ExternalApplicationBehaviorHost {
    constructor() Agent(address(0)) {}

    function installBehavior(bytes32 localId, address implementation) external {
        _installBehavior(localId, implementation);
    }
}

contract ExternalApplicationBehaviorHostTest is Test {
    HostHarness internal host;
    HostHarness internal hostB;
    ComposedAgent internal composed;
    ComposedRequest internal requester;

    bytes32 internal idX;
    bytes32 internal idY;
    address internal strategyS;
    address internal strategyS2;

    function setUp() public {
        host = new HostHarness();
        hostB = new HostHarness();
        composed = new ComposedAgent();
        requester = new ComposedRequest();
        idX = keccak256("X");
        idY = keccak256("Y");
        strategyS = makeAddr("S");
        strategyS2 = makeAddr("S2");
    }

    function test_installLookupUninstallRoundTrip() public {
        vm.expectEmit(true, false, false, true, address(host));
        emit ExternalApplicationBehaviorHost.BehaviorInstalled(idX, strategyS);
        host.installBehavior(idX, strategyS);
        assertEq(host.behaviorImplementation(idX), strategyS);

        vm.expectEmit(true, false, false, true, address(host));
        emit ExternalApplicationBehaviorHost.BehaviorUninstalled(idX, strategyS);
        host.uninstallBehavior(idX);
        assertEq(host.behaviorImplementation(idX), address(0));
    }

    function test_sameAgentTwoIdsSameStrategy() public {
        host.installBehavior(idX, strategyS);
        host.installBehavior(idY, strategyS);
        assertEq(host.behaviorImplementation(idX), strategyS);
        assertEq(host.behaviorImplementation(idY), strategyS);
        assertTrue(idX != idY);
    }

    function test_twoHostsSameLocalIdAreIndependent() public {
        host.installBehavior(idX, strategyS);
        hostB.installBehavior(idX, strategyS2);
        assertEq(host.behaviorImplementation(idX), strategyS);
        assertEq(hostB.behaviorImplementation(idX), strategyS2);
    }

    function test_zeroLocalIdReverts() public {
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidLocalId.selector);
        host.installBehavior(bytes32(0), strategyS);
    }

    function test_zeroImplementationReverts() public {
        vm.expectRevert(ExternalApplicationBehaviorHost.InvalidImplementation.selector);
        host.installBehavior(idX, address(0));
    }

    function test_eoaImplementationIsAllowedAssociation() public {
        host.installBehavior(idX, strategyS);
        assertEq(strategyS.code.length, 0);
        assertEq(host.behaviorImplementation(idX), strategyS);
    }

    function test_occupiedIdReverts() public {
        host.installBehavior(idX, strategyS);
        vm.expectRevert(ExternalApplicationBehaviorHost.AlreadyInstalled.selector);
        host.installBehavior(idX, strategyS2);
        assertEq(host.behaviorImplementation(idX), strategyS);
    }

    function test_uninstallThenReinstallDifferentStrategy() public {
        host.installBehavior(idX, strategyS);
        host.uninstallBehavior(idX);
        host.installBehavior(idX, strategyS2);
        assertEq(host.behaviorImplementation(idX), strategyS2);
    }

    function test_uninstallNotInstalledReverts() public {
        vm.expectRevert(ExternalApplicationBehaviorHost.NotInstalled.selector);
        host.uninstallBehavior(idX);
    }

    function test_composedAgentStillHandles() public {
        composed.installBehavior(idX, strategyS);
        assertEq(composed.behaviorImplementation(idX), strategyS);
        Message memory m;
        m.conversationId = keccak256("composed-handle");
        composed.handle(m);
        assertEq(composed.behaviorImplementation(idX), strategyS);
        assertEq(composed.trustedRelay(), address(0));
    }

    function test_composedRequestInstallDoesNotCreateSession() public {
        bytes32 conversationId = keccak256("not-a-request");
        requester.installBehavior(idX, strategyS);
        RequestAgent.Status memory st = requester.requestStatus(conversationId);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
        Message memory m;
        m.conversationId = conversationId;
        requester.handle(m);
        st = requester.requestStatus(conversationId);
        assertEq(uint8(st.phase), uint8(RequestPhase.None));
        assertEq(requester.behaviorImplementation(idX), strategyS);
    }

    function test_snapshotAgentHasNoInstallApi() public {
        Agent bare = new Agent(address(0));
        (bool ok,) = address(bare)
            .call(abi.encodeWithSignature("installBehavior(bytes32,address)", idX, strategyS));
        assertFalse(ok);
        (ok,) = address(bare).call(abi.encodeWithSignature("behaviorImplementation(bytes32)", idX));
        assertFalse(ok);
    }
}
