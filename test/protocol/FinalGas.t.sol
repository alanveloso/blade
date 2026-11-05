// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NetFixture} from "./Fixtures.sol";
import {SubscriptionActor} from "./Subscribe.t.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";

contract FinalGasTest is NetFixture {
    function test_gasSubscribeLifecycle() public {
        SubscriptionActor a = new SubscriptionActor();
        SubscriptionActor b = new SubscriptionActor();
        bytes32 id = bytes32(uint256(1));
        uint256 g = gasleft();
        a.start(address(b), id);
        emit log_named_uint("subscribe open", g - gasleft());
        g = gasleft();
        b.act(id, Performative.Agree);
        emit log_named_uint("subscribe agree", g - gasleft());
        g = gasleft();
        b.act(id, Performative.Inform);
        emit log_named_uint("subscribe notify", g - gasleft());
        g = gasleft();
        a.act(id, Performative.Cancel);
        emit log_named_uint("subscribe cancel", g - gasleft());
        g = gasleft();
        b.act(id, Performative.Inform);
        emit log_named_uint("subscribe cancel ack", g - gasleft());
        assertEq(uint8(a.subscription(id).phase), 0);
        assertEq(uint8(b.subscription(id).phase), 0);
    }

    function test_gasContractNetLifecycle() public {
        bytes32 id = bytes32(uint256(1));
        Message memory m = _cfp(id, uint64(block.timestamp + 100));
        address[] memory peers = _two(address(p1), address(p2));
        uint256 g = gasleft();
        manager.cfp(peers, m);
        emit log_named_uint("cn cfp two peers", g - gasleft());
        Message memory proposal = _out(m, Performative.Propose);
        g = gasleft();
        p1.respond(m, address(manager), proposal);
        emit log_named_uint("cn propose", g - gasleft());
        p2.respond(m, address(manager), proposal);
        vm.warp(block.timestamp + 101);
        address[] memory accept = _one(address(p1));
        address[] memory reject = _one(address(p2));
        address[] memory empty = _empty();
        g = gasleft();
        manager.evaluate(id, accept, reject, empty);
        emit log_named_uint("cn evaluate", g - gasleft());
        Message memory result = _out(m, Performative.Inform);
        g = gasleft();
        p1.respond(m, address(manager), result);
        emit log_named_uint("cn inform", g - gasleft());
        assertEq(manager.conversation(id).live, 0);
    }
}
