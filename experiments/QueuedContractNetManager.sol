// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ContractNetLib} from "../src/core/ContractNetLib.sol";
import {ContractNetManager} from "../src/core/ContractNetManager.sol";
import {Agent} from "../src/core/Agent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

/// @notice Research candidate: stages decisions, delivers each in a separate call.
/// @dev Not a production replacement. Owner chooses decisions; anyone can trigger delivery.
/// A stuck recipient retains its queue entry and prevents ID reuse, but not honest delivery.
contract QueuedContractNetManager is ContractNetManager {
    address public immutable owner;
    mapping(bytes32 => mapping(address => uint8)) public pending;
    mapping(bytes32 => uint256) public pendingCount;
    event DecisionQueued(bytes32 indexed id, address indexed peer, uint8 act);

    constructor() Agent(address(0)) {
        owner = msg.sender;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    function cfp(address[] calldata peers, Message memory m) external onlyOwner returns (bytes32) {
        // BLADE assigns a fresh id; pending decisions cannot collide with a new opening.
        return _cfp(peers, m);
    }

    function evaluate(
        bytes32 id,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external onlyOwner {
        _evaluate(id, accept, reject, silent);
    }

    function deliver(bytes32 id, address peer) external {
        uint8 act = pending[id][peer];
        require(act != 0, "no decision");
        delete pending[id][peer];
        --pendingCount[id];
        super._send(peer, _act(id, act, 0));
    }

    /// @dev Staged acceptance is not yet delivered. A participant may withdraw, but cannot
    /// report completion before delivery. During deliver(), pending is cleared before callback.
    function _onInbound(Message calldata m) internal override {
        bool queuedAcceptance = m.protocol == uint8(Protocol.FipaContractNet)
            && pending[m.conversationId][msg.sender] == uint8(Performative.AcceptProposal);
        if (
            queuedAcceptance
                && (m.performative == uint8(Performative.Inform)
                    || m.performative == uint8(Performative.Failure))
        ) revert ContractNetLib.InvalidTransition();
        super._onInbound(m);
        if (queuedAcceptance && m.performative == uint8(Performative.NotUnderstood)) {
            delete pending[m.conversationId][msg.sender];
            --pendingCount[m.conversationId];
            emit DecisionWithdrawn(m.conversationId, msg.sender);
        }
    }

    event DecisionWithdrawn(bytes32 indexed id, address indexed peer);

    function _send(address peer, Message memory m) internal override {
        if (
            m.protocol == uint8(Protocol.FipaContractNet)
                && (m.performative == uint8(Performative.AcceptProposal)
                    || m.performative == uint8(Performative.RejectProposal))
        ) {
            require(pending[m.conversationId][peer] == 0, "duplicate decision");
            pending[m.conversationId][peer] = m.performative;
            ++pendingCount[m.conversationId];
            emit DecisionQueued(m.conversationId, peer, m.performative);
        } else {
            super._send(peer, m);
        }
    }
}
