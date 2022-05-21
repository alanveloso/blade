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
        string content;
        string language;
        string encoding;
        string ontology;
        string protocol;
        string reply_with;
        string in_reply_to;
        uint256 reply_by;

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

}