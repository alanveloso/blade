// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../acl/Message.sol";

contract MessageMock {

    using Message for Message.ACLMessage;
    
    Message.ACLMessage _message;

    function getMessage() public view returns (Message.ACLMessage memory) {
        return _message.get_message();
    }
}