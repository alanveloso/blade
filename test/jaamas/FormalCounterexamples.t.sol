// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {RequestProperties} from "../../formal/RequestProperties.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {Agent} from "../../src/core/Agent.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Message} from "../../src/core/Message.sol";

/// @dev Concrete replay of CHC candidates. Revert shows these traces do not violate assertions
/// on the EVM; it does NOT establish universal correctness of the assertions.
contract FormalCounterexamplesTest is Test {
    function test_transitionCounterexamplesActuallyRevert() public {
        RequestProperties h = new RequestProperties(address(0));
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        h.participantCannotContinue(RequestPhase.None, Performative.Cancel);
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        h.participantCannotContinue(RequestPhase.None, Performative.Request);
        vm.expectRevert(RequestAgent.InvalidTransition.selector);
        h.agreeRequiresRequested(RequestPhase.Terminal, Performative.Request);
    }

    function test_authorizationCounterexamplesActuallyRevert() public {
        RequestProperties h = new RequestProperties(address(1));
        Message memory m;
        m.logicalSender = bytes32(uint256(0x52f7));
        vm.prank(address(0));
        vm.expectRevert(Agent.UnauthorizedLogicalSender.selector);
        h.authorization(m);
        m.logicalSender = bytes32(0);
        vm.prank(address(1));
        vm.expectRevert(Agent.RelayMustSetLogicalSender.selector);
        h.authorization(m);
    }

    function test_validPathsReachAssertions() public {
        RequestProperties h = new RequestProperties(address(0));
        h.participantCannotContinue(RequestPhase.Requested, Performative.NotUnderstood);
        h.agreeRequiresRequested(RequestPhase.Requested, Performative.Agree);
        Message memory m;
        h.authorization(m);
        h.correlation(
            bytes32(uint256(1)), bytes32(uint256(2)), true, bytes32(uint256(2)), bytes32(0)
        );
        h.peer(bytes32(uint256(1)), address(this), bytes32(0), m);
    }
}
