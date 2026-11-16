// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title QQAITierData — SSTORE2-style data contract for the QQAINFT tier bitmap.
/// @notice The deployed runtime code of this contract IS the data passed to
///         the constructor (one chunk of the 27,778-byte tier bitmap).
///         QQAINFT.tierOf reads single bytes from it with EXTCODECOPY. Deploy
///         two instances (chunk A, chunk B) from contracts/tierdata.json and
///         register them on QQAINFT with setTierData(a, b) right after the
///         QQAINFT deployment (deployer only, locks forever).
contract QQAITierData {
    constructor(bytes memory data) {
        assembly {
            return(add(data, 0x20), mload(data))
        }
    }
}
