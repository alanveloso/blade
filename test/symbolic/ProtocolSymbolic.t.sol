// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {QueuedContractNetManager} from "../../experiments/QueuedContractNetManager.sol";
import {Test} from "forge-std/Test.sol";
import {ScriptedRequestAgent} from "../Request.t.sol";
import {SubscriptionActor} from "../protocol/Subscribe.t.sol";
import {NetFixture} from "../protocol/Fixtures.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestPhase} from "../../src/core/RequestAgent.sol";
import {SubscribePhase} from "../../src/core/SubscribeAgent.sol";
import {Message} from "../../src/core/Message.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {Performative} from "../../src/core/Performative.sol";
import {ContractNetLib} from "../../src/core/ContractNetLib.sol";

/// @dev Bounded symbolic proofs over compiled runtime bytecode and real reachable setup.
/// check_* functions are run by Halmos, not counted as Forge tests.
contract RequestBytecodeProof is Test {
    ScriptedRequestAgent a;
    ScriptedRequestAgent b;
    bytes32 constant ID = bytes32(uint256(1));

    function setUp() public {
        a = new ScriptedRequestAgent(address(0));
        b = new ScriptedRequestAgent(address(0));
        Message memory m;
        m.protocol = uint8(Protocol.FipaRequest);
        m.performative = uint8(Performative.Request);
        m.conversationId = ID;
        a.startRequest(address(b), m);
        m.conversationId = bytes32(uint256(2));
        a.startRequest(address(b), m);
    }

    function response(uint8 act, bytes32 token) internal pure returns (Message memory m) {
        m.protocol = uint8(Protocol.FipaRequest);
        m.performative = act;
        m.conversationId = ID;
        m.inReplyTo = token;
    }

    function check_peerTokenIsolation(address caller, bytes32 token) public {
        bytes32 expected = a.requestStatus(ID).replyWith;
        bytes32 other = keccak256(abi.encode(a.requestStatus(bytes32(uint256(2)))));
        vm.prank(caller);
        (bool ok,) =
            address(a).call(abi.encodeCall(a.handle, (response(uint8(Performative.Agree), token))));
        assert(ok == (caller == address(b) && token == expected));
        assert(a.requestStatus(ID).phase == (ok ? RequestPhase.Agreed : RequestPhase.Requested));
        assert(keccak256(abi.encode(a.requestStatus(bytes32(uint256(2))))) == other);
    }

    function check_requestedTransition(uint8 act) public {
        Message memory m = response(act, a.requestStatus(ID).replyWith);
        vm.prank(address(b));
        (bool ok,) = address(a).call(abi.encodeCall(a.handle, (m)));
        bool terminal = act == uint8(Performative.Inform) || act == uint8(Performative.Failure)
            || act == uint8(Performative.Refuse) || act == uint8(Performative.NotUnderstood);
        assert(ok == (terminal || act == uint8(Performative.Agree)));
        if (terminal) {
            assert(a.requestStatus(ID).phase == RequestPhase.None);
        } else {
            assert(a.requestStatus(ID).phase == (ok ? RequestPhase.Agreed : RequestPhase.Requested));
        }
    }

    function check_authenticatedIdentity(address caller, bytes32 logical) public {
        Agent endpoint = new Agent(address(0xbeef));
        Message memory m;
        m.logicalSender = logical;
        vm.prank(caller);
        (bool ok,) = address(endpoint).call(abi.encodeCall(endpoint.handle, (m)));
        assert(ok == (caller == address(0xbeef) ? logical != bytes32(0) : logical == bytes32(0)));
    }
}

contract SubscribeBytecodeProof is Test {
    SubscriptionActor a;
    SubscriptionActor b;
    bytes32 constant ID = bytes32(uint256(1));

    function setUp() public {
        a = new SubscriptionActor();
        b = new SubscriptionActor();
        a.start(address(b), ID);
        b.act(ID, Performative.Agree);
        a.start(address(b), bytes32(uint256(2)));
    }

    function check_cancelAcknowledgement(bytes32 token) public {
        a.act(ID, Performative.Cancel);
        bytes32 expected = a.subscription(ID).cancelToken;
        Message memory m;
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(Performative.Inform);
        m.conversationId = ID;
        m.inReplyTo = token;
        vm.prank(address(b));
        (bool ok,) = address(a).call(abi.encodeCall(a.handle, (m)));
        assert(ok == (token == expected));
        assert(a.subscription(ID).phase == (ok ? SubscribePhase.None : SubscribePhase.Cancelling));
        assert(a.subscription(bytes32(uint256(2))).phase == SubscribePhase.Pending);
    }

    function check_failureRollback(uint8 act) public {
        vm.assume(act <= uint8(Performative.Subscribe));
        a.reject(true);
        bytes32 beforeA = keccak256(abi.encode(a.subscription(ID)));
        bytes32 beforeB = keccak256(abi.encode(b.subscription(ID)));
        (bool ok,) = address(b).call(abi.encodeCall(b.act, (ID, Performative(act))));
        assert(!ok);
        assert(keccak256(abi.encode(a.subscription(ID))) == beforeA);
        assert(keccak256(abi.encode(b.subscription(ID))) == beforeB);
    }

    function check_cancelFailureRestoresOpening() public {
        bytes32 pending = bytes32(uint256(2));
        a.act(pending, Performative.Cancel);
        b.act(pending, Performative.Failure);
        assert(a.subscription(pending).phase == SubscribePhase.Pending);
        assert(b.subscription(pending).phase == SubscribePhase.Pending);
        assert(a.subscription(pending).cancelToken == bytes32(0));
    }
}

contract ContractNetBytecodeProof is NetFixture {
    bytes32 internal openedId;

    function setUp() public override {
        super.setUp();
        (openedId,) = _open(_one(address(p1)), uint64(block.timestamp + 100));
    }

    function check_proposerAuthorization(address caller) public {
        Message memory m;
        m.protocol = uint8(Protocol.FipaContractNet);
        m.performative = uint8(Performative.Propose);
        m.conversationId = openedId;
        vm.prank(caller);
        (bool ok,) = address(manager).call(abi.encodeCall(manager.handle, (m)));
        assert(ok == (caller == address(p1)));
        assert(manager.conversation(openedId).live == 1);
        assert(
            manager.slotOf(openedId, address(p1))
                == (ok ? ContractNetLib.SLOT_PROPOSED : ContractNetLib.SLOT_INVITED)
        );
    }

    function check_uninvitedConversationIsolated(bytes32 id) public {
        vm.assume(id != openedId);
        Message memory m;
        m.protocol = uint8(Protocol.FipaContractNet);
        m.performative = uint8(Performative.Propose);
        m.conversationId = id;
        vm.prank(address(p1));
        (bool ok,) = address(manager).call(abi.encodeCall(manager.handle, (m)));
        assert(!ok);
        assert(manager.conversation(openedId).live == 1);
        assert(manager.slotOf(openedId, address(p1)) == ContractNetLib.SLOT_INVITED);
    }
}

contract QueueBytecodeProof is NetFixture {
    QueuedContractNetManager q;
    Message opening;
    bytes32 internal openedId;

    function setUp() public override {
        super.setUp();
        q = new QueuedContractNetManager();
        opening = _cfp(uint64(block.timestamp + 100));
        openedId = q.cfp(_one(address(p1)), opening);
        opening.conversationId = openedId;
        p1.respond(opening, address(q), _out(opening, Performative.Propose));
        vm.warp(block.timestamp + 101);
        q.evaluate(openedId, _one(address(p1)), _empty(), _empty());
    }

    function check_earlyCompletionRejected(bool failure) public {
        Message memory m = _out(opening, failure ? Performative.Failure : Performative.Inform);
        vm.prank(address(p1));
        (bool ok,) = address(q).call(abi.encodeCall(q.handle, (m)));
        assert(!ok);
        assert(q.pendingCount(openedId) == 1);
        assert(q.conversation(openedId).live == 1);
    }

    function check_withdrawalCleansQueue() public {
        p1.respond(opening, address(q), _out(opening, Performative.NotUnderstood));
        assert(q.pendingCount(openedId) == 0);
        assert(q.pending(openedId, address(p1)) == 0);
        assert(q.conversation(openedId).live == 0);
    }

    function check_wrongDeliveryTarget(address peer) public {
        vm.assume(peer != address(p1));
        (bool ok,) = address(q).call(abi.encodeCall(q.deliver, (openedId, peer)));
        assert(!ok);
        assert(q.pendingCount(openedId) == 1);
        assert(q.conversation(openedId).live == 1);
    }
}
