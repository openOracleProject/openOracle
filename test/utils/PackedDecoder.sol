// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenOracle as Slim} from "../../src/OpenOracleSlim.sol";
import {openSwapV2} from "../../src/swap/OpenSwapSlim.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/// @notice Fixed-offset decoders for the packed-event payloads emitted by
///         OpenOracle._packMem and openSwap._packMem. Offsets MUST stay in
///         lockstep with the contracts' _packMem assembly. Any layout drift in
///         the contract that isn't mirrored here will surface as a field-level
///         mismatch in the round-trip tests.
///
///         Bot-side decoders must obey the same offsets.
library PackedDecoder {
    // ── primitive readers ───────────────────────────────────────────────
    function _readUint(bytes memory blob, uint256 off, uint256 W) internal pure returns (uint256 v) {
        require(off + W <= blob.length, "PackedDecoder: out of range");
        assembly {
            v := shr(mul(8, sub(32, W)), mload(add(add(blob, 0x20), off)))
        }
    }

    function readU128(bytes memory blob, uint256 off) internal pure returns (uint128) { return uint128(_readUint(blob, off, 16)); }
    function readU96(bytes memory blob, uint256 off)  internal pure returns (uint96)  { return uint96(_readUint(blob, off, 12)); }
    function readU48(bytes memory blob, uint256 off)  internal pure returns (uint48)  { return uint48(_readUint(blob, off, 6)); }
    function readU32(bytes memory blob, uint256 off)  internal pure returns (uint32)  { return uint32(_readUint(blob, off, 4)); }
    function readU24(bytes memory blob, uint256 off)  internal pure returns (uint24)  { return uint24(_readUint(blob, off, 3)); }
    function readU16(bytes memory blob, uint256 off)  internal pure returns (uint16)  { return uint16(_readUint(blob, off, 2)); }
    function readU8(bytes memory blob, uint256 off)   internal pure returns (uint8)   { return uint8(_readUint(blob, off, 1)); }
    function readU232(bytes memory blob, uint256 off) internal pure returns (uint232) { return uint232(_readUint(blob, off, 29)); }
    function readAddress(bytes memory blob, uint256 off) internal pure returns (address) { return address(uint160(_readUint(blob, off, 20))); }
    function readBool(bytes memory blob, uint256 off) internal pure returns (bool) { return readU8(blob, off) != 0; }

    // ── struct decoders ─────────────────────────────────────────────────

    /// @dev OracleGame layout (203 bytes). Mirrors OpenOracleSlim._packMem head.
    function decodeOracleGame(bytes memory blob)
        internal
        pure
        returns (IOpenOracle2.OracleGame memory g)
    {
        require(blob.length >= 203, "PackedDecoder: blob too short for OracleGame");
        g.currentAmount1       = readU128(blob,   0);
        g.currentAmount2       = readU128(blob,  16);
        g.currentReporter      = readAddress(blob, 32);
        g.reportTimestamp      = readU48(blob,  52);
        g.settlementTimestamp  = readU48(blob,  58);
        g.token1               = readAddress(blob, 64);
        g.lastReportOppoTime   = readU48(blob,  84);
        g.settlementTime       = readU48(blob,  90);
        g.escalationHalt       = readU128(blob, 96);
        g.protocolFeeRecipient = readAddress(blob, 112);
        g.settlerReward        = readU96(blob, 132);
        g.token2               = readAddress(blob, 144);
        g.numReports           = readU24(blob, 164);
        g.disputeDelay         = readU24(blob, 167);
        g.feePercentage        = readU24(blob, 170);
        g.multiplier           = readU16(blob, 173);
        g.callbackContract     = readAddress(blob, 175);
        g.callbackGasLimit     = readU32(blob, 195);
        g.protocolFee          = readU24(blob, 199);
        g.flags                = readU8(blob,  202);
    }

    /// @dev Oracle PreimageHelper tail (32 bytes at offset 203). reportId is
    ///      pulled from the indexed topic, not from the packed blob.
    function decodeHelperTail(bytes memory blob, uint256 reportIdFromTopic)
        internal
        pure
        returns (IOpenOracle2.PreimageHelper memory h)
    {
        require(blob.length >= 235, "PackedDecoder: blob too short for helper tail");
        h.reportId       = reportIdFromTopic;
        h.creator        = readAddress(blob, 203);
        h.blockTimestamp = uint256(readU48(blob, 223));
        h.blockNumber    = uint256(readU48(blob, 229));
    }

    /// @dev ProposedSwap layout from SwapCreated packed (170 bytes head). Mirrors
    ///      openSwap._packMem kind=1 head.
    function decodeProposedSwap(bytes memory blob)
        internal
        pure
        returns (openSwapV2.ProposedSwap memory s)
    {
        require(blob.length >= 170, "PackedDecoder: blob too short for ProposedSwap");
        s.sellAmt              = readU128(blob,   0);
        s.minFulfillLiquidity  = readU128(blob,  16);
        s.settlerReward        = readU96(blob,  32);
        s.maxGameTime          = readU24(blob,  44);
        s.buyToken             = readAddress(blob, 47);
        s.matcherGasComp       = readU96(blob,  67);
        s.sellToken            = readAddress(blob, 79);
        s.swapper              = readAddress(blob, 99);
        s.executorGasComp      = readU96(blob, 119);
        s.useInternalBalances  = readBool(blob, 131);
        s.expiration           = readU48(blob, 132);
        s.priceTolerated       = readU232(blob, 138);
        s.toleranceRange       = readU24(blob, 167);
    }

    /// @dev MatcherPreimage tail of SwapCreated packed (65 bytes at offset 170).
    function decodeMatcherPreimage(bytes memory blob)
        internal
        pure
        returns (openSwapV2.MatcherPreimage memory m)
    {
        require(blob.length >= 235, "PackedDecoder: blob too short for MatcherPreimage");
        m.initialLiquidity         = readU128(blob, 170);
        m.escalationHalt           = readU128(blob, 186);
        m.settlementTime           = readU48(blob, 202);
        m.disputeDelay             = readU24(blob, 208);
        m.protocolFee              = readU24(blob, 211);
        m.multiplier               = readU16(blob, 214);
        m.startFulfillFeeIncrease  = readU48(blob, 216);
        m.maxFee                   = readU24(blob, 222);
        m.startingFee              = readU24(blob, 225);
        m.roundLength              = readU24(blob, 228);
        m.growthRate               = readU16(blob, 231);
        m.maxRounds                = readU16(blob, 233);
    }

    /// @dev MatchedSwap layout from SwapMatched packed (205 bytes). Mirrors
    ///      openSwap._packMem kind=2.
    function decodeMatchedSwap(bytes memory blob)
        internal
        pure
        returns (openSwapV2.MatchedSwap memory s)
    {
        require(blob.length >= 205, "PackedDecoder: blob too short for MatchedSwap");
        s.sellAmt              = readU128(blob,   0);
        s.minFulfillLiquidity  = readU128(blob,  16);
        s.maxGameTime          = readU24(blob,  32);
        s.buyToken             = readAddress(blob, 35);
        s.sellToken            = readAddress(blob, 55);
        s.swapper              = readAddress(blob, 75);
        s.executorGasComp      = readU96(blob,  95);
        s.useInternalBalances  = readBool(blob, 107);
        s.reportId             = readU128(blob, 108);
        s.matcher              = readAddress(blob, 124);
        s.start                = readU48(blob, 144);
        s.fulfillmentFee       = readU24(blob, 150);
        s.feeRecipient         = readAddress(blob, 153);
        s.priceTolerated       = readU232(blob, 173);
        s.toleranceRange       = readU24(blob, 202);
    }
}
