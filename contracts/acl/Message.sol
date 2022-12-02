// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import "../../node_modules/@openzeppelin/contracts/utils/Address.sol";

library Message {

    using Message for ACLMessage;

    enum performatives{ Null, AcceptProposal, Agree, Cancel, Cfp, CallForProposal, Confirm, Disconfirm, Failure, Inform, NotUnderstood, Propose, QueryIf, QueryRef, Refuse, RejectProposal, Request, RequestWhen, RequestWhenever, Subscribe, InformIf, Proxy, Propagate}

    enum protocols{ Null, FipaRequestProtocol, FipaQueryProtocol, FipaRequestWhenProtocol, FipaContractNetProtocol}

    string constant ACCEPT_PROPOSAL = 'accept-proposal';
    string constant AGREE = 'agree';
    string constant CANCEL =  'cancel';
    string constant CFP = 'cfp';
    string constant CONFIRM = 'confirm';
    string constant DISCONFIRM = 'disconfirm';
    string constant FAILURE = 'failure';
    string constant INFORM = 'inform';
    string constant NOT_UNDERSTOOD = 'not-understood';
    string constant PROPOSE = 'propose';
    string constant QUERY_IF = 'query-if';
    string constant QUERY_REF = 'query-ref';
    string constant REFUSE = 'refuse';
    string constant REJECT_PROPOSAL = 'reject-proposal';
    string constant REQUEST = 'request';
    string constant REQUEST_WHEN = 'request-when';
    string constant REQUEST_WHENEVER = 'request-whenever';
    string constant SUBSCRIBE = 'subscribe';
    string constant INFORM_IF = 'inform-if';
    string constant PROXY = 'proxy';
    string constant PROPAGATE = 'propagate';
    string constant Null = 'Null';

    string constant FIPA_REQUEST_PROTOCOL = 'fipa-request protocol';
    string constant FIPA_QUERY_PROTOCOL = 'fipa-query protocol';
    string constant FIPA_REQUEST_WHEN_PROTOCOL = 'fipa-request-when protocol';
    string constant FIPA_CONTRACT_NET_PROTOCOL = 'fipa-contract-net protocol';
    string constant FIPA_SUBSCRIBE_PROTOCOL = 'fipa-subscribe-protocol';

    struct ACLMessage {
    // Structure that implements ACLMessage message type

        performatives performative;
        protocols protocol;
        bool system_message; // False
        uint256 datetime;
        address sender;
        address[] receivers;
        address[] reply_to;
        bytes content;
        string language;
        string encoding;
        string ontology;
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

    function set_content(ACLMessage storage self, bytes memory content) public {
        self.content = content;
    }

    function set_language(ACLMessage storage self, string memory language) public {
        self.language = language;
    }

    function set_encoding(ACLMessage storage self, string memory encoding) public {
        self.encoding = encoding;
    }

    function set_ontology(ACLMessage storage self, string memory ontology) public {
        self.ontology = ontology;
    }

    function set_protocol(ACLMessage storage self, protocols protocol) public {
        self.protocol = protocol;
    }

    function set_conversation_id(ACLMessage storage self, string memory conversation_id) public {
        self.conversation_id = conversation_id;
    }

    function set_message_id(ACLMessage storage self, string memory message_id) public {
        self.message_id = message_id;
    }

    function set_reply_with(ACLMessage storage self, string memory reply_with) public {
        self.reply_with = reply_with;
    }

    function set_in_reply_to(ACLMessage storage self, string memory in_reply_to) public {
        self.in_reply_to = in_reply_to;
    }
    
    function set_reply_by(ACLMessage storage self, string memory reply_by) public {
        self.reply_with = reply_by;
    }

    function set_message(ACLMessage storage self, bytes calldata message) public {
        ACLMessage memory aclmsg;
        aclmsg = abi.decode(message[4:], (ACLMessage));
        
        self.performative = aclmsg.performative;
        self.protocol = aclmsg.protocol;
        self.system_message = aclmsg.system_message;
        self.datetime = aclmsg.datetime;
        self.sender = aclmsg.sender;

        for (uint i = 0; i < aclmsg.receivers.length; i++){
            self.receivers.push(aclmsg.receivers[i]);
            self.reply_to.push(aclmsg.receivers[i]);
        }

        self.content = aclmsg.content;
        self.language = aclmsg.language;
        self.encoding = aclmsg.encoding;
        self.ontology = aclmsg.ontology;
        self.reply_with = aclmsg.reply_with;
        self.in_reply_to = aclmsg.in_reply_to;
        self.reply_by = aclmsg.reply_by;
        self.conversation_id = aclmsg.conversation_id;
        self.message_id  = aclmsg.message_id;
    }

    function get_message(ACLMessage memory self) internal pure returns (ACLMessage memory) {
        return (self);
    }

    function create_reply(ACLMessage memory self) public pure returns (ACLMessage memory) {
        ACLMessage memory message;
        message.performative = self.performative;
        message.system_message = self.system_message;

        if (bytes(self.language).length == 0)
            message.language = self.language;
        
        if (bytes(self.ontology).length == 0)
            message.ontology = self.ontology;
        
        if (self.protocol != protocols.Null)
            message.protocol = self.protocol;
        
        if (bytes(self.conversation_id).length == 0)
            message.conversation_id = self.conversation_id;

        for (uint i=0; i<self.reply_to.length; i++){
            message.receivers[i] = self.receivers[i];
        }

        if (self.reply_to.length == 0)
            message.receivers[0] = self.sender;

        if (bytes(self.reply_with).length == 0)
            message.in_reply_to = self.reply_with;

        return message;
    }

}