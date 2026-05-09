// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {OpenOracle as OpenOracleGG} from "../../src/OpenOracleGasGolfing_ContractSizeLimit.sol";
import {MockERC20} from "../utils/MockERC20.sol";

// Shared base for OpenOracleGasGolfing behavioral tests.
abstract contract BaseGGTest is Test {
    OpenOracleGG internal oracle;
    MockERC20 internal token1;
    MockERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    // Storage slot of `oracleGame` mapping in OpenOracleGasGolfing.
    // OpenOracleErrors is a state-less abstract base, so layout starts at slot 0:
    //   slot 0 = nextReportId
    //   slot 1 = oracleGame
    uint256 internal constant ORACLE_GAME_SLOT = 1;

    function setUp() public virtual {
        oracle = new OpenOracleGG();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        token1.transfer(alice, 100 ether);
        token1.transfer(bob, 100 ether);
        token1.transfer(charlie, 100 ether);
        token2.transfer(alice, 100_000 ether);
        token2.transfer(bob, 100_000 ether);
        token2.transfer(charlie, 100_000 ether);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        _approveOracle(alice);
        _approveOracle(bob);
        _approveOracle(charlie);
    }

    function _approveOracle(address user) internal {
        vm.startPrank(user);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    // Read the current stateHash for a report directly from storage.
    function _stateHash(uint256 reportId) internal view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(reportId, ORACLE_GAME_SLOT));
        return vm.load(address(oracle), slot);
    }

    function _emptyTiming() internal pure returns (OpenOracleGG.TimingBoundaries memory) {
        return OpenOracleGG.TimingBoundaries({
            blockNumber: 0,
            blockNumberBound: 0,
            blockTimestamp: 0,
            blockTimestampBound: 0
        });
    }

    function _oracleCaller() internal returns (address) {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.Prank || mode == VmSafe.CallerMode.RecurrentPrank) return sender;
        return address(this);
    }

    function _submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries memory timing
    ) internal {
        oracle.submitInitialReport(
            reportId,
            amount1,
            amount2,
            stateHash,
            _oracleCaller(),
            tryInternalBalance1,
            tryInternalBalance2,
            timing
        );
    }

    function _submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        address reporter,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries memory timing
    ) internal {
        oracle.submitInitialReport(
            reportId, amount1, amount2, stateHash, reporter, tryInternalBalance1, tryInternalBalance2, timing
        );
    }

    function _disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        uint128 amt2Expected,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries memory timing
    ) internal {
        oracle.disputeAndSwap(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            _oracleCaller(),
            amt2Expected,
            stateHash,
            tryInternalBalance1,
            tryInternalBalance2,
            timing
        );
    }

    function _disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        address disputer,
        uint128 amt2Expected,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries memory timing
    ) internal {
        oracle.disputeAndSwap(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            disputer,
            amt2Expected,
            stateHash,
            tryInternalBalance1,
            tryInternalBalance2,
            timing
        );
    }

    // Mirrors the contract's `_hashOracle` so calldata-mode tests can compute the state hash.
    function _hashOracle(OpenOracleGG.OracleGame memory game, OpenOracleGG.PreimageHelper memory helper)
        internal
        pure
        returns (bytes32)
    {
        bytes32 saved = game.stateHash;
        game.stateHash = bytes32(0);
        bytes32 h = keccak256(abi.encode(game, helper));
        game.stateHash = saved;
        return h;
    }

    function _defaultParams() internal view returns (OpenOracleGG.CreateReportParams memory) {
        return OpenOracleGG.CreateReportParams({
            exactToken1Report: 1e18,
            escalationHalt: 10e18,
            settlerReward: 0.001 ether,
            token1Address: address(token1),
            settlementTime: uint48(300),
            disputeDelay: uint24(5),
            protocolFee: uint24(1000),
            token2Address: address(token2),
            callbackGasLimit: 0,
            feePercentage: uint24(3000),
            multiplier: uint16(110),
            timeType: true,
            trackDisputes: false,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: protocolFeeRecipient
        });
    }

    // Read just the protocol-fee-recipient balance without the dust sentinel adjustment.
    function _heldTokens(address user, address token) internal view returns (uint256) {
        return oracle.tokenHolder(user, token);
    }
}
