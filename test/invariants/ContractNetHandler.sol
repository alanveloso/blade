pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";
import {ContractNetManager} from "../../src/core/ContractNetManager.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {
    AutoCompleteParticipant,
    ExposedContractNetManager,
    ExposedContractNetParticipant
} from "../ContractNetActors.sol";

contract ContractNetHandler is Test {
    uint256 internal constant N_IDS = 2;
    bytes internal constant NEEDLE =
        hex"c0ffee01c0ffee02c0ffee03c0ffee04c0ffee05c0ffee06c0ffee07c0ffee08";

    ExposedContractNetManager public manager;
    ExposedContractNetParticipant public p1;
    ExposedContractNetParticipant public p2;
    AutoCompleteParticipant public autoInform;
    ExposedContractNetParticipant public stranger;

    bytes32[N_IDS] internal ids;
    Message[N_IDS] internal lastCfp;
    address[3] internal known;

    uint256 public calls;

    constructor() {
        manager = new ExposedContractNetManager(address(0));
        p1 = new ExposedContractNetParticipant(address(0));
        p2 = new ExposedContractNetParticipant(address(0));
        autoInform = new AutoCompleteParticipant(uint8(Performative.Inform));
        stranger = new ExposedContractNetParticipant(address(0));
        ids[0] = keccak256("inv-cn-0");
        ids[1] = keccak256("inv-cn-1");
        known[0] = address(p1);
        known[1] = address(p2);
        known[2] = address(autoInform);
        vm.warp(1_700_000_000);
    }

    function cfp(uint8 idSel, uint8 mask) external {
        bytes32 id = ids[idSel % N_IDS];
        address[] memory parts = _participants(mask);
        if (parts.length == 0) {
            return;
        }
        Message memory m = _cfp(id, uint64(block.timestamp + 100));
        bytes32 beforeOther = _pack(ids[(uint256(idSel) + 1) % N_IDS]);
        try manager.cfp(parts, m) {
            lastCfp[idSel % N_IDS] = m;
        } catch {}
        assertEq(_pack(ids[(uint256(idSel) + 1) % N_IDS]), beforeOther, "CN-I7 cfp sibling");
        calls++;
    }

    function respond(uint8 idSel, uint8 pSel, uint8 actSel) external {
        uint256 i = idSel % N_IDS;
        bytes32 id = ids[i];
        ExposedContractNetParticipant p = _part(pSel);
        Performative act = _act(actSel);
        Message memory inbound = lastCfp[i];
        if (inbound.conversationId == bytes32(0)) {
            inbound = _cfp(id, uint64(block.timestamp + 1));
        }
        Message memory outbound;
        outbound.performative = uint8(act);
        outbound.protocol = uint8(Protocol.FipaContractNet);
        outbound.conversationId = id;
        outbound.inReplyTo = inbound.replyWith;
        bytes32 beforeOther = _pack(ids[(i + 1) % N_IDS]);
        address other = known[(uint256(pSel) + 1) % 3];
        uint8 slotPeer = manager.slotOf(id, other);
        try p.respond(inbound, address(manager), outbound) {} catch {}
        assertEq(_pack(ids[(i + 1) % N_IDS]), beforeOther, "CN-I7 respond sibling");
        assertEq(manager.slotOf(id, other), slotPeer, "CN-I6 other slot");
        calls++;
    }

    function warpAroundDeadline(uint8 idSel, uint8 mode) external {
        uint64 by = manager.conversation(ids[idSel % N_IDS]).replyBy;
        if (by == 0) {
            return;
        }
        if (mode % 3 == 0) {
            vm.warp(uint256(by) > 0 ? uint256(by) - 1 : uint256(by));
        } else if (mode % 3 == 1) {
            vm.warp(uint256(by));
        } else {
            vm.warp(uint256(by) + 1);
        }
        calls++;
    }

    function evaluate(uint8 idSel, uint8 mode) external {
        bytes32 id = ids[idSel % N_IDS];
        ContractNetManager.Conversation memory c = manager.conversation(id);
        if (c.live == 0) {
            return;
        }
        address[] memory acc;
        address[] memory rej;
        address[] memory sil;
        (acc, rej, sil) = _partition(id, mode);
        bytes32 beforeOther = _pack(ids[(uint256(idSel) + 1) % N_IDS]);
        try manager.evaluate(id, acc, rej, sil) {} catch {}
        assertEq(_pack(ids[(uint256(idSel) + 1) % N_IDS]), beforeOther, "CN-I7 evaluate sibling");
        calls++;
    }

    function strangerPropose(uint8 idSel) external {
        bytes32 id = ids[idSel % N_IDS];
        bytes32 before = _pack(id);
        Message memory m;
        m.performative = uint8(Performative.Propose);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        vm.prank(address(stranger));
        try manager.handle(m) {} catch {}
        assertEq(_pack(id), before, "non-invited mutated");
        calls++;
    }

    function expire(uint8 idSel, uint8 pSel) external {
        bytes32 id = ids[idSel % N_IDS];
        ExposedContractNetParticipant p = _part(pSel);
        uint8 phaseBefore = p.session(id).phase;
        uint64 by = p.session(id).replyBy;
        bytes32 beforeOther = _pack(ids[(uint256(idSel) + 1) % N_IDS]);
        try p.expire(id) {
            assertEq(phaseBefore, ContractNetLib.PART_CFPED, "expire only CFPED");
            assertTrue(block.timestamp > by, "expire only after replyBy");
            assertEq(p.session(id).phase, ContractNetLib.PART_NONE);
        } catch {
            if (phaseBefore == ContractNetLib.PART_CFPED && by != 0 && block.timestamp > by) {
                revert("expire should have succeeded");
            }
        }
        assertEq(_pack(ids[(uint256(idSel) + 1) % N_IDS]), beforeOther, "CN-I7 expire sibling");
        calls++;
    }

    function tryInvalidParticipants(uint8 idSel) external {
        bytes32 id = ids[idSel % N_IDS];
        bytes32 before = _pack(id);
        address[] memory z = new address[](1);
        z[0] = address(0);
        try manager.cfp(z, _cfp(id, uint64(block.timestamp + 10))) {
            revert("zero participant accepted");
        } catch {}
        address[] memory eoa = new address[](1);
        eoa[0] = address(0xBEEF);
        try manager.cfp(eoa, _cfp(id, uint64(block.timestamp + 10))) {
            revert("eoa participant accepted");
        } catch {}
        assertEq(_pack(id), before, "invalid cfp mutated");
        calls++;
    }

    function assertContractNetInvariants() external view {
        for (uint256 i = 0; i < N_IDS; i++) {
            _assertLive(ids[i]);
        }
        _assertNoNeedle(address(manager));
        _assertNoNeedle(address(p1));
        _assertNoNeedle(address(p2));
        _assertNoNeedle(address(autoInform));
    }

    function _assertLive(bytes32 id) internal view {
        ContractNetManager.Conversation memory c = manager.conversation(id);
        uint32 counted;
        for (uint256 i = 0; i < 3; i++) {
            uint8 slot = manager.slotOf(id, known[i]);
            if (slot != ContractNetLib.SLOT_NONE) {
                counted++;
                assertTrue(slot <= ContractNetLib.SLOT_ACCEPTED, "CN-I4 bad slot");
            }
            uint8 phase = _session(known[i], id);
            if (slot == ContractNetLib.SLOT_NONE) {
                // Silent evaluate deletes the manager slot without an ACL act (TCN1).
                // Participant may remain CFPED; they are not live.
                assertTrue(
                    phase == ContractNetLib.PART_NONE || phase == ContractNetLib.PART_CFPED,
                    "CN-I3/I9 unexpected leftover"
                );
            } else if (slot == ContractNetLib.SLOT_INVITED) {
                assertTrue(
                    phase == ContractNetLib.PART_CFPED || phase == ContractNetLib.PART_NONE,
                    "invited/session"
                );
            } else if (slot == ContractNetLib.SLOT_PROPOSED) {
                assertEq(phase, ContractNetLib.PART_PROPOSED, "CN-I4");
            } else if (slot == ContractNetLib.SLOT_ACCEPTED) {
                assertEq(phase, ContractNetLib.PART_ACCEPTED, "CN-I5");
            }
        }
        assertEq(c.live, counted, "CN-I1 live vs slots");
        if (counted == 0) {
            assertEq(c.invited, 0, "CN-I8 leftover invited");
            assertEq(c.replyBy, 0, "CN-I8 leftover replyBy");
            assertFalse(c.evaluated, "CN-I8 leftover evaluated");
        }
    }

    function _session(address p, bytes32 id) internal view returns (uint8) {
        if (p == address(p1)) return p1.session(id).phase;
        if (p == address(p2)) return p2.session(id).phase;
        return autoInform.session(id).phase;
    }

    function _participants(uint8 mask) internal view returns (address[] memory parts) {
        uint256 n;
        if (mask & 1 != 0) n++;
        if (mask & 2 != 0) n++;
        if (mask & 4 != 0) n++;
        parts = new address[](n);
        uint256 k;
        if (mask & 1 != 0) parts[k++] = address(p1);
        if (mask & 2 != 0) parts[k++] = address(p2);
        if (mask & 4 != 0) parts[k++] = address(autoInform);
    }

    function _part(uint8 sel) internal view returns (ExposedContractNetParticipant) {
        uint256 i = sel % 3;
        if (i == 0) return p1;
        if (i == 1) return p2;
        return autoInform;
    }

    function _act(uint8 sel) internal pure returns (Performative) {
        uint256 i = sel % 6;
        if (i == 0) return Performative.Propose;
        if (i == 1) return Performative.Refuse;
        if (i == 2) return Performative.Inform;
        if (i == 3) return Performative.Failure;
        if (i == 4) return Performative.NotUnderstood;
        return Performative.RejectProposal;
    }

    function _cfp(bytes32 id, uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = id;
        m.replyWith = keccak256(abi.encodePacked(id, "rw"));
        m.replyBy = replyBy;
        m.content = NEEDLE;
    }

    function _partition(bytes32 id, uint8 mode)
        internal
        view
        returns (address[] memory acc, address[] memory rej, address[] memory sil)
    {
        address[] memory proposed = new address[](3);
        address[] memory invited = new address[](3);
        uint256 np;
        uint256 ni;
        for (uint256 i = 0; i < 3; i++) {
            uint8 slot = manager.slotOf(id, known[i]);
            if (slot == ContractNetLib.SLOT_PROPOSED) {
                proposed[np++] = known[i];
            } else if (slot == ContractNetLib.SLOT_INVITED) {
                invited[ni++] = known[i];
            }
        }
        sil = new address[](ni);
        for (uint256 i = 0; i < ni; i++) {
            sil[i] = invited[i];
        }
        if (mode % 2 == 0) {
            acc = new address[](np);
            rej = new address[](0);
            for (uint256 i = 0; i < np; i++) {
                acc[i] = proposed[i];
            }
        } else {
            acc = new address[](0);
            rej = new address[](np);
            for (uint256 i = 0; i < np; i++) {
                rej[i] = proposed[i];
            }
        }
    }

    function _pack(bytes32 id) internal view returns (bytes32) {
        ContractNetManager.Conversation memory c = manager.conversation(id);
        return keccak256(
            abi.encode(
                c.replyBy,
                c.evaluated,
                c.live,
                c.invited,
                manager.slotOf(id, address(p1)),
                manager.slotOf(id, address(p2)),
                manager.slotOf(id, address(autoInform)),
                p1.session(id).phase,
                p2.session(id).phase,
                autoInform.session(id).phase
            )
        );
    }

    function _assertNoNeedle(address target) internal view {
        bytes32 n = bytes32(NEEDLE);
        for (uint256 i = 0; i < 16; i++) {
            assertTrue(vm.load(target, bytes32(i)) != n);
        }
    }
}
