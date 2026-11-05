// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Agent} from "../src/core/Agent.sol";
import {RequestAgent} from "../src/core/RequestAgent.sol";
import {Message} from "../src/core/Message.sol";
import {Performative} from "../src/core/Performative.sol";
import {Protocol} from "../src/core/Protocol.sol";

/// @notice Reactive inventory agent. Its Solidity policy accepts only available quantities.
contract InventoryAgent is RequestAgent {
    uint256 public stock;

    constructor(uint256 initialStock) Agent(address(0)) {
        stock = initialStock;
    }

    function _onReceive(Message calldata m) internal override {
        require(m.protocol == uint8(Protocol.FipaRequest), "protocol");
        require(m.performative == uint8(Performative.Request), "act");
        uint256 quantity = abi.decode(m.content, (uint256));
        bool accept = quantity > 0 && quantity <= stock;
        if (accept) stock -= quantity;
        Message memory response;
        response.protocol = m.protocol;
        response.conversationId = m.conversationId;
        response.inReplyTo = m.replyWith;
        response.performative = uint8(accept ? Performative.Inform : Performative.Refuse);
        response.content = abi.encode(accept ? quantity : 0);
        _reply(m, msg.sender, response);
    }
}

/// @notice Solidity reorder policy: request the deficit only when below its target.
/// @dev Anyone may trigger tick, but cannot choose supplier or quantity. No self-scheduling.
contract ReorderAgent is RequestAgent {
    address public immutable supplier;
    uint256 public immutable target;
    uint256 public inventory;
    uint256 public attempts;
    uint256 public refusals;

    constructor(address supplier_, uint256 target_) Agent(address(0)) {
        supplier = supplier_;
        target = target_;
    }

    function tick() external {
        if (inventory >= target) return;
        Message memory m;
        m.protocol = uint8(Protocol.FipaRequest);
        m.performative = uint8(Performative.Request);
        m.conversationId = keccak256(abi.encode(address(this), ++attempts));
        m.content = abi.encode(target - inventory);
        _startRequest(supplier, m);
    }

    function _onReceive(Message calldata m) internal override {
        require(m.protocol == uint8(Protocol.FipaRequest) && msg.sender == supplier, "supplier");
        if (m.performative == uint8(Performative.Inform)) {
            inventory += abi.decode(m.content, (uint256));
        } else if (m.performative == uint8(Performative.Refuse)) {
            refusals++;
        } else {
            revert("act");
        }
    }
}
