// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "./Agent.sol";
import {ContractNetLib} from "./ContractNetLib.sol";
import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

/// @title FIPA Contract Net initiator. Does not store `Message`/`content`.
contract ContractNetManager is Agent {
    using ContractNetLib for Message;

    /// @dev Root record. Slots: conversationId => participant => Invited|Proposed|Accepted.
    struct Conversation {
        uint64 replyBy;
        bool evaluated;
        uint32 live;
        uint32 invited;
    }

    mapping(bytes32 conversationId => Conversation) internal _net;
    mapping(bytes32 conversationId => mapping(address participant => uint8 slot)) internal _slot;

    event ContractNetSlot(
        bytes32 indexed conversationId, address indexed participant, uint8 slot, uint8 performative
    );

    constructor(address trustedRelay_) Agent(trustedRelay_) {}

    function conversation(bytes32 conversationId) external view returns (Conversation memory) {
        return _net[conversationId];
    }

    function slotOf(bytes32 conversationId, address participant) external view returns (uint8) {
        return _slot[conversationId][participant];
    }

    /// @dev Explicit 1:N CFP. Same `conversationId` on every `handle`. Application decision primitive.
    function _cfp(address[] calldata participants, Message memory message) internal {
        ContractNetLib.requireCfp(message);
        uint256 n = participants.length;
        if (n == 0) {
            revert ContractNetLib.EmptyParticipants();
        }
        Conversation storage c = _net[message.conversationId];
        if (c.invited != 0 || c.live != 0) {
            revert ContractNetLib.InvalidTransition();
        }
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            if (p == address(0) || p.code.length == 0) {
                revert ContractNetLib.InvalidParticipant(p);
            }
            for (uint256 j = 0; j < i; j++) {
                if (participants[j] == p) {
                    revert ContractNetLib.DuplicateParticipant();
                }
            }
        }
        c.replyBy = message.replyBy;
        c.evaluated = false;
        // `n > type(uint32).max` is unreachable: this transaction delivers one `handle` per invitee.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.live = uint32(n);
        // forge-lint: disable-next-line(unsafe-typecast)
        c.invited = uint32(n);
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            _slot[message.conversationId][p] = ContractNetLib.SLOT_INVITED;
            emit ContractNetSlot(
                message.conversationId, p, ContractNetLib.SLOT_INVITED, uint8(Performative.Cfp)
            );
        }
        for (uint256 i = 0; i < n; i++) {
            _send(participants[i], message);
        }
    }

    /// @dev Tx-triggered finalization after `replyBy`. CEI: all checks/effects, then participant `handle`s.
    function _evaluate(
        bytes32 conversationId,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) internal {
        Conversation storage c = _net[conversationId];
        if (c.invited == 0 && c.live == 0) {
            revert ContractNetLib.InvalidTransition();
        }
        if (c.evaluated) {
            revert ContractNetLib.InvalidTransition();
        }
        ContractNetLib.requireWindowClosed(c.replyBy);

        ContractNetLib.requireNoDuplicates(accept);
        ContractNetLib.requireNoDuplicates(reject);
        ContractNetLib.requireNoDuplicates(silent);
        ContractNetLib.requireDisjoint(accept, reject);
        ContractNetLib.requireDisjoint(accept, silent);
        ContractNetLib.requireDisjoint(reject, silent);

        if (accept.length + reject.length + silent.length != c.live) {
            revert ContractNetLib.IncompleteEvaluation();
        }
        for (uint256 i = 0; i < silent.length; i++) {
            if (_slot[conversationId][silent[i]] != ContractNetLib.SLOT_INVITED) {
                revert ContractNetLib.InvalidTransition();
            }
        }
        for (uint256 i = 0; i < reject.length; i++) {
            if (_slot[conversationId][reject[i]] != ContractNetLib.SLOT_PROPOSED) {
                revert ContractNetLib.InvalidTransition();
            }
        }
        for (uint256 i = 0; i < accept.length; i++) {
            if (_slot[conversationId][accept[i]] != ContractNetLib.SLOT_PROPOSED) {
                revert ContractNetLib.InvalidTransition();
            }
        }

        uint64 replyBy = c.replyBy;
        c.evaluated = true;
        for (uint256 i = 0; i < silent.length; i++) {
            delete _slot[conversationId][silent[i]];
            c.live -= 1;
        }
        for (uint256 i = 0; i < reject.length; i++) {
            delete _slot[conversationId][reject[i]];
            c.live -= 1;
            emit ContractNetSlot(
                conversationId,
                reject[i],
                ContractNetLib.SLOT_NONE,
                uint8(Performative.RejectProposal)
            );
        }
        for (uint256 i = 0; i < accept.length; i++) {
            _slot[conversationId][accept[i]] = ContractNetLib.SLOT_ACCEPTED;
            emit ContractNetSlot(
                conversationId,
                accept[i],
                ContractNetLib.SLOT_ACCEPTED,
                uint8(Performative.AcceptProposal)
            );
        }
        // After effects, live == accept.length. Callbacks may reduce live further (M30).
        _maybeClear(conversationId);

        for (uint256 i = 0; i < reject.length; i++) {
            _send(reject[i], _act(conversationId, uint8(Performative.RejectProposal), replyBy));
        }
        for (uint256 i = 0; i < accept.length; i++) {
            _send(accept[i], _act(conversationId, uint8(Performative.AcceptProposal), replyBy));
        }
    }

    function _onInbound(Message calldata message) internal override {
        if (message.protocol != uint8(Protocol.FipaContractNet)) {
            return;
        }
        Conversation storage c = _net[message.conversationId];
        if (c.invited == 0 && c.live == 0) {
            revert ContractNetLib.InvalidTransition();
        }
        if (message.logicalSender != bytes32(0)) {
            revert ContractNetLib.UnexpectedPeer();
        }
        uint8 slot = _slot[message.conversationId][msg.sender];
        if (slot == ContractNetLib.SLOT_NONE) {
            revert ContractNetLib.UnexpectedPeer();
        }
        Performative act = Performative(message.performative);
        if (act == Performative.Propose) {
            if (slot != ContractNetLib.SLOT_INVITED) {
                revert ContractNetLib.UnexpectedPeer();
            }
            if (ContractNetLib.isLate(c.replyBy)) {
                delete _slot[message.conversationId][msg.sender];
                c.live -= 1;
                emit ContractNetSlot(
                    message.conversationId,
                    msg.sender,
                    ContractNetLib.SLOT_NONE,
                    uint8(Performative.RejectProposal)
                );
                _send(
                    msg.sender,
                    _act(message.conversationId, uint8(Performative.RejectProposal), c.replyBy)
                );
                _maybeClear(message.conversationId);
                return;
            }
            _slot[message.conversationId][msg.sender] = ContractNetLib.SLOT_PROPOSED;
            emit ContractNetSlot(
                message.conversationId,
                msg.sender,
                ContractNetLib.SLOT_PROPOSED,
                uint8(Performative.Propose)
            );
            return;
        }
        if (act == Performative.Refuse) {
            if (slot != ContractNetLib.SLOT_INVITED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _slot[message.conversationId][msg.sender];
            c.live -= 1;
            emit ContractNetSlot(
                message.conversationId,
                msg.sender,
                ContractNetLib.SLOT_NONE,
                uint8(Performative.Refuse)
            );
            _maybeClear(message.conversationId);
            return;
        }
        if (act == Performative.NotUnderstood) {
            if (slot == ContractNetLib.SLOT_NONE) {
                revert ContractNetLib.UnexpectedPeer();
            }
            delete _slot[message.conversationId][msg.sender];
            c.live -= 1;
            emit ContractNetSlot(
                message.conversationId,
                msg.sender,
                ContractNetLib.SLOT_NONE,
                uint8(Performative.NotUnderstood)
            );
            _maybeClear(message.conversationId);
            return;
        }
        if (act == Performative.Inform || act == Performative.Failure) {
            if (slot != ContractNetLib.SLOT_ACCEPTED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _slot[message.conversationId][msg.sender];
            c.live -= 1;
            emit ContractNetSlot(
                message.conversationId, msg.sender, ContractNetLib.SLOT_NONE, uint8(act)
            );
            _maybeClear(message.conversationId);
            return;
        }
        revert ContractNetLib.InvalidTransition();
    }

    function _maybeClear(bytes32 conversationId) internal {
        Conversation storage c = _net[conversationId];
        if (c.live != 0) {
            return;
        }
        if (!c.evaluated && c.invited != 0) {
            // Still before/without evaluation only if every invited already refused/NU/late-rejected.
            // No Proposed/Accepted remain; nothing to evaluate.
        }
        delete _net[conversationId];
    }

    function _act(bytes32 conversationId, uint8 performative, uint64 replyBy)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = performative;
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = conversationId;
        m.replyBy = replyBy;
    }
}
