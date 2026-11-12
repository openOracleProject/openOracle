// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../utils/SlimTestBase.sol";
import "../utils/PackedDecoder.sol";
import {SwapCompat} from "./SwapCompat.sol";

/// @notice Solady's predictDeterministicAddress returns a raw keccak256 word (upper 96 bits dirty).
///         matchSwap writes it into s.feeRecipient and hashes the struct's raw memory, so the
///         stored hash only matches abi.encode(_swap) if the memory write masks the address.
contract OpenSwapFeeRecipientCleanBitsTest is SlimTestBase {
    uint24 constant PROTO_FEE = 1000;
    bytes32 internal constant SWAP_MATCHED_SIG = keccak256("SwapMatched(uint256,bytes)");
    uint256 internal constant FEE_RECIPIENT_OFFSET = 0x180; // MatchedSwap field 12

    function setUp() public {
        _setUpAll();
    }

    function _defaultOracleParams() internal view override returns (SwapCompat.OracleParams memory p) {
        p = super._defaultOracleParams();
        p.protocolFee = PROTO_FEE;
    }

    /// @dev Raw word as returned by Solady, before any Solidity cleanup.
    function _rawPrediction(uint256 swapId) internal view returns (uint256 raw) {
        bytes memory args = abi.encodePacked(swapId, address(sellToken), address(buyToken), swapper, matcher);
        address predicted = LibClone.predictDeterministicAddress(
            swapContract.feeReceiverImpl(), args, bytes32(swapId), address(swapContract)
        );
        assembly {
            raw := predicted
        }
    }

    function _proposeAndMatch()
        internal
        returns (uint256 swapId, uint48 expiration, openSwapV2.MatchedSwap memory sPost, Vm.Log[] memory logs)
    {
        (swapId, expiration) = _propose();
        vm.recordLogs();
        (,, sPost) = _match(swapId, 2000e18, expiration);
        logs = vm.getRecordedLogs();
    }

    function _matchedLogData(Vm.Log[] memory logs, uint256 swapId) internal view returns (bytes memory) {
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(swapContract) && logs[i].topics.length == 2
                    && logs[i].topics[0] == SWAP_MATCHED_SIG && uint256(logs[i].topics[1]) == swapId
            ) return logs[i].data;
        }
        revert("SwapMatched not found");
    }

    function testFeeRecipient_SoladyPredictionHasDirtyUpperBits() public {
        (uint256 swapId,,,) = _proposeAndMatch();
        uint256 raw = _rawPrediction(swapId);
        assertTrue(raw >> 160 != 0, "Solady output is dirty above bit 160");
        assertEq(address(uint160(raw)), _predictSwapFeeReceiver(swapId, address(sellToken), address(buyToken), swapper, matcher));
    }

    function testFeeRecipient_MatchedHashUsesCleanAddress() public {
        (uint256 swapId,, openSwapV2.MatchedSwap memory sPost, Vm.Log[] memory logs) = _proposeAndMatch();
        uint256 raw = _rawPrediction(swapId);
        assertTrue(raw >> 160 != 0, "precondition: dirty prediction");

        assertEq(sPost.feeRecipient, address(uint160(raw)), "committed receiver = masked prediction");
        bytes memory enc = abi.encode(sPost);
        assertEq(swapContract.swaps(swapId), keccak256(enc), "stored hash = abi.encode(sPost)");

        // Same encoding with the dirty word in the feeRecipient slot must not match.
        assembly {
            mstore(add(add(enc, 0x20), FEE_RECIPIENT_OFFSET), raw)
        }
        assertTrue(swapContract.swaps(swapId) != keccak256(enc), "dirty word would change the hash");

        openSwapV2.MatchedSwap memory fromLog = PackedDecoder.decodeMatchedSwap(_matchedLogData(logs, swapId));
        assertEq(fromLog.feeRecipient, sPost.feeRecipient, "event feeRecipient");
        assertEq(keccak256(abi.encode(fromLog)), swapContract.swaps(swapId), "event preimage hashes to stored hash");
    }

    function testFeeRecipient_OracleGameCommitsCleanAddress() public {
        (uint256 swapId, uint48 expiration, openSwapV2.MatchedSwap memory sPost,) = _proposeAndMatch();
        (IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph) =
            _gameAtMatch(swapId, expiration, 2000e18, sPost);
        assertEq(og.protocolFeeRecipient, sPost.feeRecipient);
        assertEq(oracle.oracleGame(sPost.reportId), keccak256(abi.encode(og, ph)), "oracle hash with clean receiver");
    }

    function testFeeRecipient_ExecuteWithStandardCalldata() public {
        (uint256 swapId, uint48 expiration, openSwapV2.MatchedSwap memory sPost,) = _proposeAndMatch();
        (IOpenOracle2.OracleGame memory og, IOpenOracle2.PreimageHelper memory ph) =
            _gameAtMatch(swapId, expiration, 2000e18, sPost);

        vm.roll(block.number + SETTLEMENT_TIME + 1);
        vm.warp(block.timestamp + (SETTLEMENT_TIME + 1) / 5);
        _settle(sPost.reportId, og, ph);
        _execute(swapId, sPost, og, ph, address(0x7001));

        assertEq(swapContract.swaps(swapId), bytes32(0), "executed");
    }

    function testFeeRecipient_ManySwapIds_AllDirtyAllClean() public {
        _fundDisputer(matcher, address(sellToken));
        _fundDisputer(matcher, address(buyToken));
        deal(address(sellToken), swapper, 1e30);
        for (uint256 i; i < 16; i++) {
            (uint256 swapId,, openSwapV2.MatchedSwap memory sPost,) = _proposeAndMatch();
            uint256 raw = _rawPrediction(swapId);
            assertTrue(raw >> 160 != 0, "dirty prediction");
            assertEq(sPost.feeRecipient, address(uint160(raw)));
            assertEq(swapContract.swaps(swapId), keccak256(abi.encode(sPost)), "clean hash");
            vm.roll(block.number + 1);
        }
    }
}
