// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NetFixture} from "./Fixtures.sol";
import {QueuedContractNetManager} from "../../experiments/QueuedContractNetManager.sol";
import {
    RevertOnDecisionParticipant,
    GasBurnerParticipant,
    ExposedContractNetParticipant
} from "../ContractNetActors.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";

contract QueuedContractNetTest is NetFixture {
    function prepare(QueuedContractNetManager q, address bad, bytes32 id)
        internal
        returns (Message memory cfp)
    {
        cfp = _cfp(id, uint64(block.timestamp + 100));
        q.cfp(_two(address(p1), bad), cfp);
        p1.respond(cfp, address(q), _out(cfp, Performative.Propose));
        ExposedContractNetParticipant(bad).respond(cfp, address(q), _out(cfp, Performative.Propose));
        vm.warp(block.timestamp + 101);
    }

    function test_queueIsolatesRevertAndAllowsHonestCompletion() public {
        QueuedContractNetManager q = new QueuedContractNetManager();
        RevertOnDecisionParticipant bad = new RevertOnDecisionParticipant();
        bytes32 id = keccak256("queued");
        Message memory cfp = prepare(q, address(bad), id);
        q.evaluate(id, _one(address(p1)), _one(address(bad)), _empty());
        vm.expectRevert(bytes("decision-revert"));
        q.deliver(id, address(bad));
        assertEq(q.pendingCount(id), 2);
        q.deliver(id, address(p1));
        p1.respond(cfp, address(q), _out(cfp, Performative.Inform));
        assertEq(q.conversation(id).live, 0);
        assertEq(q.pendingCount(id), 1);
        vm.expectRevert(bytes("pending decisions"));
        q.cfp(_one(address(p1)), cfp);
        vm.expectRevert(bytes("no decision"));
        q.deliver(id, address(p1));
    }

    function test_queueIsolatesGasExhaustion() public {
        QueuedContractNetManager q = new QueuedContractNetManager();
        GasBurnerParticipant bad = new GasBurnerParticipant(0);
        bytes32 id = keccak256("queued-gas");
        Message memory cfp = prepare(q, address(bad), id);
        q.evaluate(id, _two(address(p1), address(bad)), _empty(), _empty());
        (bool ok,) = address(q).call{gas: 200_000}(abi.encodeCall(q.deliver, (id, address(bad))));
        assertFalse(ok);
        assertEq(q.pendingCount(id), 2);
        q.deliver(id, address(p1));
        p1.respond(cfp, address(q), _out(cfp, Performative.Inform));
        assertEq(q.slotOf(id, address(p1)), ContractNetLib.SLOT_NONE);
        assertEq(q.conversation(id).live, 1); // accepted griefer remains; not global liveness
    }

    function test_gasEquivalentHonestDecisions() public {
        bytes32 id = keccak256("equivalent");
        uint256 initial = vm.snapshotState();
        Message memory cfp = _proposeAll(id, _two(address(p1), address(p2)));
        uint256 g = gasleft();
        manager.evaluate(id, _one(address(p1)), _one(address(p2)), _empty());
        emit log_named_uint("sync evaluate execution", g - gasleft());
        p1.respond(cfp, address(manager), _out(cfp, Performative.Inform));
        assertTrue(vm.revertToState(initial));
        QueuedContractNetManager q = new QueuedContractNetManager();
        cfp = prepare(q, address(p2), id);
        g = gasleft();
        q.evaluate(id, _one(address(p1)), _one(address(p2)), _empty());
        uint256 staged = g - gasleft();
        emit log_named_uint("queue evaluate execution", staged);
        g = gasleft();
        q.deliver(id, address(p2));
        q.deliver(id, address(p1));
        uint256 delivery = g - gasleft();
        emit log_named_uint("queue two deliveries execution", delivery);
        emit log_named_uint("queue total execution", staged + delivery);
        p1.respond(cfp, address(q), _out(cfp, Performative.Inform));
        assertEq(q.conversation(id).live, 0);
        assertEq(q.pendingCount(id), 0);
    }
}
