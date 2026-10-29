pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Agent} from "../src/core/Agent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";
import {ScriptedRequestAgent} from "./Request.t.sol";
import {ExampleParticipant, ExampleRequester} from "../examples/RequestExample.sol";

/// @dev Per-call protocol gas (warm accounts, measured with `gasleft`). Logged for reports.
contract GasRequestTest is Test {
    ScriptedRequestAgent internal alice;
    ScriptedRequestAgent internal bob;

    function setUp() public {
        alice = new ScriptedRequestAgent(address(0));
        bob = new ScriptedRequestAgent(address(0));
    }

    function _start(bytes32 id) internal returns (Message memory req, uint256 used) {
        req.performative = uint8(Performative.Request);
        req.protocol = uint8(Protocol.FipaRequest);
        req.conversationId = id;
        vm.recordLogs();
        uint256 g = gasleft();
        alice.startRequest(address(bob), req);
        used = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bob) && logs[i].topics[0] == Agent.Received.selector) {
                (,,, bytes32 replyWith,,,) = abi.decode(
                    logs[i].data, (bytes32, uint8, uint8, bytes32, bytes32, uint64, bytes)
                );
                req.replyWith = replyWith;
            }
        }
    }

    function _act(Message memory req, Performative act) internal pure returns (Message memory m) {
        m.performative = uint8(act);
        m.protocol = req.protocol;
        m.conversationId = req.conversationId;
        m.inReplyTo = req.replyWith;
    }

    function _respond(Message memory req, Performative act) internal returns (uint256 used) {
        Message memory out = _act(req, act);
        uint256 g = gasleft();
        bob.respond(req, address(alice), out);
        used = g - gasleft();
    }

    function test_gas_requestRefuse() public {
        (Message memory req, uint256 s1) = _start(keccak256("g1"));
        uint256 s2 = _respond(req, Performative.Refuse);
        emit log_named_uint("first startRequest", s1);
        emit log_named_uint("refuse", s2);
        (req, s1) = _start(keccak256("g1b"));
        s2 = _respond(req, Performative.Refuse);
        emit log_named_uint("next startRequest", s1);
        emit log_named_uint("refuse (2)", s2);
    }

    function test_gas_requestAgreeInform() public {
        (Message memory warm,) = _start(keccak256("warm"));
        _respond(warm, Performative.Refuse);
        (Message memory req, uint256 s1) = _start(keccak256("g2"));
        uint256 s2 = _respond(req, Performative.Agree);
        uint256 s3 = _respond(req, Performative.Inform);
        emit log_named_uint("startRequest", s1);
        emit log_named_uint("agree", s2);
        emit log_named_uint("inform", s3);
        emit log_named_uint("total", s1 + s2 + s3);
    }

    function test_gas_exampleSynchronousInform() public {
        ExampleRequester r = new ExampleRequester(address(0));
        ExampleParticipant p = new ExampleParticipant(address(0));
        r.request(address(p), keccak256("warm"), hex"01");
        uint256 g = gasleft();
        r.request(address(p), keccak256("g3"), hex"01");
        emit log_named_uint("example request->inform (one tx)", g - gasleft());
    }
}
