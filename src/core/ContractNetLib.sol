// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

/// @dev Shared Contract Net checks. Not a multi-agent router.
library ContractNetLib {
    error InvalidCfp();
    error EmptyParticipants();
    error DuplicateParticipant();
    error DuplicateEvaluateEntry();
    error OverlappingEvaluateLists();
    error EvaluationTooEarly();
    error IncompleteEvaluation();
    error InvalidTransition();
    error UnexpectedPeer();
    error ReplyByRequired();
    error InvalidParticipant(address participant);

    uint8 internal constant SLOT_NONE = 0;
    uint8 internal constant SLOT_INVITED = 1;
    uint8 internal constant SLOT_PROPOSED = 2;
    uint8 internal constant SLOT_ACCEPTED = 3;

    uint8 internal constant PART_NONE = 0;
    uint8 internal constant PART_CFPED = 1;
    uint8 internal constant PART_PROPOSED = 2;
    uint8 internal constant PART_ACCEPTED = 3;

    function requireCfp(Message memory m) internal pure {
        if (m.protocol != uint8(Protocol.FipaContractNet)) {
            revert InvalidCfp();
        }
        if (m.performative != uint8(Performative.Cfp)) {
            revert InvalidCfp();
        }
        if (m.conversationId == bytes32(0)) {
            revert InvalidCfp();
        }
        if (m.replyBy == 0) {
            revert ReplyByRequired();
        }
    }

    function isLate(uint64 replyBy) internal view returns (bool) {
        return block.timestamp > replyBy;
    }

    function requireWindowClosed(uint64 replyBy) internal view {
        if (!isLate(replyBy)) {
            revert EvaluationTooEarly();
        }
    }

    function requireNoDuplicates(address[] calldata a) internal pure {
        uint256 n = a.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (a[i] == a[j]) {
                    revert DuplicateEvaluateEntry();
                }
            }
        }
    }

    function contains(address[] calldata a, address x) internal pure returns (bool) {
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] == x) {
                return true;
            }
        }
        return false;
    }

    function requireDisjoint(address[] calldata a, address[] calldata b) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            if (contains(b, a[i])) {
                revert OverlappingEvaluateLists();
            }
        }
    }
}
