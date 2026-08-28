// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DirtyCalldataBase.t.sol";

/**
 * @notice Validates the field manifests and records the compilation configuration.
 *
 * @dev These are fixture-integrity tests, not security tests. They exist so that a manifest
 *      transcription error can never make a padding sweep vacuously pass.
 */
contract DirtyManifestTest is DirtyCalldataBase {
    function setUp() public {
        _setUpDirty();
    }

    /// @dev The half of the configuration tuple that is visible from inside the EVM. The rest
    ///      (viaIR, optimizer runs, evmVersion) is checked against artifact metadata.
    function test_compilerConfigurationIsTheIntendedOne() public pure {
        // Cancun: TSTORE/TLOAD and MCOPY are available. MCOPY is the cheapest positive probe.
        uint256 probe;
        assembly {
            mstore(0x80, 0xdeadbeef)
            mcopy(0xa0, 0x80, 0x20) // reverts as an invalid opcode pre-Cancun
            probe := mload(0xa0)
        }
        assertEq(probe, 0xdeadbeef, "MCOPY available, so the EVM target is at least Cancun");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Word counts match the live ABI encoding
    // ══════════════════════════════════════════════════════════════════

    function _assertWordCount(uint256 encodedLen, Field[] memory f, string memory name) internal pure {
        assertEq(encodedLen % 32, 0, string.concat(name, ": encodes to whole words"));
        assertEq(encodedLen / 32, f.length, string.concat(name, ": manifest word count"));
    }

    function test_manifestWordCountsMatchTheAbiEncoding() public view {
        _assertWordCount(abi.encode(_defaultProposedSwap()).length, _proposedSwapFields(), "ProposedSwap");
        _assertWordCount(abi.encode(_defaultMatcherPreimage()).length, _matcherPreimageFields(), "MatcherPreimage");
        _assertWordCount(abi.encode(_defaultCloseDutch()).length, _closeDutchFields(), "CloseDutch");

        OpenPuntStorage.MatchedSwap memory ms;
        _assertWordCount(abi.encode(ms).length, _matchedSwapFields(), "MatchedSwap");

        IOpenOracle2.OracleGame memory g;
        _assertWordCount(abi.encode(g).length, _oracleGameFields(), "OracleGame");

        IOpenOracle2.PreimageHelper memory h;
        _assertWordCount(abi.encode(h).length, _preimageHelperFields(), "PreimageHelper");
    }

    /// @dev The oracle preimage encodes to a fixed, contiguous layout, which is what lets the
    ///      dirty-calldata suites address individual OracleGame and PreimageHelper members by
    ///      offset. `execute()` hashes `abi.encode` of the decoded memory structs, so this is a
    ///      layout-consistency assertion for the tests' addressing, not a claim about how
    ///      production computes the hash.
    function test_oraclePreimageEncodesToAFixedContiguousLayout() public pure {
        IOpenOracle2.OracleGame memory g;
        IOpenOracle2.PreimageHelper memory h;
        assertEq(abi.encode(g).length, 20 * 32, "OracleGame is 20 static words");
        assertEq(abi.encode(h).length, 4 * 32, "PreimageHelper is 4 static words");
        assertEq(
            abi.encode(g, h).length,
            abi.encode(g).length + abi.encode(h).length,
            "encoding the pair is the concatenation, so member offsets are additive"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Manifest widths are individually correct
    // ══════════════════════════════════════════════════════════════════

    /// @dev Encodes a struct whose every member is set to all-ones for its declared width, then
    ///      checks each word has exactly `width` nonzero low bytes. This catches a wrong width
    ///      or a wrong declaration order, independently of the source comments.
    function _assertWidths(bytes memory encoded, Field[] memory f, string memory name) internal pure {
        for (uint256 i = 0; i < f.length; i++) {
            bytes32 w;
            assembly {
                w := mload(add(add(encoded, 0x20), mul(i, 32)))
            }
            uint256 nonzeroLow = 0;
            for (uint256 b = 0; b < 32; b++) {
                if (uint8(uint256(w) >> (8 * b)) != 0) nonzeroLow = b + 1;
            }
            assertEq(
                nonzeroLow, f[i].width, string.concat(name, ".", f[i].name, ": declared width matches the encoding")
            );
        }
    }

    function test_proposedSwapWidths() public pure {
        OpenPuntStorage.ProposedSwap memory s;
        s.swapper = address(type(uint160).max);
        s.collatToken = address(type(uint160).max);
        s.oracleToken1 = address(type(uint160).max);
        s.oracleToken2 = address(type(uint160).max);
        s.initialMarginSwapper = type(uint128).max;
        s.initialMarginMatcher = type(uint128).max;
        s.maintenanceMarginSwapper = type(uint128).max;
        s.notional = type(uint128).max;
        s.isLong = true;
        s.pnlUsesToken1PerToken2 = true;
        s.fundingRate = type(int32).max; // positive: no sign extension into the padding
        s.fulfillmentFee = type(uint24).max;
        s.auctionFunding = true;
        s.priceTolerated = type(uint232).max;
        s.toleranceRange = type(uint24).max;
        s.millisecondsPerBlock = type(uint16).max;
        s.maxGameTime = type(uint24).max;
        s.maxExecutionLatency = type(uint16).max;
        s.liquidationHeartbeatMin = type(uint16).max;
        s.liquidationHeartbeatMax = type(uint16).max;
        s.expiration = type(uint48).max;
        s.maturityWindow = type(uint48).max;
        s.settlerReward = type(uint96).max;
        s.matcherGasComp = type(uint96).max;
        s.openExecutionComp = type(uint96).max;
        s.useInternalBalances = true;
        s.maturityOnly = true;
        _assertWidths(abi.encode(s), _proposedSwapFields(), "ProposedSwap");
    }

    function test_matcherPreimageWidths() public pure {
        OpenPuntStorage.MatcherPreimage memory m;
        m.initialLiquidity = type(uint128).max;
        m.escalationHalt = type(uint128).max;
        m.settlementTime = type(uint48).max;
        m.disputeDelay = type(uint24).max;
        m.multiplier = type(uint16).max;
        m.protocolFee = type(uint24).max;
        m.auctionStart = type(int32).max; // positive: no sign extension into the padding
        m.auctionEnd = type(int32).max;
        m.roundLength = type(uint24).max;
        m.maxRounds = type(uint16).max;
        m.growthRate = type(uint16).max;
        m.startFulfillFeeIncrease = type(uint48).max;
        _assertWidths(abi.encode(m), _matcherPreimageFields(), "MatcherPreimage");
    }

    function test_matchedSwapWidths() public pure {
        OpenPuntStorage.MatchedSwap memory s;
        s.swapper = address(type(uint160).max);
        s.matcher = address(type(uint160).max);
        s.collatToken = address(type(uint160).max);
        s.oracleToken1 = address(type(uint160).max);
        s.oracleToken2 = address(type(uint160).max);
        s.initialMarginSwapper = type(uint128).max;
        s.initialMarginMatcher = type(uint128).max;
        s.maintenanceMarginSwapper = type(uint128).max;
        s.notional = type(uint128).max;
        s.swapperIsLong = true;
        s.pnlUsesToken1PerToken2 = true;
        s.fulfillmentFee = type(uint24).max;
        s.fundingRate = type(int32).max;
        s.oracleAmount1 = type(uint128).max;
        s.oracleAmount2 = type(uint128).max;
        s.feeRecipient = address(type(uint160).max);
        s.matcherPreimageHash = bytes32(type(uint256).max);
        s.priceTolerated = type(uint232).max;
        s.toleranceRange = type(uint24).max;
        s.millisecondsPerBlock = type(uint16).max;
        s.maxGameTime = type(uint24).max;
        s.maxExecutionLatency = type(uint16).max;
        s.liquidationHeartbeatMin = type(uint16).max;
        s.liquidationHeartbeatMax = type(uint16).max;
        s.start = type(uint48).max;
        s.maturity = type(uint48).max;
        s.maturityWindow = type(uint48).max;
        s.active = true;
        s.openExecutionComp = type(uint96).max;
        s.useInternalBalances = true;
        s.maturityOnly = true;
        _assertWidths(abi.encode(s), _matchedSwapFields(), "MatchedSwap");
    }

    function test_closeDutchWidths() public pure {
        OpenPuntStorage.CloseDutch memory d;
        d.swapper = address(type(uint160).max);
        d.collatToken = address(type(uint160).max);
        d.swapId = type(uint256).max;
        d.maxReward = type(uint128).max;
        d.startingReward = type(uint128).max;
        d.roundLength = type(uint24).max;
        d.growthRate = type(uint16).max;
        d.maxRounds = type(uint16).max;
        d.start = type(uint48).max;
        d.expiration = type(uint48).max;
        d.useInternalBalances = true;
        _assertWidths(abi.encode(d), _closeDutchFields(), "CloseDutch");
    }

    function test_oracleGameWidths() public pure {
        IOpenOracle2.OracleGame memory g;
        g.currentAmount1 = type(uint128).max;
        g.currentAmount2 = type(uint128).max;
        g.currentReporter = address(type(uint160).max);
        g.reportTimestamp = type(uint48).max;
        g.settlementTimestamp = type(uint48).max;
        g.token1 = address(type(uint160).max);
        g.lastReportOppoTime = type(uint48).max;
        g.settlementTime = type(uint48).max;
        g.escalationHalt = type(uint128).max;
        g.protocolFeeRecipient = address(type(uint160).max);
        g.settlerReward = type(uint96).max;
        g.token2 = address(type(uint160).max);
        g.numReports = type(uint24).max;
        g.disputeDelay = type(uint24).max;
        g.feePercentage = type(uint24).max;
        g.multiplier = type(uint16).max;
        g.callbackContract = address(type(uint160).max);
        g.callbackGasLimit = type(uint32).max;
        g.protocolFee = type(uint24).max;
        g.flags = type(uint8).max;
        _assertWidths(abi.encode(g), _oracleGameFields(), "OracleGame");
    }

    function test_preimageHelperWidths() public pure {
        IOpenOracle2.PreimageHelper memory h;
        h.reportId = type(uint256).max;
        h.creator = address(type(uint160).max);
        h.blockTimestamp = type(uint256).max;
        h.blockNumber = type(uint256).max;
        _assertWidths(abi.encode(h), _preimageHelperFields(), "PreimageHelper");
    }

    /// @dev Signed members are the exception to "padding must be zero": their padding is the
    ///      sign extension. A negative int32 legitimately carries 0xff across all 28 padding
    ///      bytes, so the sweeps must dirty signed fields against their sign, not against zero.
    function test_signedPaddingIsTheSignExtensionNotZero() public pure {
        OpenPuntStorage.MatcherPreimage memory m;
        m.auctionStart = -1;
        bytes memory enc = abi.encode(m);
        bytes32 w = _readWord(enc, 32 * 6); // auctionStart is word 6
        assertEq(w, bytes32(type(uint256).max), "negative int32 encodes as all ones, padding included");

        m.auctionStart = 1;
        w = _readWord(abi.encode(m), 32 * 6);
        assertEq(uint256(w), 1, "positive int32 encodes with zero padding");
    }

    // ══════════════════════════════════════════════════════════════════
    //  Padding budget, reported per struct
    // ══════════════════════════════════════════════════════════════════

    function test_paddingByteBudgetPerStruct() public pure {
        assertEq(_paddingByteCount(_proposedSwapFields()), 617, "ProposedSwap padding bytes");
        assertEq(_paddingByteCount(_matcherPreimageFields()), 317, "MatcherPreimage padding bytes");
        assertEq(_paddingByteCount(_matchedSwapFields()), 659, "MatchedSwap padding bytes");
        assertEq(_paddingByteCount(_closeDutchFields()), 228, "CloseDutch padding bytes");
        assertEq(_paddingByteCount(_oracleGameFields()), 437, "OracleGame padding bytes");
        assertEq(_paddingByteCount(_preimageHelperFields()), 12, "PreimageHelper padding bytes");
        assertEq(
            _paddingByteCount(_proposedSwapFields()) + _paddingByteCount(_matcherPreimageFields())
                + _paddingByteCount(_matchedSwapFields()) + _paddingByteCount(_closeDutchFields())
                + _paddingByteCount(_oracleGameFields()) + _paddingByteCount(_preimageHelperFields()),
            2270,
            "total padding budget across all six structs"
        );
    }
}
