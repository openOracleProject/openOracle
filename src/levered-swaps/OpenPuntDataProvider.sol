// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "../interfaces/IOpenOracle2.sol";
import {OpenPuntStorage} from "./OpenPuntStorage.sol";

/// @dev Getter-only interface to the OpenPunt core, including its recovery index.
interface IOpenPuntDataSource {
    function nextSwapId() external view returns (uint256);
    function swaps(uint256 swapId) external view returns (bytes32);
    function numSwapsBySwapper(address swapper) external view returns (uint256);
    function swapperSwapData(address swapper, uint256 index) external view returns (uint256);
    function recoveryBlocks(uint256 swapId)
        external
        view
        returns (uint48 openedBlock, uint48 terminalBlock, uint48 reportStartBlock);
    function swapIdToReportId(uint256 swapId) external view returns (uint256);
    function closeRequestBlock(uint256 swapId) external view returns (uint48);
    function executionGasComp(uint256 reportId) external view returns (uint128);
    function closeAuctions(uint256 swapId)
        external
        view
        returns (
            uint128 maxReward,
            uint128 startingReward,
            uint128 executionComp,
            uint48 start,
            uint24 roundLength,
            uint16 expirationDuration,
            uint16 growthRate,
            uint8 maxRounds,
            bool useInternalBalances
        );
    function liquidationHeartbeats(uint256 swapId) external view returns (uint128 reportId, uint48 timestamp);
}

/**
 * @title OpenPuntDataProvider
 * @notice Read-only discovery and recovery metadata for OpenPunt proposals and positions.
 * @dev OpenPunt stores position hashes, not their preimages. This provider cannot reconstruct
 *      ProposedSwap, MatchedSwap, MatcherPreimage, prices, PnL, or execution outcomes from storage.
 *      Recover those inputs from logs and authenticate current preimages against swapHash.
 *
 *      Swapper entries point to SwapProposed logs. An opening report's reportStartBlock points
 *      to SwapMatched; later reports point to PositionReportStarted. openedBlock points to
 *      PositionOpened, and terminalBlock to PositionClosed or PositionLiquidated. These are
 *      event blocks, not economic settlement timestamps. A report pointer is overwritten for
 *      each new report and cleared when released, so it is not a historical report index.
 *
 *      terminalBlock is not recorded for cancellations or failed/bailout openings. swapHash
 *      is checked before assigning any live status. Status does not predict liquidation,
 *      executability, proposal expiry, or whether a bound oracle report is already settled.
 *
 *      Array/range overloads are looped views, not constant-cost queries. Paginate within your
 *      RPC's gas/response limits. Pin all page reads and log queries to the same block snapshot.
 *
 *      settlementEligibility is an optional OpenOracle sidecar. OpenPunt lifecycle reports made
 *      after a position opens populate it, but opening reports do not, so detail reads return zero
 *      during Opening. Recover opening eligibility from reportTimestamp + settlementTime in logs.
 */
contract OpenPuntDataProvider {
    error AddressCannotBeZero();
    error SwapperIndexOutOfBounds(uint256 index, uint256 total);

    IOpenPuntDataSource public immutable punt;
    IOpenOracle2 public immutable oracle;

    enum SwapStatus {
        NotCreated,
        Proposed,
        Opening,
        Active,
        EndedBeforeOpening,
        ClosedOrLiquidated
    }

    struct SwapView {
        uint256 swapId;
        bytes32 swapHash;
        SwapStatus status;
        uint48 openedBlock;
        uint48 terminalBlock;
        uint48 reportStartBlock;
        uint48 closeRequestBlock;
        uint256 reportId; // currently bound report; not necessarily still disputable
        uint128 executionComp; // reserved compensation for reportId; excludes oracle settler reward
    }

    struct SwapperSwapView {
        uint256 index; // zero-based index in this swapper's proposal history
        uint48 proposedBlock;
        SwapView swap;
    }

    struct SwapDetailView {
        SwapView swap;
        OpenPuntStorage.StoredDutch auction;
        OpenPuntStorage.LiquidationHeartbeat heartbeat;
        uint48 settlementEligibility;
    }

    struct SwapperSwapDetailView {
        uint256 index; // original zero-based index in this swapper's proposal history
        uint48 proposedBlock;
        SwapDetailView detail;
    }

    constructor(IOpenPuntDataSource punt_, IOpenOracle2 oracle_) {
        if (address(punt_) == address(0) || address(oracle_) == address(0)) revert AddressCannotBeZero();
        punt = punt_;
        oracle = oracle_;
    }

    /// @notice Returns metadata by global swap ID. Zero/unallocated IDs return NotCreated.
    function getSwap(uint256 swapId) external view returns (SwapView memory) {
        return _getSwap(swapId, punt.nextSwapId());
    }

    /// @notice Returns one result per requested ID, preserving order and duplicates.
    /// @dev Zero/unallocated IDs return NotCreated rather than reverting the batch.
    function getSwap(uint256[] calldata swapIds) external view returns (SwapView[] memory result) {
        uint256 nextId = punt.nextSwapId();
        result = new SwapView[](swapIds.length);
        for (uint256 i; i < swapIds.length; ++i) {
            result[i] = _getSwap(swapIds[i], nextId);
        }
    }

    /// @notice Reads up to count consecutive global IDs beginning at startId.
    /// @dev Clamps to nextSwapId (exclusive); an out-of-range start returns an empty array.
    ///      IDs begin at 1. A range beginning at 0 includes its NotCreated row if count > 0.
    function getSwap(uint256 startId, uint256 count) external view returns (SwapView[] memory result) {
        uint256 nextId = punt.nextSwapId();
        uint256 length = _pageLength(startId, count, nextId);
        result = new SwapView[](length);
        for (uint256 i; i < length; ++i) {
            result[i] = _getSwap(startId + i, nextId);
        }
    }

    /// @notice Returns full recovery metadata for one global swap ID.
    function getSwapDetail(uint256 swapId) external view returns (SwapDetailView memory) {
        return _getSwapDetail(swapId, punt.nextSwapId());
    }

    /// @notice Returns full recovery metadata for each requested global swap ID.
    function getSwapDetail(uint256[] calldata swapIds) external view returns (SwapDetailView[] memory result) {
        uint256 nextId = punt.nextSwapId();
        result = new SwapDetailView[](swapIds.length);
        for (uint256 i; i < swapIds.length; ++i) {
            result[i] = _getSwapDetail(swapIds[i], nextId);
        }
    }

    /// @notice Reads full recovery metadata for up to count consecutive global IDs from startId.
    /// @dev Clamps to nextSwapId (exclusive), matching the lean global-ID range overload.
    function getSwapDetail(uint256 startId, uint256 count) external view returns (SwapDetailView[] memory result) {
        uint256 nextId = punt.nextSwapId();
        uint256 length = _pageLength(startId, count, nextId);
        result = new SwapDetailView[](length);
        for (uint256 i; i < length; ++i) {
            result[i] = _getSwapDetail(startId + i, nextId);
        }
    }

    /// @notice Returns oracle settlement eligibility for each report ID, preserving order and duplicates.
    /// @dev IDs are oracle report IDs, not swap IDs; terminal report IDs can be recovered from logs.
    ///      Returns zero when the oracle has no eligibility sidecar for a report (including openings).
    ///      Values are eligibility clocks, not proof of settlement; OpenPunt uses block numbers.
    function getSettlementEligibilities(uint256[] calldata reportIds) external view returns (uint48[] memory result) {
        result = new uint48[](reportIds.length);
        for (uint256 i; i < reportIds.length; ++i) {
            result[i] = oracle.settlementEligibility(reportIds[i]);
        }
    }

    /// @notice Returns a swapper's proposal entry by zero-based index, including inactive entries.
    /// @dev Reverts for an index >= numSwapsBySwapper(swapper).
    function getSwapperSwap(address swapper, uint256 index) external view returns (SwapperSwapView memory) {
        uint256 total = punt.numSwapsBySwapper(swapper);
        return _getSwapperSwap(swapper, index, total, punt.nextSwapId());
    }

    /// @notice Returns requested proposal indices in order, including duplicates and inactive entries.
    /// @dev Any invalid index reverts the whole batch. Indices are not global swap IDs.
    function getSwapperSwap(address swapper, uint256[] calldata indices)
        external
        view
        returns (SwapperSwapView[] memory result)
    {
        uint256 total = punt.numSwapsBySwapper(swapper);
        uint256 nextId = punt.nextSwapId();
        result = new SwapperSwapView[](indices.length);
        for (uint256 i; i < indices.length; ++i) {
            result[i] = _getSwapperSwap(swapper, indices[i], total, nextId);
        }
    }

    /// @notice Reads up to count proposal entries beginning at a swapper's zero-based startIndex.
    /// @dev Returns the total proposal count for pagination. Includes inactive entries without
    ///      filtering, so indices remain stable. An out-of-range start returns an empty page.
    function getSwapperSwap(address swapper, uint256 startIndex, uint256 count)
        external
        view
        returns (SwapperSwapView[] memory result, uint256 total)
    {
        total = punt.numSwapsBySwapper(swapper);
        uint256 nextId = punt.nextSwapId();
        uint256 length = _pageLength(startIndex, count, total);
        result = new SwapperSwapView[](length);
        for (uint256 i; i < length; ++i) {
            result[i] = _getSwapperSwap(swapper, startIndex + i, total, nextId);
        }
    }

    /// @notice Reads up to count proposal entries newest first, including full recovery metadata.
    /// @param offset Number of newest entries to skip; zero starts at the latest proposal.
    /// @dev Returns the total proposal count so the first page needs no separate count read.
    ///      Includes inactive entries without filtering. Each index remains its original ascending
    ///      proposal index; newest means proposal order, not most recently updated position.
    ///      Offsets at/beyond total and zero counts return an empty page. Counts are clamped.
    ///      Pin every page to the same block: a new proposal shifts offsets toward older entries.
    ///      Details include hashes and pointers, not preimages; reconstruct and hash-check those
    ///      from the pointed logs. Cost scales with the number of entries returned.
    function getSwapperSwapDetailsNewest(address swapper, uint256 offset, uint256 count)
        external
        view
        returns (SwapperSwapDetailView[] memory result, uint256 total)
    {
        total = punt.numSwapsBySwapper(swapper);
        uint256 nextId = punt.nextSwapId();
        uint256 length = _pageLength(offset, count, total);
        result = new SwapperSwapDetailView[](length);
        for (uint256 i; i < length; ++i) {
            uint256 index = total - 1 - offset - i;
            uint256 packed = punt.swapperSwapData(swapper, index);
            result[i] = SwapperSwapDetailView({
                index: index,
                proposedBlock: uint48(packed),
                detail: _getSwapDetail(packed >> 48, nextId)
            });
        }
    }

    function _getSwap(uint256 swapId, uint256 nextId) internal view returns (SwapView memory s) {
        s.swapId = swapId;
        if (swapId == 0 || swapId >= nextId) return s;

        s.swapHash = punt.swaps(swapId);
        (s.openedBlock, s.terminalBlock, s.reportStartBlock) = punt.recoveryBlocks(swapId);

        // An ended proposal may have no recovery blocks at all. Check the committed hash first.
        if (s.swapHash == bytes32(0)) {
            s.status = s.openedBlock == 0 ? SwapStatus.EndedBeforeOpening : SwapStatus.ClosedOrLiquidated;
            return s;
        }

        s.reportId = punt.swapIdToReportId(swapId);
        s.closeRequestBlock = punt.closeRequestBlock(swapId);
        if (s.reportId != 0) s.executionComp = punt.executionGasComp(s.reportId);

        if (s.openedBlock != 0) {
            s.status = SwapStatus.Active;
        } else {
            s.status = s.reportId == 0 ? SwapStatus.Proposed : SwapStatus.Opening;
        }
    }

    function _getSwapDetail(uint256 swapId, uint256 nextId) internal view returns (SwapDetailView memory detail) {
        detail.swap = _getSwap(swapId, nextId);

        (
            detail.auction.maxReward,
            detail.auction.startingReward,
            detail.auction.executionComp,
            detail.auction.start,
            detail.auction.roundLength,
            detail.auction.expirationDuration,
            detail.auction.growthRate,
            detail.auction.maxRounds,
            detail.auction.useInternalBalances
        ) = punt.closeAuctions(swapId);

        (detail.heartbeat.reportId, detail.heartbeat.timestamp) = punt.liquidationHeartbeats(swapId);

        if (detail.swap.reportId != 0) {
            detail.settlementEligibility = oracle.settlementEligibility(detail.swap.reportId);
        }
    }

    function _getSwapperSwap(address swapper, uint256 index, uint256 total, uint256 nextId)
        internal
        view
        returns (SwapperSwapView memory entry)
    {
        if (index >= total) revert SwapperIndexOutOfBounds(index, total);
        uint256 packed = punt.swapperSwapData(swapper, index);
        entry.index = index;
        entry.proposedBlock = uint48(packed);
        entry.swap = _getSwap(packed >> 48, nextId);
    }

    function _pageLength(uint256 start, uint256 count, uint256 end) internal pure returns (uint256) {
        if (start >= end) return 0;
        uint256 remaining = end - start;
        return count < remaining ? count : remaining;
    }
}
