// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Discriminated proposal a Behavior may return. Envelope only — not a frozen API.
/// @dev This slice supports `None` (explicit no-op). Payload-bearing kinds are later work.
enum Kind {
    None
}

struct Action {
    uint8 kind;
    bytes data;
}

library ActionLib {
    error UnknownKind();
    error NoneRequiresEmptyData();

    /// @dev Field-only checks avoid copying `data` beyond length.
    function validateFields(uint8 kind, uint256 dataLength) internal pure {
        if (kind != uint8(Kind.None)) {
            revert UnknownKind();
        }
        if (dataLength != 0) {
            revert NoneRequiresEmptyData();
        }
    }

    function validate(Action memory a) internal pure {
        validateFields(a.kind, a.data.length);
    }

    function kindOf(Action memory a) internal pure returns (Kind) {
        validate(a);
        return Kind.None;
    }

    /// @dev Validated apply. `None` is a no-op. Unknown/invalid kinds revert first.
    function applyAction(Action memory a) internal pure {
        validate(a);
    }
}
