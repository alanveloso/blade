// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {Agent} from "../../src/core/Agent.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {SubscribeAgent, SubscribePhase} from "../../src/core/SubscribeAgent.sol";
import {Message} from "../../src/core/Message.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {Performative} from "../../src/core/Performative.sol";
import {SubscriptionActor} from "./Subscribe.t.sol";
import {ScriptedRequestAgent} from "../Request.t.sol";

contract CompositeSubscription is RequestAgent, SubscribeAgent {
    constructor() Agent(address(0)) {}

    function startBoth(address peer, bytes32 id) external {
        _startSubscribe(peer, id, "");
        Message memory m;
        m.protocol = uint8(Protocol.FipaRequest);
        m.performative = uint8(Performative.Request);
        m.conversationId = id;
        _startRequest(peer, m);
    }

    function _onInbound(Message calldata m) internal override(RequestAgent, SubscribeAgent) {
        super._onInbound(m);
    }

    function _reply(Message calldata inbound, address to, Message memory outbound)
        internal
        override(Agent, RequestAgent)
    {
        super._reply(inbound, to, outbound);
    }

    function agreeSubscription(bytes32 id) external {
        _subscriptionAct(id, Performative.Agree, "");
    }
}

contract SubscribeCompositionTest is Test {
    function test_sameIdentifierSeparateProtocolNamespaces() public {
        CompositeSubscription a = new CompositeSubscription();
        CompositeSubscription b = new CompositeSubscription();
        bytes32 id = keccak256("shared-id");
        a.startBoth(address(b), id);
        b.agreeSubscription(id);
        assertEq(uint8(a.subscription(id).phase), uint8(SubscribePhase.Active));
        assertEq(uint8(b.subscription(id).phase), uint8(SubscribePhase.Active));
        assertEq(uint8(a.requestStatus(id).phase), uint8(RequestPhase.Requested));
        assertEq(uint8(b.requestStatus(id).phase), uint8(RequestPhase.Requested));
    }
}
