// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Min, OpenPuntHelperBase} from "./OpenPuntHelperBase.t.sol";
import {OpenPuntHelper} from "../../src/levered-swaps/OpenPuntHelper.sol";

/**
 * @notice Opaque Universal Router forwarding and the funding invariants that bound it.
 *
 * @dev The helper intentionally does not inspect command bytes or route inputs. Successful plans
 *      must deliver every required asset to the helper, cannot spend more than the transferred
 *      route budget without an approval, and must arrange their own residue handling. Router
 *      syntax and deadline failures therefore surface from the router itself.
 */
contract RoutingAndValidationTest is OpenPuntHelperBase {
    bytes4 internal constant TRANSACTION_DEADLINE_PASSED = bytes4(keccak256("TransactionDeadlinePassed()"));

    function setUp() public override {
        super.setUp();
        _approveMatcherLegs(designatedMatcher, address(tokenA), address(tokenB));
    }

    function test_failedSubplanFallsThroughToAWorkingRoute() public {
        Proposal memory p = _propose();

        (bytes memory badCommands, bytes[] memory badInputs) =
            _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, 1);
        bytes[] memory subplanInput = new bytes[](1);
        subplanInput[0] = abi.encode(badCommands, badInputs);

        (bytes memory fallbackCommands, bytes[] memory fallbackInputs) =
            _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, 5000e18);
        (fallbackCommands, fallbackInputs) = _withSweep(fallbackCommands, fallbackInputs, address(tokenC));

        (bytes memory commands, bytes[] memory inputs) = _join(
            abi.encodePacked(CMD_EXECUTE_SUB_PLAN | ROUTER_FLAG_ALLOW_REVERT),
            subplanInput,
            fallbackCommands,
            fallbackInputs
        );

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 5000e18, commands, inputs),
            router
        );

        assertTrue(punt.swaps(p.swapId) != bytes32(0), "fallback route completed the match");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
    }

    /// @dev The helper does not impose its own recipient policy. A bot may return unused input
    ///      directly to itself instead of routing it through the helper's refund path.
    function test_callerDirectedInputSweepSucceeds() public {
        Proposal memory p = _propose();
        uint256 maxIn = 5000e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);

        bytes[] memory sweep = new bytes[](1);
        sweep[0] = abi.encode(address(tokenC), funder, uint256(0));
        (bytes memory commands, bytes[] memory inputs) = _join(c, i, abi.encodePacked(CMD_SWEEP), sweep);

        uint256 before = tokenC.balanceOf(funder);
        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, commands, inputs),
            router
        );

        uint256 spent = before - tokenC.balanceOf(funder);
        assertGt(spent, 0, "the route input was not used");
        assertLt(spent, maxIn, "unused input was not returned directly to the caller");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
        _assertNoRouterOrPermit2Approvals();
    }

    /// @dev Omitting residue recovery is a caller mistake, not a helper validation failure. The
    ///      match succeeds, while the exact-output remainder remains in the router.
    function test_omittingTheInputSweepLeavesResidueInTheRouter() public {
        Proposal memory p = _propose();
        uint256 maxIn = 5000e18;
        (bytes memory commands, bytes[] memory inputs) =
            _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, maxIn);

        uint256 routerBefore = tokenC.balanceOf(router);
        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, commands, inputs),
            router
        );

        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the match should not depend on a sweep");
        assertGt(tokenC.balanceOf(router), routerBefore, "the caller's residue should remain in the router");
        assertEq(tokenC.balanceOf(address(helper)), 0, "helper retained route input");
    }

    /// @dev Deadline interpretation belongs to the router; the helper forwards it verbatim.
    function test_anExpiredDeadlineIsRejectedByTheRouter() public {
        Proposal memory p = _propose();
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, 5000e18);
        (c, i) = _withSweep(c, i, address(tokenC));

        OpenPuntHelper.RouteFunding memory route =
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 5000e18, c, i);
        route.deadline = block.timestamp - 1;

        vm.prank(funder);
        vm.expectRevert(TRANSACTION_DEADLINE_PASSED);
        helper.matchWithRoute(p.swapId, AMOUNT2, p.swap, p.preimage, _noTiming(), designatedMatcher, route, router);
    }

    function test_v4ExactOutputRouteFundsALeg() public {
        Proposal memory p = _propose();
        uint256 maxIn = 5000e18;

        (bytes memory c, bytes[] memory i) =
            _v4ExactOutSingle(address(tokenC), address(tokenA), INITIAL_LIQUIDITY, uint128(maxIn));
        (bytes memory commands, bytes[] memory inputs) = _withSweep(c, i, address(tokenC));

        uint256 a0 = tokenA.balanceOf(funder);
        uint256 tc0 = tokenC.balanceOf(funder);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, commands, inputs),
            router
        );

        assertEq(tokenA.balanceOf(funder), a0, "the route should buy exactly the requirement");
        assertLt(tc0 - tokenC.balanceOf(funder), maxIn, "unused input was not swept back");
        _assertNoRouterOrPermit2Approvals();
    }

    /// @dev The router is selected per call rather than stored by the helper. A minimal contract
    ///      with the documented execute(bytes,bytes[],uint256) interface can therefore receive the
    ///      exact route budget and provide the missing asset. Over-delivery is refunded to the
    ///      caller after OpenPunt consumes the required amount.
    function test_callerSelectedCompatibleRouterReceivesExactBudgetAndRefundsOverdelivery() public {
        Proposal memory p = _propose();
        uint256 maxIn = 5e18;
        uint256 excessOutput = 7e18;
        RecordingCompatibleRouter chosen =
            new RecordingCompatibleRouter(address(tokenC), address(tokenA), INITIAL_LIQUIDITY + excessOutput);
        tokenA.mint(address(chosen), INITIAL_LIQUIDITY + excessOutput);

        bytes[] memory opaqueInputs = new bytes[](1);
        opaqueInputs[0] = hex"deadbeef";
        uint256 funderA = tokenA.balanceOf(funder);

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, hex"1234", opaqueInputs),
            address(chosen)
        );

        assertEq(chosen.caller(), address(helper), "the selected router was not called by the helper");
        assertEq(chosen.receivedInput(), maxIn, "the selected router did not receive exactly maxSwapInput");
        assertEq(chosen.commandsHash(), keccak256(hex"1234"), "router commands changed in transit");
        assertEq(chosen.inputsHash(), keccak256(abi.encode(opaqueInputs)), "router inputs changed in transit");
        assertEq(chosen.deadline(), block.timestamp + 1, "router deadline changed in transit");
        assertEq(tokenA.balanceOf(funder) - funderA, excessOutput, "routed over-delivery was not refunded");
        assertEq(tokenC.allowance(address(helper), address(chosen)), 0, "helper approved the selected router");
        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the selected-router match did not complete");
    }

    /// @dev Selecting a contract with the documented ABI but no useful output fails the helper's
    ///      final funding assertion. The pre-transfer and the router's own state change both unwind.
    function test_unproductiveCallerSelectedRouterRevertsAtomically() public {
        Proposal memory p = _propose();
        uint256 maxIn = 5e18;
        RecordingNoOutputRouter chosen = new RecordingNoOutputRouter(address(tokenC));
        uint256 funderInput = tokenC.balanceOf(funder);
        bytes32 proposalHash = punt.swaps(p.swapId);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), maxIn, hex"01", new bytes[](0)),
            address(chosen)
        );

        assertEq(tokenC.balanceOf(funder), funderInput, "failed route consumed caller input");
        assertEq(tokenC.balanceOf(address(chosen)), 0, "failed route left input at selected router");
        assertEq(chosen.receivedInput(), 0, "failed route retained router state");
        assertEq(punt.swaps(p.swapId), proposalHash, "failed route changed the proposal");
    }

    function test_underDeliveryOfOneAssetRevertsEverything() public {
        Proposal memory p = _propose();
        (bytes memory c, bytes[] memory i) = _v2ExactIn(address(tokenC), address(tokenA), 1e12, 1);
        (c, i) = _withSweep(c, i, address(tokenC));

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InsufficientRouterOutput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 1e12, c, i),
            router
        );
    }

    /// @dev A payerIsUser plan cannot spend from the helper because the helper grants neither the
    ///      ERC20 approval to Permit2 nor a Permit2 allowance to the router.
    function test_payerIsUserPlansCannotFundTheHelper() public {
        Proposal memory p = _propose();

        address[] memory path = new address[](2);
        path[0] = address(tokenC);
        path[1] = address(tokenA);

        bytes memory commands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(helper), uint256(5000e18), uint256(1), path, true, _noHopPrices());

        vm.prank(funder);
        vm.expectRevert(bytes(""));
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 5000e18, commands, inputs),
            router
        );
    }

    function test_routeBudgetCannotExceedTheSuppliedSurplus() public {
        Proposal memory p = _propose();
        uint256 surplus = 4000e18;
        (bytes memory c, bytes[] memory i) = _v2ExactOut(address(tokenB), address(tokenA), INITIAL_LIQUIDITY, surplus);

        vm.prank(funder);
        vm.expectRevert(OpenPuntHelper.InvalidMaximumSwapInput.selector);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(0, AMOUNT2 + surplus, INITIAL_MARGIN_MATCHER, false, address(tokenB), surplus + 1, c, i),
            router
        );
    }

    /// @dev Opaque route calldata and even a zero router remain inert when direct supplies already
    ///      cover every obligation; `_hasShortfall` skips router validation and execution entirely.
    function test_routerChoiceAndOpaqueCalldataAreIgnoredWhenThereIsNoShortfall() public {
        Proposal memory p = _propose();
        bytes[] memory junk = new bytes[](1);
        junk[0] = hex"deadbeef";

        vm.prank(funder);
        helper.matchWithRoute(
            p.swapId,
            AMOUNT2,
            p.swap,
            p.preimage,
            _noTiming(),
            designatedMatcher,
            _routeFunding(INITIAL_LIQUIDITY, AMOUNT2, INITIAL_MARGIN_MATCHER, false, address(tokenC), 0, hex"ff", junk),
            address(0)
        );

        assertTrue(punt.swaps(p.swapId) != bytes32(0), "the fully funded match should complete");
    }

    function _assertNoRouterOrPermit2Approvals() internal view {
        address[4] memory tokens = [address(tokenA), address(tokenB), address(collat), address(tokenC)];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20Min(tokens[i]).allowance(address(helper), router), 0, "helper approved the router");
            assertEq(IERC20Min(tokens[i]).allowance(address(helper), PERMIT2), 0, "helper approved Permit2");
        }
    }
}

contract RecordingCompatibleRouter {
    IERC20Min internal immutable inputToken;
    IERC20Min internal immutable outputToken;
    uint256 internal immutable outputAmount;

    address public caller;
    uint256 public receivedInput;
    bytes32 public commandsHash;
    bytes32 public inputsHash;
    uint256 public deadline;

    constructor(address inputToken_, address outputToken_, uint256 outputAmount_) {
        inputToken = IERC20Min(inputToken_);
        outputToken = IERC20Min(outputToken_);
        outputAmount = outputAmount_;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline_) external payable {
        caller = msg.sender;
        receivedInput = inputToken.balanceOf(address(this));
        commandsHash = keccak256(commands);
        inputsHash = keccak256(abi.encode(inputs));
        deadline = deadline_;
        require(outputToken.transfer(msg.sender, outputAmount), "output transfer");
    }
}

contract RecordingNoOutputRouter {
    IERC20Min internal immutable inputToken;
    uint256 public receivedInput;

    constructor(address inputToken_) {
        inputToken = IERC20Min(inputToken_);
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external {
        receivedInput = inputToken.balanceOf(address(this));
    }
}
