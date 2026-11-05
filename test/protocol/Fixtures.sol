// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ExposedContractNetManager, ExposedContractNetParticipant} from "../ContractNetActors.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";

abstract contract NetFixture is Test {
    ExposedContractNetManager internal manager;
    ExposedContractNetParticipant internal p1;
    ExposedContractNetParticipant internal p2;

    function setUp() public virtual {
        manager = new ExposedContractNetManager(address(0));
        p1 = new ExposedContractNetParticipant(address(0));
        p2 = new ExposedContractNetParticipant(address(0));
        vm.warp(1_700_000_000);
    }

    /// @dev Opening template: `conversationId` must be zero; BLADE assigns on `cfp`.
    function _cfp(uint64 by) internal pure returns (Message memory m) {
        m.protocol = uint8(Protocol.FipaContractNet);
        m.performative = uint8(Performative.Cfp);
        m.replyBy = by;
        m.replyWith = keccak256("cn-rw");
    }

    /// @dev Legacy helper for audit comparators that still accept application-chosen ids.
    function _cfpWithId(bytes32 id, uint64 by) internal pure returns (Message memory m) {
        m = _cfp(by);
        m.conversationId = id;
        m.replyWith = keccak256(abi.encodePacked(id, "rw"));
    }

    function _open(address[] memory peers, uint64 by)
        internal
        returns (bytes32 id, Message memory cfp)
    {
        cfp = _cfp(by);
        id = manager.cfp(peers, cfp);
        cfp.conversationId = id;
    }

    function _out(Message memory inbound, Performative act)
        internal
        pure
        returns (Message memory m)
    {
        m.protocol = inbound.protocol;
        m.performative = uint8(act);
        m.conversationId = inbound.conversationId;
        m.inReplyTo = inbound.replyWith;
    }

    function _empty() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _one(address p) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = p;
    }

    function _two(address p, address q) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = p;
        a[1] = q;
    }

    function _proposeAll(address[] memory peers) internal returns (bytes32 id, Message memory cfp) {
        (id, cfp) = _open(peers, uint64(block.timestamp + 100));
        for (uint256 i; i < peers.length; ++i) {
            ExposedContractNetParticipant(peers[i])
                .respond(cfp, address(manager), _out(cfp, Performative.Propose));
        }
        vm.warp(block.timestamp + 101);
    }
}
