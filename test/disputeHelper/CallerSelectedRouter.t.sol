// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DisputeHelperBase} from "./DisputeHelperBase.t.sol";
import {OracleDisputeHelper} from "../../src/oracle-periphery/OracleDisputeHelper.sol";

/**
 * @notice Coverage for the caller-selected router boundary. The helper deliberately treats the
 *         router calldata as opaque; these tests pin only the properties the helper promises:
 *         exact route-input transfer, argument passthrough, output accounting, refunds and
 *         transaction-wide rollback.
 */
contract CallerSelectedRouterTest is DisputeHelperBase {
    uint128 internal constant NEW_AMOUNT_1 = 1.1e18;
    uint256 internal constant REQUIRED_1 = 2.1004e18;

    RecordingRouter internal selectedRouter;

    function setUp() public override {
        super.setUp();
        selectedRouter = new RecordingRouter();
        tokenA.mint(address(selectedRouter), 1_000e18);
        tokenB.mint(address(selectedRouter), 1_000e18);
    }

    function test_callerSelectedRouterReceivesExactInputAndOpaqueArguments() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        selectedRouter.configure(address(tokenC), address(tokenA), REQUIRED_1, address(0), 0, false);

        bytes memory commands = hex"deadbeef";
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = hex"010203";
        inputs[1] = abi.encode(address(tokenC), uint256(77));
        uint256 deadline = block.timestamp + 73;
        uint256 maxIn = 5e18;

        vm.prank(disputer);
        helper.disputeWithRoute(
            _dd(ctx, NEW_AMOUNT_1, 900e18),
            ctx.game,
            ctx.helper,
            _emptyTiming(),
            0,
            0,
            false,
            address(tokenC),
            maxIn,
            commands,
            inputs,
            deadline,
            address(selectedRouter)
        );

        assertEq(selectedRouter.callCount(), 1, "selected router not called exactly once");
        assertEq(selectedRouter.lastCaller(), address(helper), "router caller");
        assertEq(selectedRouter.lastValue(), 0, "unexpected native value");
        assertEq(selectedRouter.inputBalanceSeen(), maxIn, "route input was not transferred exactly");
        assertEq(selectedRouter.commandsHash(), keccak256(commands), "commands changed");
        assertEq(selectedRouter.inputsHash(), keccak256(abi.encode(inputs)), "inputs changed");
        assertEq(selectedRouter.lastDeadline(), deadline, "deadline changed");
        assertEq(tokenC.balanceOf(address(selectedRouter)), maxIn, "router input balance");
        assertEq(tokenC.allowance(address(helper), address(selectedRouter)), 0, "router allowance granted");
        assertEq(tokenC.allowance(address(helper), PERMIT2), 0, "Permit2 allowance granted");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_selectedRouterMayFundBothLegs() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        selectedRouter.configure(address(tokenC), address(tokenA), REQUIRED_1, address(tokenB), 50e18, false);

        bytes[] memory inputs = new bytes[](0);
        _callDisputeWithRouter(
            ctx, NEW_AMOUNT_1, 1050e18, 0, 0, false, address(tokenC), 5e18, hex"77", inputs, 0, address(selectedRouter)
        );

        assertEq(selectedRouter.callCount(), 1, "selected router not called");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_routerOverdeliveryIsRefundedToTheDisputer() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        uint256 excess = 7e18;
        selectedRouter.configure(address(tokenC), address(tokenA), REQUIRED_1 + excess, address(0), 0, false);

        uint256 before = tokenA.balanceOf(disputer);
        bytes[] memory inputs = new bytes[](0);
        _callDisputeWithRouter(
            ctx, NEW_AMOUNT_1, 900e18, 0, 0, false, address(tokenC), 5e18, hex"01", inputs, 0, address(selectedRouter)
        );

        assertEq(tokenA.balanceOf(disputer), before + excess, "overdelivery was not refunded");
        _assertHelperHoldsNothing(_tokens(address(tokenA), address(tokenB), address(tokenC)));
    }

    function test_selectedRouterFailureRollsBackInputAndOracleState() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        selectedRouter.configure(address(tokenC), address(tokenA), REQUIRED_1, address(0), 0, true);

        uint256 disputerInput = tokenC.balanceOf(disputer);
        uint256 routerInput = tokenC.balanceOf(address(selectedRouter));
        bytes32 stateHash = oracle.oracleGame(ctx.reportId);
        bytes[] memory inputs = new bytes[](0);

        vm.expectRevert(RecordingRouter.RouteFailed.selector);
        _callDisputeWithRouter(
            ctx, NEW_AMOUNT_1, 900e18, 0, 0, false, address(tokenC), 5e18, hex"02", inputs, 0, address(selectedRouter)
        );

        assertEq(selectedRouter.callCount(), 0, "router state survived revert");
        assertEq(tokenC.balanceOf(disputer), disputerInput, "disputer route input moved");
        assertEq(tokenC.balanceOf(address(selectedRouter)), routerInput, "router retained input");
        assertEq(oracle.oracleGame(ctx.reportId), stateHash, "oracle state changed");
    }

    function test_routerUnderDeliveryRollsBackTheWholeCall() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        selectedRouter.configure(address(tokenC), address(tokenA), REQUIRED_1 - 1, address(0), 0, false);

        uint256 disputerInput = tokenC.balanceOf(disputer);
        uint256 routerInput = tokenC.balanceOf(address(selectedRouter));
        uint256 routerOutput = tokenA.balanceOf(address(selectedRouter));
        bytes32 stateHash = oracle.oracleGame(ctx.reportId);
        bytes[] memory inputs = new bytes[](0);

        vm.expectRevert(OracleDisputeHelper.InsufficientRouterOutput.selector);
        _callDisputeWithRouter(
            ctx, NEW_AMOUNT_1, 900e18, 0, 0, false, address(tokenC), 5e18, hex"03", inputs, 0, address(selectedRouter)
        );

        assertEq(tokenC.balanceOf(disputer), disputerInput, "disputer route input moved");
        assertEq(tokenC.balanceOf(address(selectedRouter)), routerInput, "router retained input");
        assertEq(tokenA.balanceOf(address(selectedRouter)), routerOutput, "router output moved");
        assertEq(oracle.oracleGame(ctx.reportId), stateHash, "oracle state changed");
    }

    function test_zeroRouterIsIgnoredWhenNoRouteIsNeeded() public {
        Game memory ctx = _newGame(address(tokenA), address(tokenB));
        bytes[] memory junk = new bytes[](1);
        junk[0] = hex"0badc0de";

        _callDisputeWithRouter(
            ctx, NEW_AMOUNT_1, 900e18, REQUIRED_1, 0, false, address(tokenA), 0, hex"ffffffff", junk, 0, address(0)
        );

        assertTrue(
            oracle.oracleGame(ctx.reportId) != keccak256(abi.encode(ctx.game, ctx.helper)), "dispute did not land"
        );
    }
}

contract RecordingRouter {
    error RouteFailed();

    address public inputToken;
    address public outputToken1;
    uint256 public outputAmount1;
    address public outputToken2;
    uint256 public outputAmount2;
    bool public shouldRevert;

    uint256 public callCount;
    address public lastCaller;
    uint256 public lastValue;
    uint256 public inputBalanceSeen;
    bytes32 public commandsHash;
    bytes32 public inputsHash;
    uint256 public lastDeadline;

    function configure(address routeToken, address token1, uint256 amount1, address token2, uint256 amount2, bool fail)
        external
    {
        inputToken = routeToken;
        outputToken1 = token1;
        outputAmount1 = amount1;
        outputToken2 = token2;
        outputAmount2 = amount2;
        shouldRevert = fail;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        if (shouldRevert) revert RouteFailed();

        ++callCount;
        lastCaller = msg.sender;
        lastValue = msg.value;
        inputBalanceSeen = IERC20View(inputToken).balanceOf(address(this));
        commandsHash = keccak256(commands);
        inputsHash = keccak256(abi.encode(inputs));
        lastDeadline = deadline;

        if (outputAmount1 != 0) IERC20View(outputToken1).transfer(msg.sender, outputAmount1);
        if (outputAmount2 != 0) IERC20View(outputToken2).transfer(msg.sender, outputAmount2);
    }
}

interface IERC20View {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
