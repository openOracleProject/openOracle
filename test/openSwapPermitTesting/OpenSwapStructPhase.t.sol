// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Errors} from "../../src/libraries/Errors.sol";

import "../utils/SlimTestBase.sol";

/// @notice Hash-shape phase separation:
///         pre-match  → swaps[id] == keccak(ProposedSwap, MatcherPreimage)
///         post-match → swaps[id] == keccak(MatchedSwap)
///         The two struct types deliberately do not implicitly convert in Solidity,
///         so a function that takes MatchedSwap can never be called with a ProposedSwap
///         (and vice versa) — phase mistakes are caught at compile time, hash mismatches
///         catch any runtime forgery attempts.
contract OpenSwapStructPhaseTest is SlimTestBase {
    function setUp() public {
        _setUpAll();
    }

    function testPhase_PreMatchHashShape() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        bytes32 expected = keccak256(abi.encode(s, m));
        assertEq(swapContract.swaps(swapId), expected, "pre-match hash = keccak(ProposedSwap, MatcherPreimage)");
    }

    function testPhase_PostMatchHashShape() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (, , openSwapV2.MatchedSwap memory sPost) = _match(swapId, 2000e18, expiration);

        bytes32 expected = keccak256(abi.encode(sPost));
        assertEq(swapContract.swaps(swapId), expected, "post-match hash = keccak(MatchedSwap)");
    }

    /// @notice After match, the old ProposedSwap+Preimage hash no longer matches storage.
    ///         Calling cancelSwap (which takes ProposedSwap+Preimage) reverts WrongHash.
    function testPhase_CancelRevertsAfterMatch() public {
        (uint256 swapId, uint48 expiration) = _propose();
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(swapId, expiration);

        _match(swapId, 2000e18, expiration);

        vm.prank(swapper);
        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.cancelSwap(swapId, s, m);
    }

    /// @notice bailOut takes MatchedSwap and hashes keccak(MatchedSwap). Pre-match storage
    ///         holds keccak(ProposedSwap, MatcherPreimage), so even a zero-init MatchedSwap mismatches.
    function testPhase_BailOutRevertsBeforeMatch() public {
        (uint256 swapId,) = _propose();
        openSwapV2.MatchedSwap memory empty;

        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.bailOut(swapId, empty);
    }

    /// @notice execute takes MatchedSwap — pre-match storage holds the ProposedSwap-shaped hash, so reverts.
    function testPhase_ExecuteRevertsBeforeMatch() public {
        (uint256 swapId,) = _propose();
        openSwapV2.MatchedSwap memory empty;
        IOpenOracle2.OracleGame memory og;
        IOpenOracle2.PreimageHelper memory ph;

        vm.expectRevert(Errors.WrongHash.selector);
        swapContract.execute(swapId, empty, og, ph, false);
    }
}
