// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../node_modules/@openzeppelin/contracts/utils/Address.sol";

library menssages {

    enum performatives{ AcceptProposal, Agree, Cancel, Cfp, CallForProposal, Confirm, Disconfirm, Failure, Inform, NotUnderstood, Propose, QueryIf, QueryRef, Refuse, RejectProposal, Request, RequestWhen, RequestWhenever, Subscribe, InformIf, Proxy, Propagate}

    enum protocols{FipaRequestProtocol, FipaQueryProtocol, FipaRequestWhenProtocol, FipaContractNetProtocol}

    struct ACLMessage {
    // Structure that implements ACLMessage message type
        
        string ACCEPT_PROPOSAL;
        string AGREE;
        string CANCEL;
        string CFP;
        string CONFIRM;
        string DISCONFIRM;
        string FAILURE;
        string INFORM;
        string NOT_UNDERSTOOD;
        string PROPOSE;
        string QUERY_IF;
        string QUERY_REF;
        string REFUSE;
        string REJECT_PROPOSAL;
        string REQUEST;
        string REQUEST_WHEN;
        string REQUEST_WHENEVER;
        string SUBSCRIBE;
        string INFORM_IF;
        string PROXY;
        string PROPAGATE;

        string FIPA_REQUEST_PROTOCOL;
        string FIPA_QUERY_PROTOCOL;
        string FIPA_REQUEST_WHEN_PROTOCOL;
        string FIPA_CONTRACT_NET_PROTOCOL;
        string FIPA_SUBSCRIBE_PROTOCOL;

        performatives performative;

        protocols protocols;
        
        bool system_message; // False
        uint256 datetime;
        address sender;
        address[] receivers;
        address[] reply_to;
        bytes content;
        string language;
        string encoding;
        string ontology;
        string protocol;
        string reply_with;
        string in_reply_to;
        uint256 reply_by;
        string conversation_id;
        string message_id;

    }

    function set_performative(ACLMessage storage self, performatives performative) public {
        self.performative = performative;
    }

    function set_system_message(ACLMessage storage self, bool is_system_message) public {
        self.system_message = is_system_message;
    }


    function set_datetime_now(ACLMessage storage self) public {
        self.datetime = block.timestamp;
    }

    function set_sender(ACLMessage storage self, address aid) public {
        if (Address.isContract(aid)){
            self.sender = aid;
        }
        else{
            set_sender(self, address(aid));
        }
    }

    function add_receiver(ACLMessage storage self, address aid) public {
        if (Address.isContract(aid)){
            self.receivers.push(aid);
        }
        else{
            add_receiver(self, address(aid));
        }
    }

    function add_reply_to (ACLMessage storage self, address aid) public {
        if (Address.isContract(aid)){
            self.reply_to.push(aid);
        }
        else{
            add_reply_to(self, address(aid));
        } 
    }

    function set_content(ACLMessage storage self, bytes memory data) public {
        self.content = data;
    }

    function set_language(ACLMessage storage self, string memory data) public {
        self.language = data;
    }

    function set_encoding(ACLMessage storage self, string memory data) public {
        self.encoding = data;
    }

    function set_ontology(ACLMessage storage self, string memory data) public {
        self.ontology = data;
    }

    function set_protocol(ACLMessage storage self, string memory data) public {
        self.protocol = data;
    }

    function set_conversation_id(ACLMessage storage self, string memory data) public {
        self.conversation_id = data;
    }

    function set_message_id(ACLMessage storage self, string memory data) public {
        self.message_id = data;
    }

    function set_reply_with(ACLMessage storage self, string memory data) public {
        self.reply_with = data;
    }

    function set_in_reply_to(ACLMessage storage self, string memory data) public {
        self.in_reply_to = data;
    }
    
    function set_reply_by(ACLMessage storage self, string memory data) public {
        self.reply_with = data;
    }

    function set_message(ACLMessage storage self, bytes memory data) public {
        ACLMessage memory aclmsg = abi.decode(data, (ACLMessage));
        
        self.performative = aclmsg.performative;
        self.system_message = aclmsg.system_message;
        self.conversation_id = aclmsg.conversation_id;
        self.message_id  = aclmsg.message_id; 
        self.datetime = aclmsg.datetime;
        self.sender = aclmsg.sender;
        self.reply_to  = aclmsg.reply_to;
        self.content = aclmsg.content;
        self.language = aclmsg.language;
        self.encoding = aclmsg.encoding;
        self.protocol = aclmsg.protocol;
        self.reply_with = aclmsg.reply_with;
        self.in_reply_to = aclmsg.in_reply_to;
        self.reply_by = aclmsg.reply_by;
    }

}