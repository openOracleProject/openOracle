// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TokenCompatBase.t.sol";

/**
 * @notice Raw-calldata / ABI-boundary fixture.
 *
 * @dev These ABI-boundary properties depend on the exact compilation
 *      configuration, not on the source alone. Verified against the artifact metadata of
 *      `out/OpenPunt.sol/OpenPunt.json`:
 *
 *          solc          0.8.28+commit.7893614a
 *          viaIR         true
 *          evmVersion    cancun
 *          optimizer     enabled, runs = 190
 *
 *      `test_compilerConfigurationIsTheIntendedOne` re-asserts the source-level half of that
 *      tuple at run time. The dirty-calldata suite must be rerun whenever the compiler version, the
 *      optimizer setting or run count, the via-IR setting, or the EVM target changes.
 *
 *      Clean payloads are produced with `abi.encodeCall`, then mutated as raw bytes. Dirty narrow
 *      values cannot be produced through typed Solidity variables because the
 *      compiler canonicalizes them before the call — so every probe here works on the encoded
 *      byte string and is delivered through a low-level `call`.
 *
 *      Every mutation is preceded by an offset self-check (`_assertCleanWord`) so that a wrong
 *      offset cannot silently produce a meaningless passing test.
 */
abstract contract DirtyCalldataBase is TokenCompatBase {
    // ── field classification ────────────────────────────────────────────

    uint8 internal constant C_FULL = 0; // uint256 / bytes32: no padding region
    uint8 internal constant C_UINT = 1;
    uint8 internal constant C_ADDR = 2;
    uint8 internal constant C_BOOL = 3;
    uint8 internal constant C_INT = 4; // signed: padding must be the SIGN EXTENSION, not zero

    struct Field {
        uint8 width; // declared width in bytes
        uint8 cls;
        string name;
    }

    /// @dev Byte offset of a struct member from the start of the function arguments
    ///      (i.e. excluding the 4-byte selector; `_argOffset` adds that back).
    function _memberOffset(uint256 structArgOffset, uint256 wordIndex) internal pure returns (uint256) {
        return structArgOffset + 32 * wordIndex;
    }

    /// @dev Absolute byte offset into the calldata buffer, selector included.
    function _argOffset(uint256 argRelativeOffset) internal pure returns (uint256) {
        return 4 + argRelativeOffset;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Canonical field manifests
    //
    //  All of these structs are static: every member occupies exactly one 32-byte word, in
    //  declaration order. Transcribed from src/levered-swaps/OpenPuntStorage.sol and
    //  src/interfaces/IOpenOracle2.sol.
    //  Word counts are asserted against the live ABI encoding in DirtyManifest.t.sol.
    // ══════════════════════════════════════════════════════════════════

    function _proposedSwapFields() internal pure returns (Field[] memory f) {
        f = new Field[](25);
        f[0] = Field(20, C_ADDR, "swapper");
        f[1] = Field(20, C_ADDR, "collatToken");
        f[2] = Field(20, C_ADDR, "oracleToken1");
        f[3] = Field(20, C_ADDR, "oracleToken2");
        f[4] = Field(16, C_UINT, "initialMarginSwapper");
        f[5] = Field(16, C_UINT, "initialMarginMatcher");
        f[6] = Field(16, C_UINT, "maintenanceMarginSwapper");
        f[7] = Field(16, C_UINT, "notional");
        f[8] = Field(1, C_BOOL, "isLong");
        f[9] = Field(4, C_INT, "fundingRate");
        f[10] = Field(3, C_UINT, "fulfillmentFee");
        f[11] = Field(1, C_BOOL, "auctionFunding");
        f[12] = Field(29, C_UINT, "priceTolerated");
        f[13] = Field(3, C_UINT, "toleranceRange");
        f[14] = Field(2, C_UINT, "millisecondsPerBlock");
        f[15] = Field(3, C_UINT, "maxGameTime");
        f[16] = Field(2, C_UINT, "maxExecutionLatency");
        f[17] = Field(2, C_UINT, "liquidationHeartbeatMin");
        f[18] = Field(2, C_UINT, "liquidationHeartbeatMax");
        f[19] = Field(6, C_UINT, "expiration");
        f[20] = Field(6, C_UINT, "maturityWindow");
        f[21] = Field(12, C_UINT, "settlerReward");
        f[22] = Field(12, C_UINT, "matcherGasComp");
        f[23] = Field(12, C_UINT, "openExecutionComp");
        f[24] = Field(1, C_BOOL, "useInternalBalances");
    }

    function _matcherPreimageFields() internal pure returns (Field[] memory f) {
        f = new Field[](12);
        f[0] = Field(16, C_UINT, "initialLiquidity");
        f[1] = Field(16, C_UINT, "escalationHalt");
        f[2] = Field(6, C_UINT, "settlementTime");
        f[3] = Field(3, C_UINT, "disputeDelay");
        f[4] = Field(2, C_UINT, "multiplier");
        f[5] = Field(3, C_UINT, "protocolFee");
        f[6] = Field(4, C_INT, "auctionStart");
        f[7] = Field(4, C_INT, "auctionEnd");
        f[8] = Field(3, C_UINT, "roundLength");
        f[9] = Field(2, C_UINT, "maxRounds");
        f[10] = Field(2, C_UINT, "growthRate");
        f[11] = Field(6, C_UINT, "startFulfillFeeIncrease");
    }

    function _matchedSwapFields() internal pure returns (Field[] memory f) {
        f = new Field[](29);
        f[0] = Field(20, C_ADDR, "swapper");
        f[1] = Field(20, C_ADDR, "matcher");
        f[2] = Field(20, C_ADDR, "collatToken");
        f[3] = Field(20, C_ADDR, "oracleToken1");
        f[4] = Field(20, C_ADDR, "oracleToken2");
        f[5] = Field(16, C_UINT, "initialMarginSwapper");
        f[6] = Field(16, C_UINT, "initialMarginMatcher");
        f[7] = Field(16, C_UINT, "maintenanceMarginSwapper");
        f[8] = Field(16, C_UINT, "notional");
        f[9] = Field(1, C_BOOL, "swapperIsLong");
        f[10] = Field(3, C_UINT, "fulfillmentFee");
        f[11] = Field(4, C_INT, "fundingRate");
        f[12] = Field(16, C_UINT, "oracleAmount1");
        f[13] = Field(16, C_UINT, "oracleAmount2");
        f[14] = Field(20, C_ADDR, "feeRecipient");
        f[15] = Field(32, C_FULL, "matcherPreimageHash");
        f[16] = Field(29, C_UINT, "priceTolerated");
        f[17] = Field(3, C_UINT, "toleranceRange");
        f[18] = Field(2, C_UINT, "millisecondsPerBlock");
        f[19] = Field(3, C_UINT, "maxGameTime");
        f[20] = Field(2, C_UINT, "maxExecutionLatency");
        f[21] = Field(2, C_UINT, "liquidationHeartbeatMin");
        f[22] = Field(2, C_UINT, "liquidationHeartbeatMax");
        f[23] = Field(6, C_UINT, "start");
        f[24] = Field(6, C_UINT, "maturity");
        f[25] = Field(6, C_UINT, "maturityWindow");
        f[26] = Field(1, C_BOOL, "active");
        f[27] = Field(12, C_UINT, "openExecutionComp");
        f[28] = Field(1, C_BOOL, "useInternalBalances");
    }

    function _closeDutchFields() internal pure returns (Field[] memory f) {
        f = new Field[](11);
        f[0] = Field(20, C_ADDR, "swapper");
        f[1] = Field(20, C_ADDR, "collatToken");
        f[2] = Field(32, C_FULL, "swapId");
        f[3] = Field(16, C_UINT, "maxReward");
        f[4] = Field(16, C_UINT, "startingReward");
        f[5] = Field(3, C_UINT, "roundLength");
        f[6] = Field(2, C_UINT, "growthRate");
        f[7] = Field(2, C_UINT, "maxRounds");
        f[8] = Field(6, C_UINT, "start");
        f[9] = Field(6, C_UINT, "expiration");
        f[10] = Field(1, C_BOOL, "useInternalBalances");
    }

    function _oracleGameFields() internal pure returns (Field[] memory f) {
        f = new Field[](20);
        f[0] = Field(16, C_UINT, "currentAmount1");
        f[1] = Field(16, C_UINT, "currentAmount2");
        f[2] = Field(20, C_ADDR, "currentReporter");
        f[3] = Field(6, C_UINT, "reportTimestamp");
        f[4] = Field(6, C_UINT, "settlementTimestamp");
        f[5] = Field(20, C_ADDR, "token1");
        f[6] = Field(6, C_UINT, "lastReportOppoTime");
        f[7] = Field(6, C_UINT, "settlementTime");
        f[8] = Field(16, C_UINT, "escalationHalt");
        f[9] = Field(20, C_ADDR, "protocolFeeRecipient");
        f[10] = Field(12, C_UINT, "settlerReward");
        f[11] = Field(20, C_ADDR, "token2");
        f[12] = Field(3, C_UINT, "numReports");
        f[13] = Field(3, C_UINT, "disputeDelay");
        f[14] = Field(3, C_UINT, "feePercentage");
        f[15] = Field(2, C_UINT, "multiplier");
        f[16] = Field(20, C_ADDR, "callbackContract");
        f[17] = Field(4, C_UINT, "callbackGasLimit");
        f[18] = Field(3, C_UINT, "protocolFee");
        f[19] = Field(1, C_UINT, "flags");
    }

    function _preimageHelperFields() internal pure returns (Field[] memory f) {
        f = new Field[](4);
        f[0] = Field(32, C_FULL, "reportId");
        f[1] = Field(20, C_ADDR, "creator");
        f[2] = Field(32, C_FULL, "blockTimestamp");
        f[3] = Field(32, C_FULL, "blockNumber");
    }

    /// @dev Total number of high-padding bytes a struct exposes. Full-width members contribute
    ///      nothing. Reported per struct so coverage counts are auditable.
    function _paddingByteCount(Field[] memory f) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < f.length; i++) {
            n += 32 - f[i].width;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Raw calldata primitives
    // ══════════════════════════════════════════════════════════════════

    function _readWord(bytes memory data, uint256 byteOffset) internal pure returns (bytes32 w) {
        require(byteOffset + 32 <= data.length, "readWord: out of range");
        assembly {
            w := mload(add(add(data, 0x20), byteOffset))
        }
    }

    function _writeWord(bytes memory data, uint256 byteOffset, bytes32 value) internal pure {
        require(byteOffset + 32 <= data.length, "writeWord: out of range");
        assembly {
            mstore(add(add(data, 0x20), byteOffset), value)
        }
    }

    function _writeByte(bytes memory data, uint256 byteOffset, uint8 value) internal pure {
        require(byteOffset < data.length, "writeByte: out of range");
        data[byteOffset] = bytes1(value);
    }

    function _readByte(bytes memory data, uint256 byteOffset) internal pure returns (uint8) {
        require(byteOffset < data.length, "readByte: out of range");
        return uint8(data[byteOffset]);
    }

    /// @dev Every mutation group first checks the target offset against the clean encoding, so a
    ///      manifest error appears as a fixture failure instead of a vacuously passing test.
    function _assertCleanWord(bytes memory data, uint256 byteOffset, bytes32 expected, string memory what)
        internal
        pure
    {
        require(_readWord(data, byteOffset) == expected, string.concat("offset self-check failed for ", what));
    }

    function _copyBytes(bytes memory src) internal pure returns (bytes memory out) {
        out = new bytes(src.length);
        for (uint256 i = 0; i < src.length; i++) {
            out[i] = src[i];
        }
    }

    function _append(bytes memory data, bytes memory suffix) internal pure returns (bytes memory) {
        return bytes.concat(data, suffix);
    }

    function _truncate(bytes memory data, uint256 newLength) internal pure returns (bytes memory out) {
        require(newLength <= data.length, "truncate: longer than input");
        out = new bytes(newLength);
        for (uint256 i = 0; i < newLength; i++) {
            out[i] = data[i];
        }
    }

    /// @dev A dirty variant of `data` with one padding byte of one member set nonzero.
    ///      `padIndex` counts from the high end of the word (0 = most significant byte).
    function _dirtyPaddingByte(bytes memory clean, uint256 memberByteOffset, uint256 padIndex, uint8 value)
        internal
        pure
        returns (bytes memory out)
    {
        out = _copyBytes(clean);
        _writeByte(out, _argOffset(memberByteOffset) + padIndex, value);
    }

    // ── low-level delivery ──────────────────────────────────────────────

    function _rawCall(address target, address from, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(from);
        (ok, ret) = target.call{value: value}(data);
    }

    function _rawCallPunt(address from, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        return _rawCall(address(punt), from, value, data);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Revert classification
    // ══════════════════════════════════════════════════════════════════

    uint8 internal constant R_OK = 0;
    uint8 internal constant R_EMPTY = 1; // ABI decode failure: revert with no returndata
    uint8 internal constant R_SELECTOR = 2; // a custom error
    uint8 internal constant R_STRING = 3; // Error(string)
    uint8 internal constant R_OTHER = 4;

    function _classify(bool ok, bytes memory ret) internal pure returns (uint8 kind, bytes4 selector) {
        if (ok) return (R_OK, bytes4(0));
        if (ret.length == 0) return (R_EMPTY, bytes4(0));
        bytes4 sel = bytes4(ret);
        if (sel == bytes4(0x08c379a0)) return (R_STRING, sel); // Error(string)
        if (ret.length == 4) return (R_SELECTOR, sel);
        if (ret.length >= 4) return (R_SELECTOR, sel);
        return (R_OTHER, sel);
    }

    function _assertRevertedWith(bool ok, bytes memory ret, bytes4 expected, string memory what) internal pure {
        (uint8 kind, bytes4 sel) = _classify(ok, ret);
        require(!ok, string.concat(what, ": expected revert but the call SUCCEEDED"));
        require(kind == R_SELECTOR, string.concat(what, ": expected a custom error"));
        require(sel == expected, string.concat(what, ": wrong error selector"));
    }

    function _assertRevertedEmpty(bool ok, bytes memory ret, string memory what) internal pure {
        require(!ok, string.concat(what, ": expected revert but the call SUCCEEDED"));
        require(ret.length == 0, string.concat(what, ": expected EMPTY returndata (ABI decode failure)"));
    }

    /// @dev "Fail-closed" = rejected somehow, without caring which guard fired. Callers that
    ///      care about the category assert it explicitly; this is for the bulk padding sweeps,
    ///      which additionally reconcile state through `_assertStateUnchanged`.
    function _assertFailedClosed(bool ok, bytes memory ret, string memory what)
        internal
        pure
        returns (uint8 kind, bytes4 sel)
    {
        require(!ok, string.concat(what, ": DIRTY INPUT WAS ACCEPTED"));
        (kind, sel) = _classify(ok, ret);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Protocol state snapshot
    // ══════════════════════════════════════════════════════════════════

    struct Book {
        uint256 nextSwapId;
        bytes32 swapHash;
        bytes32 dutchHash;
        bool closeIntent;
        uint128 pendingExecComp;
        uint128 hbReportId;
        uint48 hbTimestamp;
        uint256 puntEth;
        uint256 moduleEth;
        uint256 swapperCollat;
        uint256 matcherCollat;
        uint256 puntCollatInternal;
        uint256 puntEthInternal;
        uint256 oracleCustody;
        uint256 nextReportId;
    }

    function _book(uint256 swapId, address collatToken) internal view returns (Book memory b) {
        b.nextSwapId = punt.nextSwapId();
        b.swapHash = punt.swaps(swapId);
        b.dutchHash = _storedDutchState(swapId);
        (b.pendingExecComp,, b.closeIntent) = _closeState(swapId);
        (b.hbReportId, b.hbTimestamp) = punt.liquidationHeartbeats(swapId);
        b.puntEth = address(punt).balance;
        b.moduleEth = address(lifecycleModule).balance;
        b.swapperCollat = _rawBalanceOf(collatToken, swapper);
        b.matcherCollat = _rawBalanceOf(collatToken, matcher);
        b.puntCollatInternal = _spendable(address(punt), collatToken);
        b.puntEthInternal = _spendable(address(punt), address(0));
        b.oracleCustody = _rawBalanceOf(collatToken, address(oracle));
        b.nextReportId = oracle.nextReportId();
    }

    function _assertStateUnchanged(Book memory before, uint256 swapId, address collatToken, string memory what)
        internal
        view
    {
        Book memory now_ = _book(swapId, collatToken);
        require(now_.nextSwapId == before.nextSwapId, string.concat(what, ": nextSwapId moved"));
        require(now_.swapHash == before.swapHash, string.concat(what, ": position hash moved"));
        require(now_.dutchHash == before.dutchHash, string.concat(what, ": Dutch hash moved"));
        require(now_.closeIntent == before.closeIntent, string.concat(what, ": close intent moved"));
        require(now_.pendingExecComp == before.pendingExecComp, string.concat(what, ": pending exec comp moved"));
        require(now_.hbReportId == before.hbReportId, string.concat(what, ": heartbeat report id moved"));
        require(now_.hbTimestamp == before.hbTimestamp, string.concat(what, ": heartbeat timestamp moved"));
        require(now_.puntEth == before.puntEth, string.concat(what, ": core ETH moved"));
        require(now_.moduleEth == before.moduleEth, string.concat(what, ": module ETH moved"));
        require(now_.swapperCollat == before.swapperCollat, string.concat(what, ": swapper collateral moved"));
        require(now_.matcherCollat == before.matcherCollat, string.concat(what, ": matcher collateral moved"));
        require(
            now_.puntCollatInternal == before.puntCollatInternal,
            string.concat(what, ": core internal collateral moved")
        );
        require(now_.puntEthInternal == before.puntEthInternal, string.concat(what, ": core internal ETH moved"));
        require(now_.oracleCustody == before.oracleCustody, string.concat(what, ": oracle custody moved"));
        require(now_.nextReportId == before.nextReportId, string.concat(what, ": nextReportId moved"));
    }

    function _rawBalanceOf(address token, address who) internal view returns (uint256) {
        if (token == address(0)) return who.balance;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(ret, (uint256));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Lifecycle fixtures (all reached through real calls)
    // ══════════════════════════════════════════════════════════════════

    function _setUpDirty() internal {
        _setUpTokenCompat();
        vm.txGasPrice(1 gwei); // heartbeats reject forced (zero gas price) transactions
    }

    /// @dev Active position with the liquidation-heartbeat mode enabled, so
    ///      `liquidationHeartbeat()`, which hashes the whole MatchedSwap, is a live entry point.
    function _openHeartbeatPosition()
        internal
        returns (uint256 swapId, OpenPuntStorage.MatchedSwap memory active, OpenPuntStorage.MatcherPreimage memory pre)
    {
        (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG;
        s.liquidationHeartbeatMin = 30;
        s.liquidationHeartbeatMax = 300;
        m.disputeDelay = 5;
        Proposal memory p;
        (swapId, active, p) = _openAccounting(s, m);
        // The emitted preimage, not the input: propose() overrides startFulfillFeeIncrease, and
        // it is the overridden struct that the position's matcherPreimageHash commits to
        pre = p.preimage;
        assertTrue(active.active, "fixture: active position");
        assertEq(punt.swapIdToReportId(swapId), 0, "fixture: idle position");
    }
}
