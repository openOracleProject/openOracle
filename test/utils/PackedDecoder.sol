// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenOracle as Slim} from "../../src/OpenOracleSlim.sol";
import {openSwapV2} from "../../src/OpenSwapSlim.sol";
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

    /// @dev ProposedSwap layout from SwapCreated packed (172 bytes head). Mirrors
    ///      openSwap._packMem kind=1 head.
    function decodeProposedSwap(bytes memory blob)
        internal
        pure
        returns (openSwapV2.ProposedSwap memory s)
    {
        require(blob.length >= 172, "PackedDecoder: blob too short for ProposedSwap");
        s.sellAmt              = readU128(blob,   0);
        s.minFulfillLiquidity  = readU128(blob,  16);
        s.settlerReward        = readU96(blob,  32);
        s.maxGameTime          = readU24(blob,  44);
        s.blocksPerSecond      = readU16(blob,  47);
        s.buyToken             = readAddress(blob, 49);
        s.matcherGasComp       = readU96(blob,  69);
        s.sellToken            = readAddress(blob, 81);
        s.swapper              = readAddress(blob, 101);
        s.executorGasComp      = readU96(blob, 121);
        s.useInternalBalances  = readBool(blob, 133);
        s.expiration           = readU48(blob, 134);
        s.priceTolerated       = readU232(blob, 140);
        s.toleranceRange       = readU24(blob, 169);
    }

    /// @dev MatcherPreimage tail of SwapCreated packed (65 bytes at offset 172).
    function decodeMatcherPreimage(bytes memory blob)
        internal
        pure
        returns (openSwapV2.MatcherPreimage memory m)
    {
        require(blob.length >= 237, "PackedDecoder: blob too short for MatcherPreimage");
        m.initialLiquidity         = readU128(blob, 172);
        m.escalationHalt           = readU128(blob, 188);
        m.settlementTime           = readU48(blob, 204);
        m.disputeDelay             = readU24(blob, 210);
        m.protocolFee              = readU24(blob, 213);
        m.multiplier               = readU16(blob, 216);
        m.startFulfillFeeIncrease  = readU48(blob, 218);
        m.maxFee                   = readU24(blob, 224);
        m.startingFee              = readU24(blob, 227);
        m.roundLength              = readU24(blob, 230);
        m.growthRate               = readU16(blob, 233);
        m.maxRounds                = readU16(blob, 235);
    }

    /// @dev MatchedSwap layout from SwapMatched packed (207 bytes). Mirrors
    ///      openSwap._packMem kind=2.
    function decodeMatchedSwap(bytes memory blob)
        internal
        pure
        returns (openSwapV2.MatchedSwap memory s)
    {
        require(blob.length >= 207, "PackedDecoder: blob too short for MatchedSwap");
        s.sellAmt              = readU128(blob,   0);
        s.minFulfillLiquidity  = readU128(blob,  16);
        s.maxGameTime          = readU24(blob,  32);
        s.blocksPerSecond      = readU16(blob,  35);
        s.buyToken             = readAddress(blob, 37);
        s.sellToken            = readAddress(blob, 57);
        s.swapper              = readAddress(blob, 77);
        s.executorGasComp      = readU96(blob,  97);
        s.useInternalBalances  = readBool(blob, 109);
        s.reportId             = readU128(blob, 110);
        s.matcher              = readAddress(blob, 126);
        s.start                = readU48(blob, 146);
        s.fulfillmentFee       = readU24(blob, 152);
        s.feeRecipient         = readAddress(blob, 155);
        s.priceTolerated       = readU232(blob, 175);
        s.toleranceRange       = readU24(blob, 204);
    }
}
