// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Agent} from "../../src/core/Agent.sol";
import {ContractNetManager} from "../../src/core/ContractNetManager.sol";
import {ContractNetParticipant} from "../../src/core/ContractNetParticipant.sol";
import {Message} from "../../src/core/Message.sol";
import {Protocol} from "../../src/core/Protocol.sol";
import {Performative} from "../../src/core/Performative.sol";

/// @dev Audit baseline: keeps caller-selected conversation ids (pre-generation policy).
contract AuditNativeManager is ContractNetManager {
    address public immutable owner;

    constructor() Agent(address(0)) {
        owner = msg.sender;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    function cfp(address[] calldata peers, Message memory m)
        external
        virtual
        onlyOwner
        returns (bytes32)
    {
        return _cfp(peers, m);
    }

    function evaluate(
        bytes32 id,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external virtual onlyOwner {
        _evaluate(id, accept, reject, silent);
    }

    /// @dev Historical comparator: application supplies the id.
    function _openConversationId(Message memory message)
        internal
        virtual
        override
        returns (bytes32)
    {
        require(message.conversationId != bytes32(0), "id required");
        return message.conversationId;
    }
}

/// @dev Keeps caller-selected IDs but permanently refuses reuse (one permanent slot per ID).
contract AuditUniqueManager is AuditNativeManager {
    mapping(bytes32 => bool) public used;

    function cfp(address[] calldata peers, Message memory m)
        external
        override
        onlyOwner
        returns (bytes32)
    {
        require(!used[m.conversationId], "used id");
        used[m.conversationId] = true;
        return _cfp(peers, m);
    }
}

/// @dev Thin wrapper over BLADE-generated ids (same policy now shipping in production).
contract AuditGeneratedIdManager is ContractNetManager {
    address public immutable owner;
    uint256 public nonce;
    event GeneratedConversation(bytes32 indexed id);

    constructor() Agent(address(0)) {
        owner = msg.sender;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    function cfp(address[] calldata peers, Message memory m) external onlyOwner returns (bytes32) {
        return open(peers, m);
    }

    function open(address[] calldata peers, Message memory m) public onlyOwner returns (bytes32 id) {
        id = _cfp(peers, m);
        // Mirror historical gas/event surface; BLADE already assigned via ++_conversationNonce.
        ++nonce;
        emit GeneratedConversation(id);
    }

    function evaluate(
        bytes32 id,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external onlyOwner {
        _evaluate(id, accept, reject, silent);
    }
}

/// @dev Strict token prototype. Requires upgraded participant and changed continuation envelopes.
/// Busy prevents same-ID reopening from decision callbacks while old decisions still need the token.
contract AuditTokenManager is AuditNativeManager {
    uint256 public nonce;
    mapping(bytes32 => bytes32) public token;
    mapping(bytes32 => bool) private busy;

    function cfp(address[] calldata peers, Message memory m)
        external
        override
        onlyOwner
        returns (bytes32)
    {
        bytes32 id = m.conversationId;
        require(!busy[id], "busy");
        require(m.replyWith == bytes32(0), "core token");
        // Check before replacing correlation for a live instance.
        require(_net[id].invited == 0 && _net[id].live == 0, "live");
        busy[id] = true;
        token[id] = keccak256(abi.encode(block.chainid, address(this), id, ++nonce));
        m.replyWith = token[id];
        id = _cfp(peers, m);
        busy[id] = false;
        _cleanToken(id);
        return id;
    }

    function evaluate(
        bytes32 id,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external override onlyOwner {
        require(!busy[id], "busy");
        busy[id] = true;
        _evaluate(id, accept, reject, silent);
        busy[id] = false;
        _cleanToken(id);
    }

    function _onInbound(Message calldata m) internal override {
        if (m.protocol == uint8(Protocol.FipaContractNet)) {
            require(
                token[m.conversationId] != bytes32(0) && m.inReplyTo == token[m.conversationId],
                "token"
            );
        }
        super._onInbound(m);
        if (m.protocol == uint8(Protocol.FipaContractNet)) _cleanToken(m.conversationId);
    }

    function _cleanToken(bytes32 id) private {
        if (!busy[id] && _net[id].invited == 0 && _net[id].live == 0) delete token[id];
    }

    function _send(address to, Message memory m) internal override {
        if (m.protocol == uint8(Protocol.FipaContractNet)) m.replyWith = token[m.conversationId];
        super._send(to, m);
    }
}

contract AuditTokenParticipant is ContractNetParticipant {
    mapping(bytes32 => bytes32) public token;
    constructor() Agent(address(0)) {}

    function respond(Message calldata opening, address to, Message memory m) external {
        _respond(opening, to, m);
    }

    function _onInbound(Message calldata m) internal override {
        if (m.protocol == uint8(Protocol.FipaContractNet)) {
            if (_cn[m.conversationId].phase == 0 && m.performative == uint8(Performative.Cfp)) {
                require(m.replyWith != bytes32(0), "token");
                token[m.conversationId] = m.replyWith;
            } else {
                require(
                    token[m.conversationId] != bytes32(0) && m.replyWith == token[m.conversationId],
                    "token"
                );
            }
        }
        super._onInbound(m);
        if (m.protocol == uint8(Protocol.FipaContractNet) && _cn[m.conversationId].phase == 0) {
            delete token[m.conversationId];
        }
    }

    function _reply(Message calldata inbound, address to, Message memory m) internal override {
        bytes32 beforeToken = token[m.conversationId];
        if (m.protocol == uint8(Protocol.FipaContractNet)) {
            require(beforeToken != bytes32(0) && m.inReplyTo == beforeToken, "token");
        }
        super._reply(inbound, to, m);
        if (
            m.protocol == uint8(Protocol.FipaContractNet) && _cn[m.conversationId].phase == 0
                && token[m.conversationId] == beforeToken
        ) {
            delete token[m.conversationId];
        }
    }
}
