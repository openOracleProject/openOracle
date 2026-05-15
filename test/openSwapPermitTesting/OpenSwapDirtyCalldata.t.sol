// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice Per-field "value vs value+1" boundary probe of propose() calldata. For each
///         sub-256-bit field, the byte immediately above the value bytes is set to 0x00
///         (value within declared width → must succeed) and then to 0x01 (value = type-max + 1
///         → must revert). Bool: 0x00 (=false) vs 0x02 (=2).
contract OpenSwapDirtyCalldataTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function _buildCleanInputs()
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        SwapCompat.OracleParams memory op = _defaultOracleParams();
        openSwapV2.SlippageParams memory slip = _defaultSlippage();
        openSwapV2.FulfillFeeParams memory ff = _defaultFulfillFee();

        s.sellAmt = SELL_AMT;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.settlerReward = op.settlerReward;
        s.maxGameTime = op.maxGameTime;
        s.blocksPerSecond = op.blocksPerSecond;
        s.buyToken = address(buyToken);
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.sellToken = address(sellToken);
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = false;
        s.expiration = uint48(1 hours);
        s.slippageParams = slip;

        m.initialLiquidity = op.initialLiquidity;
        m.escalationHalt = op.escalationHalt;
        m.settlementTime = op.settlementTime;
        m.disputeDelay = op.disputeDelay;
        m.protocolFee = op.protocolFee;
        m.multiplier = op.multiplier;
        m.maxFee = ff.maxFee;
        m.startingFee = ff.startingFee;
        m.roundLength = ff.roundLength;
        m.growthRate = ff.growthRate;
        m.maxRounds = ff.maxRounds;
    }

    /// @dev Build clean abi-encoded propose() call, set byte at `byteOffset` (from start of
    ///      args, post-selector) to `b`, low-level call. Returns ok.
    function _proposeWithByte(uint256 byteOffset, uint8 b) internal returns (bool ok) {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _buildCleanInputs();
        bytes memory data = abi.encodeCall(swapContract.propose, (s, m, _emptyPermit2(), MIN_OUT));
        data[4 + byteOffset] = bytes1(b);

        uint256 eth = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        vm.prank(swapper);
        (ok,) = address(swapContract).call{value: eth}(data);
    }

    /// @dev Boundary check: clean byte (0x00) at the padding-edge succeeds; +1 (0x01) reverts.
    function _assertBoundary(uint256 slotOffset, uint256 valueBytes, string memory label) internal {
        uint256 byteIdx = slotOffset + 32 - valueBytes - 1;
        assertTrue(_proposeWithByte(byteIdx, 0x00), string.concat(label, ": value must not revert"));
        uint256 idAfterClean = swapContract.nextSwapId();
        assertFalse(_proposeWithByte(byteIdx, 0x01), string.concat(label, ": value+1 must revert"));
        assertEq(swapContract.nextSwapId(), idAfterClean, "nextSwapId unchanged after value+1");
        assertEq(swapContract.swaps(idAfterClean), bytes32(0), "no swap hash on value+1");
    }

    /// @dev Bool boundary: byte 31 = 0x00 succeeds; 0x02 (= max + 1) reverts.
    function _assertBoolBoundary(uint256 slotOffset, string memory label) internal {
        uint256 byteIdx = slotOffset + 31;
        assertTrue(_proposeWithByte(byteIdx, 0x00), string.concat(label, ": false must not revert"));
        uint256 idAfterClean = swapContract.nextSwapId();
        assertFalse(_proposeWithByte(byteIdx, 0x02), string.concat(label, ": bool=2 must revert"));
        assertEq(swapContract.nextSwapId(), idAfterClean, "nextSwapId unchanged after bool=2");
        assertEq(swapContract.swaps(idAfterClean), bytes32(0), "no swap hash on bool=2");
    }

    function testDirtyCalldata_CleanCallSucceeds() public {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _buildCleanInputs();
        bytes memory data = abi.encodeCall(swapContract.propose, (s, m, _emptyPermit2(), MIN_OUT));
        uint256 eth = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;
        vm.prank(swapper);
        (bool ok,) = address(swapContract).call{value: eth}(data);
        assertTrue(ok, "clean abi.encodeCall must succeed");
    }

    // ProposedSwap layout:
    //   0x000  sellAmt              uint128
    //   0x020  minFulfillLiquidity  uint128
    //   0x040  settlerReward        uint96
    //   0x060  maxGameTime          uint24
    //   0x080  blocksPerSecond      uint16
    //   0x0A0  buyToken             address
    //   0x0C0  matcherGasComp       uint96
    //   0x0E0  sellToken            address
    //   0x100  swapper              address     (override; expected = 0)
    //   0x120  executorGasComp      uint96
    //   0x140  useInternalBalances  bool
    //   0x160  expiration           uint48      (override; expected = offset)
    //   0x180  priceTolerated       uint232     (inline SlippageParams)
    //   0x1A0  toleranceRange       uint24
    // MatcherPreimage at 0x1C0:
    //   0x1C0  initialLiquidity     uint128
    //   0x1E0  escalationHalt       uint128
    //   0x200  settlementTime       uint48
    //   0x220  disputeDelay         uint24
    //   0x240  protocolFee          uint24
    //   0x260  multiplier           uint16
    //   0x280  startFulfillFeeIncrease uint48   (override; expected = 0)
    //   0x2A0  maxFee               uint24
    //   0x2C0  startingFee          uint24
    //   0x2E0  roundLength          uint24
    //   0x300  growthRate           uint16
    //   0x320  maxRounds            uint16
    // Tail head:
    //   0x340  Permit2Params offset (dynamic)
    //   0x360  minOut               uint128

    function testBoundary_SellAmt() public { _assertBoundary(0x000, 16, "sellAmt"); }
    function testBoundary_MinFulfillLiquidity() public { _assertBoundary(0x020, 16, "minFulfillLiquidity"); }
    function testBoundary_SettlerReward() public { _assertBoundary(0x040, 12, "settlerReward"); }
    function testBoundary_MaxGameTime() public { _assertBoundary(0x060, 3, "maxGameTime"); }
    function testBoundary_BlocksPerSecond() public { _assertBoundary(0x080, 2, "blocksPerSecond"); }
    function testBoundary_BuyToken() public { _assertBoundary(0x0A0, 20, "buyToken"); }
    function testBoundary_MatcherGasComp() public { _assertBoundary(0x0C0, 12, "matcherGasComp"); }
    function testBoundary_SellToken() public { _assertBoundary(0x0E0, 20, "sellToken"); }
    function testBoundary_Swapper() public { _assertBoundary(0x100, 20, "swapper"); }
    function testBoundary_ExecutorGasComp() public { _assertBoundary(0x120, 12, "executorGasComp"); }
    function testBoundary_UseInternalBalances() public { _assertBoolBoundary(0x140, "useInternalBalances"); }
    function testBoundary_Expiration() public { _assertBoundary(0x160, 6, "expiration"); }
    function testBoundary_PriceTolerated() public { _assertBoundary(0x180, 29, "priceTolerated"); }
    function testBoundary_ToleranceRange() public { _assertBoundary(0x1A0, 3, "toleranceRange"); }
    function testBoundary_InitialLiquidity() public { _assertBoundary(0x1C0, 16, "initialLiquidity"); }
    function testBoundary_EscalationHalt() public { _assertBoundary(0x1E0, 16, "escalationHalt"); }
    function testBoundary_SettlementTime() public { _assertBoundary(0x200, 6, "settlementTime"); }
    function testBoundary_DisputeDelay() public { _assertBoundary(0x220, 3, "disputeDelay"); }
    function testBoundary_ProtocolFee() public { _assertBoundary(0x240, 3, "protocolFee"); }
    function testBoundary_Multiplier() public { _assertBoundary(0x260, 2, "multiplier"); }
    function testBoundary_StartFulfillFeeIncrease() public { _assertBoundary(0x280, 6, "startFulfillFeeIncrease"); }
    function testBoundary_MaxFee() public { _assertBoundary(0x2A0, 3, "maxFee"); }
    function testBoundary_StartingFee() public { _assertBoundary(0x2C0, 3, "startingFee"); }
    function testBoundary_RoundLength() public { _assertBoundary(0x2E0, 3, "roundLength"); }
    function testBoundary_GrowthRate() public { _assertBoundary(0x300, 2, "growthRate"); }
    function testBoundary_MaxRounds() public { _assertBoundary(0x320, 2, "maxRounds"); }
    function testBoundary_MinOut() public { _assertBoundary(0x360, 16, "minOut"); }
}
