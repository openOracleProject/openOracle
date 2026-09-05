// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OpenPuntDataProvider, IOpenPuntDataSource} from "../../src/levered-swaps/OpenPuntDataProvider.sol";
import {IOpenOracle2} from "../../src/interfaces/IOpenOracle2.sol";

/// @dev Getter-compatible fixture; these tests exercise discovery/status semantics without
///      running oracle games. Real lifecycle metadata transitions are covered by RecoveryIndex.t.sol.
contract PuntDataSourceFixture {
    struct Blocks {
        uint48 openedBlock;
        uint48 terminalBlock;
        uint48 reportStartBlock;
    }

    struct Auction {
        uint128 maxReward;
        uint128 startingReward;
        uint128 executionComp;
        uint48 start;
        uint24 roundLength;
        uint16 expirationDuration;
        uint16 growthRate;
        uint8 maxRounds;
        bool useInternalBalances;
    }

    struct Heartbeat {
        uint128 reportId;
        uint48 timestamp;
    }

    uint256 public nextSwapId = 7;
    mapping(uint256 => bytes32) public swaps;
    mapping(address => uint256) public numSwapsBySwapper;
    mapping(address => mapping(uint256 => uint256)) public swapperSwapData;
    mapping(uint256 => Blocks) public recoveryBlocks;
    mapping(uint256 => uint256) public swapIdToReportId;
    mapping(uint256 => uint48) public closeRequestBlock;
    mapping(uint256 => uint128) public executionGasComp;
    mapping(uint256 => Auction) public closeAuctions;
    mapping(uint256 => Heartbeat) public liquidationHeartbeats;
    mapping(uint256 => uint48) public settlementEligibility;

    constructor(address swapper) {
        swaps[1] = bytes32(uint256(1)); // proposed
        swaps[2] = bytes32(uint256(2)); // opening
        swaps[3] = bytes32(uint256(3)); // active, idle
        swaps[4] = bytes32(uint256(4)); // active, report bound
        // 5: ended before opening; 6: closed/liquidated
        recoveryBlocks[2] = Blocks(0, 0, 20);
        recoveryBlocks[3] = Blocks(30, 0, 0);
        recoveryBlocks[4] = Blocks(40, 0, 45);
        recoveryBlocks[6] = Blocks(60, 70, 0);
        swapIdToReportId[2] = 12;
        swapIdToReportId[4] = 14;
        closeRequestBlock[4] = 44;
        executionGasComp[12] = 120;
        executionGasComp[14] = 140;
        closeAuctions[4] = Auction(400, 100, 40, 41, 2, 60, 11_000, 8, true);
        liquidationHeartbeats[4] = Heartbeat(14, 43);
        settlementEligibility[14] = 55;
        numSwapsBySwapper[swapper] = 3;
        swapperSwapData[swapper][0] = (uint256(5) << 48) | 11;
        swapperSwapData[swapper][1] = (uint256(4) << 48) | 12;
        swapperSwapData[swapper][2] = (uint256(6) << 48) | 13;
    }

    function clearHash(uint256 id) external {
        swaps[id] = bytes32(0);
    }
}

contract OpenPuntDataProviderTest {
    address internal constant SWAPPER = address(0x1234);
    PuntDataSourceFixture internal source;
    OpenPuntDataProvider internal provider;

    function setUp() public {
        source = new PuntDataSourceFixture(SWAPPER);
        provider = new OpenPuntDataProvider(IOpenPuntDataSource(address(source)), IOpenOracle2(address(source)));
    }

    function test_statusDistinguishesEveryLifecyclePhase() public view {
        _status(0, OpenPuntDataProvider.SwapStatus.NotCreated);
        _status(1, OpenPuntDataProvider.SwapStatus.Proposed);
        _status(2, OpenPuntDataProvider.SwapStatus.Opening);
        _status(3, OpenPuntDataProvider.SwapStatus.Active);
        _status(4, OpenPuntDataProvider.SwapStatus.Active);
        _status(5, OpenPuntDataProvider.SwapStatus.EndedBeforeOpening);
        _status(6, OpenPuntDataProvider.SwapStatus.ClosedOrLiquidated);
        _status(7, OpenPuntDataProvider.SwapStatus.NotCreated);
        _status(type(uint256).max, OpenPuntDataProvider.SwapStatus.NotCreated);
    }

    function test_zeroHashTakesPrecedenceOverRemainingLiveMetadata() public {
        source.clearHash(2);
        source.clearHash(4);
        OpenPuntDataProvider.SwapView memory opening = provider.getSwap(2);
        OpenPuntDataProvider.SwapView memory active = provider.getSwap(4);
        require(opening.status == OpenPuntDataProvider.SwapStatus.EndedBeforeOpening, "ended opening");
        require(active.status == OpenPuntDataProvider.SwapStatus.ClosedOrLiquidated, "ended position");
        require(opening.reportId == 0 && active.reportId == 0, "no live report for zero hash");
        require(active.executionComp == 0 && active.closeRequestBlock == 0, "no live controls for zero hash");
    }

    function test_liveReportMetadataAndIdleState() public view {
        OpenPuntDataProvider.SwapView memory s = provider.getSwap(4);
        require(s.swapId == 4 && s.swapHash == bytes32(uint256(4)), "identity");
        require(s.openedBlock == 40 && s.terminalBlock == 0 && s.reportStartBlock == 45, "event blocks");
        require(s.reportId == 14 && s.executionComp == 140 && s.closeRequestBlock == 44, "report controls");
        s = provider.getSwap(3);
        require(s.reportId == 0 && s.executionComp == 0 && s.reportStartBlock == 0, "idle position");
    }

    function test_detailReturnsSwapAuctionHeartbeatAndEligibility() public view {
        OpenPuntDataProvider.SwapDetailView memory detail = provider.getSwapDetail(4);
        require(detail.swap.swapId == 4 && detail.swap.status == OpenPuntDataProvider.SwapStatus.Active, "swap");
        require(
            detail.auction.maxReward == 400 && detail.auction.startingReward == 100
                && detail.auction.executionComp == 40,
            "auction amounts"
        );
        require(
            detail.auction.start == 41 && detail.auction.roundLength == 2 && detail.auction.expirationDuration == 60,
            "auction timing"
        );
        require(
            detail.auction.growthRate == 11_000 && detail.auction.maxRounds == 8 && detail.auction.useInternalBalances,
            "auction policy"
        );
        require(detail.heartbeat.reportId == 14 && detail.heartbeat.timestamp == 43, "heartbeat");
        require(detail.settlementEligibility == 55, "eligibility");

        detail = provider.getSwapDetail(2);
        require(detail.swap.status == OpenPuntDataProvider.SwapStatus.Opening, "opening");
        require(detail.settlementEligibility == 0, "opening eligibility omitted");
    }

    function test_detailArrayPreservesOrderDuplicatesAndUnknownRows() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 4;
        ids[1] = 2;
        ids[2] = 4;
        ids[3] = 99;
        OpenPuntDataProvider.SwapDetailView[] memory result = provider.getSwapDetail(ids);
        require(result.length == 4, "length");
        require(result[0].settlementEligibility == 55 && result[2].settlementEligibility == 55, "duplicates");
        require(result[1].swap.swapId == 2 && result[1].swap.status == OpenPuntDataProvider.SwapStatus.Opening, "order");
        require(result[3].swap.swapId == 99, "unknown identity");
        require(result[3].swap.status == OpenPuntDataProvider.SwapStatus.NotCreated, "unknown status");
        require(provider.getSwapDetail(new uint256[](0)).length == 0, "empty array");
    }

    function test_detailRangeClampsLikeLeanRange() public view {
        OpenPuntDataProvider.SwapDetailView[] memory result = provider.getSwapDetail(4, type(uint256).max);
        require(result.length == 3, "tail length");
        require(result[0].swap.swapId == 4 && result[0].settlementEligibility == 55, "first detail");
        require(result[2].swap.swapId == 6, "last detail");
        require(provider.getSwapDetail(type(uint256).max, type(uint256).max).length == 0, "far start");
        require(provider.getSwapDetail(1, 0).length == 0, "zero count");
    }

    function test_idArrayPreservesOrderDuplicatesAndUncreatedRows() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 6;
        ids[1] = 1;
        ids[2] = 6;
        ids[3] = 99;
        OpenPuntDataProvider.SwapView[] memory result = provider.getSwap(ids);
        require(result.length == 4, "one result per input");
        require(result[0].swapId == 6 && result[1].swapId == 1 && result[2].swapId == 6, "input order");
        require(result[3].swapId == 99 && result[3].status == OpenPuntDataProvider.SwapStatus.NotCreated, "unknown");
        require(provider.getSwap(new uint256[](0)).length == 0, "empty array");
    }

    function test_idRangeClampsWithoutAdditionOverflow() public view {
        OpenPuntDataProvider.SwapView[] memory result = provider.getSwap(5, type(uint256).max);
        require(result.length == 2 && result[0].swapId == 5 && result[1].swapId == 6, "tail page");
        require(provider.getSwap(type(uint256).max, type(uint256).max).length == 0, "far start");
        require(provider.getSwap(1, 0).length == 0, "zero count");
        result = provider.getSwap(0, 2);
        require(result.length == 2 && result[0].status == OpenPuntDataProvider.SwapStatus.NotCreated, "zero ID");
        require(result[1].swapId == 1, "range from zero");
    }

    function test_swapperEntriesDecodePackedIdsAndKeepInactiveRows() public view {
        OpenPuntDataProvider.SwapperSwapView memory entry = provider.getSwapperSwap(SWAPPER, 0);
        require(entry.index == 0 && entry.proposedBlock == 11 && entry.swap.swapId == 5, "decode");
        require(entry.swap.status == OpenPuntDataProvider.SwapStatus.EndedBeforeOpening, "inactive retained");
        entry = provider.getSwapperSwap(SWAPPER, 2);
        require(entry.proposedBlock == 13 && entry.swap.terminalBlock == 70, "terminal recovery");
    }

    function test_swapperArrayPreservesOrderAndDuplicates() public view {
        uint256[] memory indices = new uint256[](3);
        indices[0] = 2;
        indices[1] = 0;
        indices[2] = 2;
        OpenPuntDataProvider.SwapperSwapView[] memory result = provider.getSwapperSwap(SWAPPER, indices);
        require(result.length == 3, "length");
        require(result[0].swap.swapId == 6 && result[1].swap.swapId == 5 && result[2].swap.swapId == 6, "order");
        require(provider.getSwapperSwap(SWAPPER, new uint256[](0)).length == 0, "empty array");
    }

    function test_swapperPageClampsAndReturnsTotal() public view {
        (OpenPuntDataProvider.SwapperSwapView[] memory result, uint256 total) =
            provider.getSwapperSwap(SWAPPER, 1, type(uint256).max);
        require(total == 3 && result.length == 2, "count and clamp");
        require(result[0].index == 1 && result[1].index == 2, "stable indices");
        (result, total) = provider.getSwapperSwap(SWAPPER, type(uint256).max, type(uint256).max);
        require(total == 3 && result.length == 0, "beyond end");
        (result, total) = provider.getSwapperSwap(address(0x5678), 0, 10);
        require(total == 0 && result.length == 0, "unknown swapper");
        (result, total) = provider.getSwapperSwap(SWAPPER, 1, 0);
        require(total == 3 && result.length == 0, "zero count");
    }

    function test_invalidSwapperIndexRevertsSingleAndArray() public view {
        try provider.getSwapperSwap(SWAPPER, 3) {
            revert("single should reject invalid index");
        } catch (bytes memory reason) {
            require(bytes4(reason) == OpenPuntDataProvider.SwapperIndexOutOfBounds.selector, "single error");
        }
        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 3;
        try provider.getSwapperSwap(SWAPPER, indices) {
            revert("array should reject invalid index");
        } catch (bytes memory reason) {
            require(bytes4(reason) == OpenPuntDataProvider.SwapperIndexOutOfBounds.selector, "batch error");
        }
    }

    function test_zeroCoreAddressRejected() public {
        try new OpenPuntDataProvider(IOpenPuntDataSource(address(0)), IOpenOracle2(address(source))) {
            revert("zero core should revert");
        } catch (bytes memory reason) {
            require(bytes4(reason) == OpenPuntDataProvider.AddressCannotBeZero.selector, "constructor error");
        }
        try new OpenPuntDataProvider(IOpenPuntDataSource(address(source)), IOpenOracle2(address(0))) {
            revert("zero oracle should revert");
        } catch (bytes memory reason) {
            require(bytes4(reason) == OpenPuntDataProvider.AddressCannotBeZero.selector, "oracle constructor error");
        }
    }

    function _status(uint256 swapId, OpenPuntDataProvider.SwapStatus expected) internal view {
        require(provider.getSwap(swapId).status == expected, "incorrect status");
    }
}
