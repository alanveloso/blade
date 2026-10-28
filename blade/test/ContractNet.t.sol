pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {ExposedContractNetManager, ExposedContractNetParticipant} from "./ContractNetActors.sol";

contract ContractNetTest is Test {
    ExposedContractNetManager internal manager;
    ExposedContractNetParticipant internal p1;
    ExposedContractNetParticipant internal p2;
    ExposedContractNetParticipant internal p3;
    ExposedContractNetParticipant internal p4;

    bytes internal constant UNIQUE =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    function setUp() public {
        manager = new ExposedContractNetManager(address(0));
        p1 = new ExposedContractNetParticipant(address(0));
        p2 = new ExposedContractNetParticipant(address(0));
        p3 = new ExposedContractNetParticipant(address(0));
        p4 = new ExposedContractNetParticipant(address(0));
        vm.warp(1_700_000_000);
    }

    function _cfp(bytes32 id, uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        m.replyWith = keccak256(abi.encodePacked(id, "rw"));
        m.replyBy = replyBy;
        m.content = UNIQUE;
    }

    function _out(Message memory inbound, Performative act)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(act);
        m.protocol = inbound.protocol;
        m.conversationId = inbound.conversationId;
        m.inReplyTo = inbound.replyWith;
    }

    function _parts2() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = address(p1);
        a[1] = address(p2);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 100);
    }

    function _assertNoContent(address target) internal view {
        bytes32 needle = bytes32(UNIQUE);
        for (uint256 i = 0; i < 16; i++) {
            assertTrue(vm.load(target, bytes32(i)) != needle);
        }
    }

    function test_cfpMultipleSameConversationId() public {
        bytes32 id = keccak256("cn1");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        assertEq(manager.conversation(id).invited, 2);
        assertEq(manager.conversation(id).live, 2);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_INVITED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_INVITED);
        assertEq(p1.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(p2.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(p1.session(id).manager, address(manager));
        _assertNoContent(address(manager));
        _assertNoContent(address(p1));
    }

    function test_proposeBeforeDeadline() public {
        bytes32 id = keccak256("cn2");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(p1.session(id).phase, ContractNetLib.PART_PROPOSED);
    }

    function test_refuse() public {
        bytes32 id = keccak256("cn3");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.conversation(id).live, 1);
    }

    function test_mixedProposeRefuse() public {
        bytes32 id = keccak256("cn4");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_NONE);
    }

    function test_lateProposeRejected() public {
        bytes32 id = keccak256("cn5");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_parts2(), cfp);
        vm.warp(uint256(by) + 1);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(manager.conversation(id).live, 1);
    }

    function test_evaluateBeforeDeadlineReverts() public {
        bytes32 id = keccak256("cn6");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        address[] memory acc = new address[](1);
        acc[0] = address(p1);
        address[] memory rej = new address[](1);
        rej[0] = address(p2);
        address[] memory silent = new address[](0);
        vm.expectRevert(ContractNetLib.EvaluationTooEarly.selector);
        manager.evaluate(id, acc, rej, silent);
    }

    function test_evaluateAfterDeadlineOneAndMultipleAndZero() public {
        // one selected
        bytes32 id = keccak256("cn7");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        address[] memory acc = new address[](1);
        acc[0] = address(p1);
        address[] memory rej = new address[](1);
        rej[0] = address(p2);
        address[] memory silent = new address[](0);
        manager.evaluate(id, acc, rej, silent);
        assertEq(manager.slotOf(id, address(p1)), ContractNetLib.SLOT_ACCEPTED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_NONE);
        assertEq(p1.session(id).phase, ContractNetLib.PART_ACCEPTED);
        assertEq(p2.session(id).phase, ContractNetLib.PART_NONE);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
        assertEq(manager.conversation(id).invited, 0);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_multipleAcceptedThenFailure() public {
        bytes32 id = keccak256("cn8");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        address[] memory acc = _parts2();
        address[] memory none = new address[](0);
        manager.evaluate(id, acc, none, none);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Failure));
        assertEq(manager.conversation(id).live, 0);
        assertEq(manager.conversation(id).invited, 0);
        _assertNoContent(address(manager));
    }

    function test_zeroProposalsSelected() public {
        bytes32 id = keccak256("cn9");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        address[] memory none = new address[](0);
        manager.evaluate(id, none, _parts2(), none);
        assertEq(manager.conversation(id).invited, 0);
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(p2.session(id).phase, ContractNetLib.PART_NONE);
    }

    function test_silentNonResponderClosedOnEvaluate() public {
        bytes32 id = keccak256("cn10");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        address[] memory acc = new address[](1);
        acc[0] = address(p1);
        address[] memory silent = new address[](1);
        silent[0] = address(p2);
        address[] memory none = new address[](0);
        manager.evaluate(id, acc, none, silent);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_NONE);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
        assertEq(manager.conversation(id).invited, 0);
    }

    function test_invalidTransitionDuplicatePropose() public {
        bytes32 id = keccak256("cn11");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
    }

    function test_unexpectedPeer() public {
        bytes32 id = keccak256("cn12");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        vm.prank(address(p3));
        vm.expectRevert(ContractNetLib.UnexpectedPeer.selector);
        manager.handle(_out(cfp, Performative.Propose));
    }

    function test_cfpRequiresReplyBy() public {
        Message memory cfp = _cfp(keccak256("cn13"), 0);
        vm.expectRevert(ContractNetLib.ReplyByRequired.selector);
        manager.cfp(_parts2(), cfp);
    }

    function test_notUnderstoodOnlyOneParticipant() public {
        bytes32 id = keccak256("cn14");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.NotUnderstood));
        assertEq(p1.session(id).phase, ContractNetLib.PART_NONE);
        assertEq(p2.session(id).phase, ContractNetLib.PART_CFPED);
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_INVITED);
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        assertEq(manager.slotOf(id, address(p2)), ContractNetLib.SLOT_PROPOSED);
    }

    function test_independentConversations() public {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        Message memory cfpA = _cfp(a, _deadline());
        Message memory cfpB = _cfp(b, _deadline());
        address[] memory only1 = new address[](1);
        only1[0] = address(p1);
        address[] memory only2 = new address[](1);
        only2[0] = address(p2);
        manager.cfp(only1, cfpA);
        manager.cfp(only2, cfpB);
        p1.respond(cfpA, address(manager), _out(cfpA, Performative.Refuse));
        assertEq(p2.session(b).phase, ContractNetLib.PART_CFPED);
        assertEq(manager.conversation(b).live, 1);
        assertEq(manager.conversation(a).invited, 0);
    }

    function test_informWithoutAcceptReverts() public {
        bytes32 id = keccak256("cn15");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
    }

    function test_snapshot_cfpN1() public {
        address[] memory a = new address[](1);
        a[0] = address(p1);
        manager.cfp(a, _cfp(keccak256("s1"), _deadline()));
    }

    function test_snapshot_cfpN2() public {
        manager.cfp(_parts2(), _cfp(keccak256("s2"), _deadline()));
    }

    function test_snapshot_cfpN4() public {
        address[] memory a = new address[](4);
        a[0] = address(p1);
        a[1] = address(p2);
        a[2] = address(p3);
        a[3] = address(p4);
        manager.cfp(a, _cfp(keccak256("s4"), _deadline()));
    }

    function test_snapshot_proposeRefuse() public {
        bytes32 id = keccak256("sp");
        Message memory cfp = _cfp(id, _deadline());
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Refuse));
    }

    function test_snapshot_evaluateAcceptRejectInform() public {
        bytes32 id = keccak256("se");
        uint64 by = _deadline();
        Message memory cfp = _cfp(id, by);
        manager.cfp(_parts2(), cfp);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        p2.respond(cfp, address(manager), _out(cfp, Performative.Propose));
        vm.warp(uint256(by) + 1);
        address[] memory acc = new address[](1);
        acc[0] = address(p1);
        address[] memory rej = new address[](1);
        rej[0] = address(p2);
        address[] memory silent = new address[](0);
        manager.evaluate(id, acc, rej, silent);
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
    }
}
