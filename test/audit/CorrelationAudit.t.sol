// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NetFixture} from "../protocol/Fixtures.sol";
import {
    AuditNativeManager,
    AuditUniqueManager,
    AuditGeneratedIdManager,
    AuditTokenManager,
    AuditTokenParticipant
} from "../../experiments/audit/ContractNetAlternatives.sol";
import {ExposedContractNetParticipant} from "../ContractNetActors.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";

contract CorrelationAuditTest is NetFixture {
    bytes32 constant ID = bytes32(uint256(1));

    function test_replayOldProposalThroughActualParticipantPrimitive() public {
        Message memory old = _cfp(ID, uint64(block.timestamp + 100));
        manager.cfp(_one(address(p1)), old);
        p1.respond(old, address(manager), _out(old, Performative.Refuse));
        Message memory fresh = _cfp(ID, uint64(block.timestamp + 200));
        fresh.replyWith = bytes32(uint256(99));
        manager.cfp(_one(address(p1)), fresh);
        // No prank: stale application envelope travels through both real protocol primitives.
        p1.respond(old, address(manager), _out(old, Performative.Propose));
        assertEq(manager.slotOf(ID, address(p1)), ContractNetLib.SLOT_PROPOSED);
        assertEq(p1.session(ID).phase, ContractNetLib.PART_PROPOSED);
    }

    function test_replayOldCompletionPrematurelyClosesNewInstance() public {
        Message memory old = _proposeAll(ID, _one(address(p1)));
        manager.evaluate(ID, _one(address(p1)), _empty(), _empty());
        p1.respond(old, address(manager), _out(old, Performative.Inform));
        Message memory fresh = _proposeAll(ID, _one(address(p1)));
        manager.evaluate(ID, _one(address(p1)), _empty(), _empty());
        assertGt(fresh.replyBy, old.replyBy);
        p1.respond(old, address(manager), _out(old, Performative.Inform));
        assertEq(manager.conversation(ID).live, 0);
        assertEq(p1.session(ID).phase, 0);
    }

    function test_uniqueIdsRejectReuseAndOldMessages() public {
        AuditUniqueManager u = new AuditUniqueManager();
        Message memory old = _cfp(ID, uint64(block.timestamp + 100));
        u.cfp(_one(address(p1)), old);
        p1.respond(old, address(u), _out(old, Performative.Refuse));
        vm.expectRevert(bytes("used id"));
        u.cfp(_one(address(p1)), old);
        Message memory fresh = _cfp(bytes32(uint256(2)), uint64(block.timestamp + 100));
        u.cfp(_one(address(p1)), fresh);
        vm.prank(address(p1));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        u.handle(_out(old, Performative.Propose));
        assertEq(u.conversation(fresh.conversationId).live, 1);
    }

    function test_generatedIdsNeedNoPerIdTombstone() public {
        AuditGeneratedIdManager g = new AuditGeneratedIdManager();
        Message memory m = _cfp(bytes32(0), uint64(block.timestamp + 100));
        bytes32 first = g.open(_one(address(p1)), m);
        m.conversationId = first;
        p1.respond(m, address(g), _out(m, Performative.Refuse));
        m.conversationId = bytes32(0);
        bytes32 second = g.open(_one(address(p1)), m);
        assertNotEq(first, second);
        assertEq(g.nonce(), 2);
        assertEq(g.conversation(first).live, 0);
        vm.prank(address(p1));
        vm.expectRevert(ContractNetLib.InvalidTransition.selector);
        m.conversationId = first;
        g.handle(_out(m, Performative.Propose));
    }

    function testFuzz_strictTokensRejectStaleBothDirections(bytes32 wrong) public {
        AuditTokenManager t = new AuditTokenManager();
        AuditTokenParticipant p = new AuditTokenParticipant();
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        m.replyWith = bytes32(0);
        t.cfp(_one(address(p)), m);
        m.replyWith = t.token(ID);
        bytes32 old = m.replyWith;
        p.respond(m, address(t), _out(m, Performative.Refuse));
        m.replyWith = bytes32(0);
        t.cfp(_one(address(p)), m);
        m.replyWith = t.token(ID);
        assertNotEq(old, m.replyWith);
        vm.assume(wrong != m.replyWith);
        Message memory stale = _out(m, Performative.Propose);
        stale.inReplyTo = wrong;
        vm.expectRevert(bytes("token"));
        p.respond(m, address(t), stale);
        vm.prank(address(p));
        vm.expectRevert(bytes("token"));
        t.handle(stale);
        p.respond(m, address(t), _out(m, Performative.Propose));
        Message memory decision = _out(m, Performative.AcceptProposal);
        decision.replyWith = old;
        vm.prank(address(t));
        vm.expectRevert(bytes("token"));
        p.handle(decision);
        vm.warp(block.timestamp + 101);
        t.evaluate(ID, _one(address(p)), _empty(), _empty());
        p.respond(m, address(t), _out(m, Performative.Inform));
        assertEq(t.token(ID), bytes32(0));
        assertEq(p.token(ID), bytes32(0));
        assertEq(t.conversation(ID).live, 0);
    }

    function test_strictTokensBreakLegacyContinuationEnvelopes() public {
        AuditTokenManager t = new AuditTokenManager();
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        m.replyWith = bytes32(0);
        t.cfp(_one(address(p1)), m);
        vm.expectRevert(bytes("token"));
        p1.respond(m, address(t), _out(m, Performative.Propose));
        assertEq(t.slotOf(ID, address(p1)), ContractNetLib.SLOT_INVITED);
    }

    function test_tokenPrototypeInheritedExpiryLeavesAuxiliaryToken() public {
        AuditTokenManager t = new AuditTokenManager();
        AuditTokenParticipant p = new AuditTokenParticipant();
        Message memory m = _cfp(ID, uint64(block.timestamp + 100));
        m.replyWith = bytes32(0);
        t.cfp(_one(address(p)), m);
        bytes32 opened = t.token(ID);
        vm.warp(block.timestamp + 101);
        p.expire(ID);
        assertEq(p.session(ID).phase, 0);
        assertEq(p.token(ID), opened);
        // Demonstrates required expiry-hook integration before any production migration.
        t.evaluate(ID, _empty(), _empty(), _one(address(p)));
        assertEq(t.token(ID), bytes32(0));
    }

    function test_gasGeneratedIdsFirstAndSecondLifecycle() public {
        AuditGeneratedIdManager m = new AuditGeneratedIdManager();
        ExposedContractNetParticipant p = new ExposedContractNetParticipant(address(0));
        for (uint256 i = 1; i <= 2; ++i) {
            Message memory c = _cfp(bytes32(0), uint64(block.timestamp + 100));
            c.replyWith = bytes32(0);
            address[] memory peers = _one(address(p));
            address[] memory empty = _empty();
            uint256 g = gasleft();
            bytes32 id = m.open(peers, c);
            c.conversationId = id;
            p.respond(c, address(m), _out(c, Performative.Propose));
            vm.warp(block.timestamp + 101);
            m.evaluate(id, peers, empty, empty);
            p.respond(c, address(m), _out(c, Performative.Inform));
            emit log_named_uint(
                i == 1 ? "generated first execution" : "generated next execution", g - gasleft()
            );
            assertEq(m.conversation(id).live, 0);
        }
    }

    function test_gasAlternativesFirstAndSecondLifecycle() public {
        // Separate fresh equivalent actors per variant; all measured intervals cover full lifecycle.
        _gasCycle(
            new AuditNativeManager(), new ExposedContractNetParticipant(address(0)), "native", false
        );
        _gasCycle(
            new AuditUniqueManager(), new ExposedContractNetParticipant(address(0)), "unique", false
        );
        _gasCycle(
            new AuditTokenManager(),
            ExposedContractNetParticipant(address(new AuditTokenParticipant())),
            "token",
            true
        );
    }

    function _gasCycle(
        AuditNativeManager m,
        ExposedContractNetParticipant p,
        string memory label,
        bool tokens
    ) internal {
        for (uint256 i = 1; i <= 2; ++i) {
            bytes32 id = bytes32(i);
            Message memory c = _cfp(id, uint64(block.timestamp + 100));
            c.replyWith = bytes32(0);
            address[] memory peers = _one(address(p));
            address[] memory empty = _empty();
            uint256 g = gasleft();
            m.cfp(peers, c);
            if (tokens) c.replyWith = AuditTokenManager(address(m)).token(id);
            p.respond(c, address(m), _out(c, Performative.Propose));
            vm.warp(block.timestamp + 101);
            m.evaluate(id, peers, empty, empty);
            p.respond(c, address(m), _out(c, Performative.Inform));
            emit log_named_uint(
                string.concat(label, i == 1 ? " first execution" : " next execution"), g - gasleft()
            );
            assertEq(m.conversation(id).live, 0);
        }
    }
}
