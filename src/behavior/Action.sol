// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Discriminated proposal a Behavior may return. Envelope only — not a frozen API.
/// @dev `Application` is intentionally generic: its payload is interpreted only by the trusted
///      Agent-owned behavior action hook. It is not a protocol-role instruction.
enum Kind {
    None,
    Application
}

struct Action {
    uint8 kind;
    bytes data;
}

library ActionLib {
    error UnknownKind();
    error NoneRequiresEmptyData();
    error ApplicationRequiresHost();

    /// @dev Field-only checks avoid copying `data` beyond length.
    function validateFields(uint8 kind, uint256 dataLength) internal pure {
        if (kind == uint8(Kind.None)) {
            if (dataLength != 0) {
                revert NoneRequiresEmptyData();
            }
            return;
        }
        if (kind == uint8(Kind.Application)) {
            return;
        }
        revert UnknownKind();
    }

    function validate(Action memory a) internal pure {
        validateFields(a.kind, a.data.length);
    }

    function kindOf(Action memory a) internal pure returns (Kind) {
        validate(a);
        return Kind(a.kind);
    }

    /// @dev Applies only framework-owned built-in semantics. `None` is a no-op.
    ///      Application actions require the trusted Agent-owned dispatch boundary and therefore
    ///      must never be silently treated as a no-op by this standalone helper.
    function applyAction(Action memory a) internal pure {
        validate(a);
        if (a.kind == uint8(Kind.Application)) {
            revert ApplicationRequiresHost();
        }
    }
}
