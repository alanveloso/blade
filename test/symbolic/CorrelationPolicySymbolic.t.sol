// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NetFixture} from "../protocol/Fixtures.sol";
import {
    AuditUniqueManager,
    AuditTokenManager,
    AuditTokenParticipant
} from "../../experiments/audit/ContractNetAlternatives.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";

contract CorrelationPolicyBytecodeProof is NetFixture {
    function check_uniquePolicyNeverReopens(bytes32 id) public {
        vm.assume(id != bytes32(0));
        AuditUniqueManager u = new AuditUniqueManager();
        Message memory m = _cfp(id, uint64(block.timestamp + 100));
        u.cfp(_one(address(p1)), m);
        p1.respond(m, address(u), _out(m, Performative.Refuse));
        (bool ok,) = address(u).call(abi.encodeCall(u.cfp, (_one(address(p1)), m)));
        assert(!ok);
        assert(u.used(id));
        assert(u.conversation(id).live == 0);
    }

    function check_strictParticipantRejectsWrongInstance(bytes32 wrong) public {
        AuditTokenManager t = new AuditTokenManager();
        AuditTokenParticipant p = new AuditTokenParticipant();
        bytes32 id = bytes32(uint256(1));
        Message memory m = _cfp(id, uint64(block.timestamp + 100));
        m.replyWith = bytes32(0);
        t.cfp(_one(address(p)), m);
        m.replyWith = t.token(id);
        vm.assume(wrong != m.replyWith);
        Message memory response = _out(m, Performative.Propose);
        response.inReplyTo = wrong;
        (bool ok,) = address(p).call(abi.encodeCall(p.respond, (m, address(t), response)));
        assert(!ok);
        assert(t.slotOf(id, address(p)) == ContractNetLib.SLOT_INVITED);
        assert(p.session(id).phase == ContractNetLib.PART_CFPED);
    }

    function check_strictManagerRejectsWrongInstance(bytes32 wrong) public {
        AuditTokenManager t = new AuditTokenManager();
        AuditTokenParticipant p = new AuditTokenParticipant();
        bytes32 id = bytes32(uint256(1));
        Message memory m = _cfp(id, uint64(block.timestamp + 100));
        m.replyWith = bytes32(0);
        t.cfp(_one(address(p)), m);
        vm.assume(wrong != t.token(id));
        Message memory response = _out(m, Performative.Propose);
        response.inReplyTo = wrong;
        vm.prank(address(p));
        (bool ok,) = address(t).call(abi.encodeCall(t.handle, (response)));
        assert(!ok);
        assert(t.slotOf(id, address(p)) == ContractNetLib.SLOT_INVITED);
    }
}
