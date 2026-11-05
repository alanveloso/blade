// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SubscriptionActor} from "./Subscribe.t.sol";
import {SubscribePhase} from "../../src/core/SubscribeAgent.sol";
import {Performative} from "../../src/core/Performative.sol";

contract SubscribeHandler is Test {
    SubscriptionActor public a = new SubscriptionActor();
    SubscriptionActor public b = new SubscriptionActor();
    uint256 public calls;
    uint256 public successes;

    function step(uint8 idChoice, uint8 action, bool fromA) external {
        bytes32 id = bytes32(uint256(idChoice % 3 + 1));
        bytes32 other = bytes32(uint256((idChoice % 3 + 1) % 3 + 1));
        bytes32 untouched = keccak256(abi.encode(a.subscription(other), b.subscription(other)));
        bytes32 beforeState = keccak256(abi.encode(a.subscription(id), b.subscription(id)));
        bool ok;
        if (action % 8 == 0) {
            try a.start(address(b), id) {
                ok = true;
            } catch {}
        } else {
            Performative[7] memory acts = [
                Performative.Agree,
                Performative.Inform,
                Performative.Cancel,
                Performative.Failure,
                Performative.Refuse,
                Performative.NotUnderstood,
                Performative.Propose
            ];
            try (fromA ? a : b).act(id, acts[action % 8 - 1]) {
                ok = true;
            } catch {}
        }
        ++calls;
        if (ok) ++successes;
        else assertEq(keccak256(abi.encode(a.subscription(id), b.subscription(id))), beforeState);
        assertEq(keccak256(abi.encode(a.subscription(other), b.subscription(other))), untouched);
    }
}

contract SubscribeInvariantTest is StdInvariant, Test {
    SubscribeHandler handler;

    function setUp() public {
        handler = new SubscribeHandler();
        targetContract(address(handler));
    }

    function invariant_endpointAgreementAndCorrelation() public view {
        for (uint256 i = 1; i <= 3; ++i) {
            bytes32 id = bytes32(i);
            assertEq(
                uint8(handler.a().subscription(id).phase), uint8(handler.b().subscription(id).phase)
            );
            assertEq(handler.a().subscription(id).token, handler.b().subscription(id).token);
            assertEq(
                handler.a().subscription(id).cancelToken, handler.b().subscription(id).cancelToken
            );
            assertEq(
                uint8(handler.a().subscription(id).resumePhase),
                uint8(handler.b().subscription(id).resumePhase)
            );
            if (handler.a().subscription(id).phase == SubscribePhase.Cancelling) {
                assertNotEq(handler.a().subscription(id).cancelToken, bytes32(0));
                assertNotEq(
                    handler.a().subscription(id).cancelToken, handler.a().subscription(id).token
                );
            }
            if (handler.a().subscription(id).phase != SubscribePhase.None) {
                assertTrue(handler.a().subscription(id).initiator);
                assertFalse(handler.b().subscription(id).initiator);
                assertEq(handler.a().subscription(id).peer, address(handler.b()));
                assertEq(handler.b().subscription(id).peer, address(handler.a()));
            }
        }
    }
}
