// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {OpenOracle} from "../../src/OpenOracleSlim.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {ArmableReentrantToken} from "../utils/ArmableReentrantToken.sol";
import {OracleArmedReentrancyHandler} from "./OracleArmedReentrancyHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fuzzer-driven completion of item 1: the armable reentrant token is rotated through the
///         oracle's action set, and on every operation that moves it a fuzzer-chosen reentrant
///         payload fires at a fuzzer-chosen trigger point. The referee is SOLVENCY (real balance >=
///         Σ withdrawable), the reentrancy-robust form of conservation that needs no off-chain
///         report mirror — so a reentrant settle/dispute mutating state behind the handler cannot
///         false-positive, while any value-printing reentrancy trips it.
contract OracleArmedReentrancyInvariantsTest is StdInvariant, Test {
    OpenOracle internal oracle;
    ArmableReentrantToken internal armToken;
    MockERC20 internal vanillaA;
    OracleArmedReentrancyHandler internal handler;

    address internal constant PFR = address(0xFEE);
    address[4] internal actorAddrs = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    address[] internal holders; // every address whose internal balance must stay backed

    function setUp() public {
        oracle = new OpenOracle();
        armToken = new ArmableReentrantToken();
        vanillaA = new MockERC20("VanillaA", "VAA");
        handler = new OracleArmedReentrancyHandler(oracle, armToken);

        handler.addToken(address(0)); // ETH
        handler.addToken(address(vanillaA));
        handler.addToken(address(armToken));

        for (uint256 i = 0; i < actorAddrs.length; i++) {
            address a = actorAddrs[i];
            handler.addActor(a);
            vm.deal(a, 1000 ether);
            vanillaA.transfer(a, 1_000_000e18 / 8);
            armToken.transfer(a, 1e30 / 8);
            vm.prank(a);
            vanillaA.approve(address(oracle), type(uint256).max);
            vm.prank(a);
            armToken.approve(address(oracle), type(uint256).max);
        }

        // Holder set the solvency invariant sums over.
        holders.push(address(handler));
        holders.push(address(armToken));
        holders.push(PFR);
        for (uint256 i = 0; i < actorAddrs.length; i++) holders.push(actorAddrs[i]);

        targetContract(address(handler));
        // actArmedReport / actArmedDeposit force the armToken + a non-zero reentry kind; listed
        // twice each to bias the campaign toward actually firing reentries.
        bytes4[] memory sels = new bytes4[](12);
        sels[0] = OracleArmedReentrancyHandler.actArmedReport.selector;
        sels[1] = OracleArmedReentrancyHandler.actArmedReport.selector;
        sels[2] = OracleArmedReentrancyHandler.actArmedDeposit.selector;
        sels[3] = OracleArmedReentrancyHandler.actArmedDeposit.selector;
        sels[4] = OracleArmedReentrancyHandler.actReport.selector;
        sels[5] = OracleArmedReentrancyHandler.actDispute.selector;
        sels[6] = OracleArmedReentrancyHandler.actSettle.selector;
        sels[7] = OracleArmedReentrancyHandler.actDeposit.selector;
        sels[8] = OracleArmedReentrancyHandler.actWithdraw.selector;
        sels[9] = OracleArmedReentrancyHandler.actPushOrCredit.selector;
        sels[10] = OracleArmedReentrancyHandler.actInternalTransfer.selector;
        sels[11] = OracleArmedReentrancyHandler.actWarp.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function _withdrawable(address holder, address token) internal view returns (uint256) {
        uint256 bal = oracle.tokenHolder(holder, token);
        return bal == 0 ? 0 : bal - 1;
    }

    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 300
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_solvencyUnderArmedReentrancy() public view {
        address[3] memory toks = [address(0), address(vanillaA), address(armToken)];
        for (uint256 t = 0; t < toks.length; t++) {
            uint256 withdrawable;
            for (uint256 h = 0; h < holders.length; h++) {
                withdrawable += _withdrawable(holders[h], toks[t]);
            }
            uint256 real = toks[t] == address(0) ? address(oracle).balance : IERC20(toks[t]).balanceOf(address(oracle));
            assertGe(real, withdrawable, "oracle insolvent: withdrawable exceeds real backing");
        }
    }

    /// @dev Non-vacuity: the campaign must have actually executed armed reentries, else "solvent"
    ///      proves nothing about reentrancy. Checked once at the end of the run.
    function afterInvariant() public view {
        assertGt(handler.reentriesFired(), 0, "no armed reentry ever fired - campaign vacuous");
    }

    /// @dev Wiring check: a single forced armed report must fire exactly one reentry, proving the
    ///      hook path is reachable (the fuzz count then reflects distribution, not a dead path).
    function test_ArmedReportFiresReentry() public {
        assertEq(handler.reentriesFired(), 0, "clean start");
        handler.actArmedReport(0, 1, 1e18, 2000e18, 2); // armToken=t1, other=vanillaA, kind=3
        assertEq(handler.reentriesFired(), 1, "forced armed report fired exactly one reentry");
    }
}
