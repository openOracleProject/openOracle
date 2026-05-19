// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BaseGGTest.sol";
import {Errors} from "../../src/libraries/Errors.sol";

// Locks down the "calldata is the state" model:
// every PreimageHelper field, and a representative selection of OracleGame
// fields, must commit to the stored stateHash. Tampering ANY of them must
// produce InvalidStateHash.
contract OpenOracleGGTamperingMatrixTest is BaseGGTest {
    function setUp() public override {
        BaseGGTest.setUp();
    }

    function _setup() internal returns (ReportContext memory ctx) {
        vm.prank(alice);
        ctx = _report(_defaultParams(), 1e18, 2000e18, alice, false, false);
        vm.warp(block.timestamp + 6);
    }

    function _expectDisputeRevert(
        ReportContext memory ctx,
        Slim.OracleGame memory game,
        Slim.PreimageHelper memory helper
    ) internal {
        vm.prank(bob);
        vm.expectRevert(Errors.InvalidStateHash.selector);
        oracle.dispute(
            ctx.reportId, address(token1), 1.1e18, 2100e18, bob, false, false, game, helper, _emptyTiming()
        );
    }

    // -------------------------------------------------------------------------
    // PreimageHelper field tampering
    // -------------------------------------------------------------------------

    function testTamper_HelperReportId() public {
        ReportContext memory ctx = _setup();
        Slim.PreimageHelper memory helper = ctx.helper;
        helper.reportId = ctx.reportId + 1;
        _expectDisputeRevert(ctx, ctx.game, helper);
    }

    function testTamper_HelperCreator() public {
        ReportContext memory ctx = _setup();
        Slim.PreimageHelper memory helper = ctx.helper;
        helper.creator = bob;
        _expectDisputeRevert(ctx, ctx.game, helper);
    }

    function testTamper_HelperBlockTimestamp() public {
        ReportContext memory ctx = _setup();
        Slim.PreimageHelper memory helper = ctx.helper;
        helper.blockTimestamp = ctx.helper.blockTimestamp + 1;
        _expectDisputeRevert(ctx, ctx.game, helper);
    }

    function testTamper_HelperBlockNumber() public {
        ReportContext memory ctx = _setup();
        Slim.PreimageHelper memory helper = ctx.helper;
        helper.blockNumber = ctx.helper.blockNumber + 1;
        _expectDisputeRevert(ctx, ctx.game, helper);
    }

    // -------------------------------------------------------------------------
    // OracleGame field tampering (representative subset)
    // -------------------------------------------------------------------------

    function testTamper_GameToken1() public {
        ReportContext memory ctx = _setup();
        // Deep-copy via abi encode/decode to avoid memory aliasing.
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.token1 = address(0xDEADBEEF);
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameToken2() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.token2 = address(0xDEADBEEF);
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameCurrentAmount1() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.currentAmount1 = 999e18;
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameCurrentAmount2() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.currentAmount2 = 1e18;
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameSettlementTime() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.settlementTime = uint48(99999);
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameMultiplier() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.multiplier = uint16(200);
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameFeePercentage() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.feePercentage = uint24(1);
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameProtocolFeeRecipient() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.protocolFeeRecipient = bob;
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }

    function testTamper_GameFlags() public {
        ReportContext memory ctx = _setup();
        Slim.OracleGame memory tampered = abi.decode(abi.encode(ctx.game), (Slim.OracleGame));
        tampered.flags = ctx.game.flags ^ FLAG_TIME_TYPE; // flip bit
        _expectDisputeRevert(ctx, tampered, ctx.helper);
    }
}
