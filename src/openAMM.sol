// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IOpenOracle2.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title openAMM
 * @notice Uses openOracle for swap execution price
 * @dev A propAMM / openOracle hybrid. Instead of a constant-product curve, price discovery
 *      is delegated to an openOracle game.
 *
 *      In openOracle, a price report is two limit orders, a buy and a sell, at the same price.
 *      The orders are locked until either the timer runs out or one is taken.
 *      To take one of the limit orders, you replace them with larger ones at a new price.
 *      When the timer runs out without a dispute, the price is settled. Any disputes reset the timer.
 *
 *      The AMM is the proprietary side. The owner provides and controls the swap inventory
 *      (held as internal balances inside openOracle) and sets per-quote fee / executionDelay /
 *      tolerance. Swaps execute at the latest tracked oracle price against that inventory, but only
 *      inside the live window: after executionDelay and before the game becomes settleable.
 *
 *      The external surface mimics UniswapV2Router02 (swapExactTokensForTokens /
 *      swapTokensForExactTokens / getAmountsOut / getAmountsIn), so existing routers and searcher
 *      bots can quote and trade against this venue with no integration changes, while WETH is
 *      wrapped/unwrapped to bridge to the oracle's native-ETH side.
 * @author OpenOracle Team
 * @custom:version 0.1.0
 * @custom:documentation https://docs.openoracle.org/
 */
contract openAMM is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable owner;
    IOpenOracle2 public immutable openOracle;
    bool public paused;

    address public immutable WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant FEE_DENOMINATOR = 10_000_000; // 1000 = 0.01%

    address public immutable token0;
    address public immutable token1;

    mapping (uint256 => QuoteRules) public quoteRules; // reportId => quoteRules
    uint256 public highestReportId;
    uint232 public priceTolerated;  // example: WETH (18 dec) / USDC (6 dec) at $4442.99/ETH → priceTolerated ≈ 1e18 * 1e30 / (4442.99 * 1e6) ≈ 2.25e38.
    uint24 public toleranceRange; // 100000 = 1%, max slippage against priceTolerated

    constructor (address _owner, address _openOracle, address _token1) {
        require(_owner != address(0));
        require(_openOracle != address(0));
        require(_token1 != address(0));
        require(_token1 != WETH);
        owner = _owner;
        openOracle = IOpenOracle2(_openOracle);
        token0 = WETH;
        token1 = _token1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    error NotOwner();
    error InvalidSettlementTime();
    error InvalidMsgValue();
    error Paused();
    error InsufficientOutputAmount();
    error InvalidTo();
    error QuoteInactive();
    error QuoteNotReady();
    error PriceOutOfBounds();
    error InsufficientInputAmount();
    error AmountTooLarge();
    error InvalidFee();
    error InvalidOracleAmounts();
    error NoQuote();
    error Expired();
    error InvalidPath();
    error ExcessiveInputAmount();
    error InvalidTolerance();
    error QuoteExpired();
    error InsufficientInventory();
    error InvalidExecutionDelay();

    struct OracleParams {
        uint128 initialLiquidity; // oracle game initial liquidity in sellToken
        uint128 escalationHalt; // amount of sellToken at which oracle game stops escalating
        uint88 settlerReward; // settler reward in oracle game. settle function executes the swap. //NOHASH
        uint48 settlementTime; // round length of oracle game, in seconds (timestamp mode is forced)
        uint24 disputeDelay; // disputes must wait this long (in seconds) after the last report to fire in the oracle game
        uint16 multiplier; // oracle game multiplier, 110 = 1.1x
    }

    struct QuoteRules {
        uint48 executionDelay;
        uint48 settlementTime; // mirrors the oracle game's settlementTime; quote is dead once settleable
        uint24 fee;
        bool inactive;
    }

    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );

    function quote(OracleParams calldata oracle, IOpenOracle2.TimingBoundaries calldata timing, uint128 amount2, uint48 executionDelay, uint24 fee) onlyOwner external payable {
        if (msg.value != oracle.settlerReward) revert InvalidMsgValue();
        if (msg.sender != owner) revert NotOwner();
        if (oracle.settlementTime > 30) revert InvalidSettlementTime();
        _checkFee(fee);
        // Need a non-empty tradeable window: ready (after executionDelay) before settleable (settlementTime).
        if (executionDelay >= oracle.settlementTime) revert InvalidExecutionDelay();

        uint256 nextReportId = openOracle.nextReportId();
        quoteRules[nextReportId] = QuoteRules({
            inactive: false,
            executionDelay: executionDelay,
            settlementTime: oracle.settlementTime,
            fee: fee
        });
        highestReportId = nextReportId;
        oracleGame(oracle, timing, amount2, oracle.settlerReward);
    }

    function oracleGame(
        OracleParams memory o,
        IOpenOracle2.TimingBoundaries memory timing,
        uint128 amount2,
        uint96 settlerReward
    ) internal {
        IOpenOracle2.OracleGame memory params = IOpenOracle2.OracleGame({
            currentAmount1: o.initialLiquidity,
            currentAmount2: amount2,
            currentReporter: msg.sender,
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: address(0), // ETH sentinel: the AMM holds native ETH (not WETH) inside the oracle
            lastReportOppoTime: 0,
            settlementTime: o.settlementTime,
            escalationHalt: o.escalationHalt,
            protocolFeeRecipient: address(0),
            settlerReward: settlerReward,
            token2: token1,
            numReports: 0,
            disputeDelay: o.disputeDelay,
            feePercentage: 0,
            multiplier: o.multiplier,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: 0,
            flags: 3 // FLAG_TIME_TYPE | FLAG_TRACK_DISPUTES: timeType true and dispute tracking on
        });

        openOracle.report{value: settlerReward}(params, true, true, timing);
    }

    function setExecutionParams(uint232 _priceTolerated, uint24 _toleranceRange) onlyOwner external {
        // Cap tolerance at 1% (FEE_DENOMINATOR / 100; 100000 = 1%) to block absurd/typo bands.
        if (_toleranceRange > FEE_DENOMINATOR / 100) revert InvalidTolerance();
        priceTolerated = _priceTolerated;
        toleranceRange = _toleranceRange;
    }

    function setQuoteParams(uint256 reportId, bool inactive, uint48 executionDelay, uint24 fee) onlyOwner external {
        _checkFee(fee);
        // settlementTime mirrors the oracle game and is fixed at quote() time; preserve it.
        QuoteRules storage r = quoteRules[reportId];
        // Keep a non-empty tradeable window (ready before settleable), same guard as quote().
        if (executionDelay >= r.settlementTime) revert InvalidExecutionDelay();
        r.inactive = inactive;
        r.executionDelay = executionDelay;
        r.fee = fee;
    }

    function pause(bool _paused) onlyOwner external {
        paused = _paused;
    }

    /**
     * @notice UniswapV2-router-style exact-input swap. Bots quote via getAmountsOut, then call this.
     *         Pulls `amountIn` of path[0] from msg.sender and sends path[1] output to `to`.
     * @param path Length-2 path: [token0, token1] or [token1, token0].
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external nonReentrant returns (uint[] memory amounts) {
        if (paused) revert Paused();
        if (block.timestamp > deadline) revert Expired();
        if (path.length != 2) revert InvalidPath();
        if (to == address(0) || to == token0 || to == token1) revert InvalidTo();
        if (amountIn == 0) revert InsufficientInputAmount();
        if (amountIn > type(uint128).max) revert AmountTooLarge();

        bool zeroForOne;
        if (path[0] == token0 && path[1] == token1) {
            zeroForOne = true;
        } else if (path[0] == token1 && path[1] == token0) {
            zeroForOne = false;
        } else {
            revert InvalidPath();
        }

        uint amountOut = _getAmountOut(amountIn, zeroForOne);
        if (amountOut == 0 || amountOut < amountOutMin) revert InsufficientOutputAmount();
        if (amountOut > type(uint128).max) revert AmountTooLarge();

        _executeSwap(zeroForOne, uint128(amountIn), uint128(amountOut), to);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    /**
     * @notice UniswapV2-router-style exact-output swap. Bots quote via getAmountsIn, then call this.
     *         Pulls up to `amountInMax` of path[0] from msg.sender and sends exactly `amountOut` to `to`.
     * @param path Length-2 path: [token0, token1] or [token1, token0].
     */
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external nonReentrant returns (uint[] memory amounts) {
        if (paused) revert Paused();
        if (block.timestamp > deadline) revert Expired();
        if (path.length != 2) revert InvalidPath();
        if (to == address(0) || to == token0 || to == token1) revert InvalidTo();
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (amountOut > type(uint128).max) revert AmountTooLarge();

        bool zeroForOne;
        if (path[0] == token0 && path[1] == token1) {
            zeroForOne = true;
        } else if (path[0] == token1 && path[1] == token0) {
            zeroForOne = false;
        } else {
            revert InvalidPath();
        }

        uint amountIn = _getAmountIn(amountOut, zeroForOne);
        if (amountIn == 0) revert InsufficientInputAmount();
        if (amountIn > amountInMax) revert ExcessiveInputAmount();
        if (amountIn > type(uint128).max) revert AmountTooLarge();

        _executeSwap(zeroForOne, uint128(amountIn), uint128(amountOut), to);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    /**
     * @notice UniswapV2-router-style quote. Returns [amountIn, amountOut] for a length-2 path.
     * @dev Reverts (QuoteNotReady / PriceOutOfBounds / etc.) under the same conditions a swap would,
     *      so an eth_call simulation reflects executability.
     */
    function getAmountsOut(uint amountIn, address[] calldata path)
        external
        view
        returns (uint[] memory amounts)
    {
        if (path.length != 2) revert InvalidPath();
        if (amountIn == 0) revert InsufficientInputAmount();

        amounts = new uint[](2);
        amounts[0] = amountIn;

        if (path[0] == token0 && path[1] == token1) {
            amounts[1] = _getAmountOut(amountIn, true);
        } else if (path[0] == token1 && path[1] == token0) {
            amounts[1] = _getAmountOut(amountIn, false);
        } else {
            revert InvalidPath();
        }
    }

    /**
     * @notice UniswapV2-router-style quote. Returns [amountIn, amountOut] for a length-2 path.
     * @dev Reverts under the same conditions a swap would, so an eth_call simulation reflects executability.
     */
    function getAmountsIn(uint amountOut, address[] calldata path)
        external
        view
        returns (uint[] memory amounts)
    {
        if (path.length != 2) revert InvalidPath();
        if (amountOut == 0) revert InsufficientOutputAmount();

        amounts = new uint[](2);
        amounts[1] = amountOut;

        if (path[0] == token0 && path[1] == token1) {
            amounts[0] = _getAmountIn(amountOut, true);
        } else if (path[0] == token1 && path[1] == token0) {
            amounts[0] = _getAmountIn(amountOut, false);
        } else {
            revert InvalidPath();
        }
    }

    /**
     * @dev Loads the active quote: validates the report exists, is active, not stale, and in-tolerance,
     *      then returns the current oracle amounts + rules. Shared by the swap entrypoints and quotes.
     *      Token-pair identity is enforced by construction: only quote() sets highestReportId, and every
     *      game it creates uses the fixed pair (oracle token1 = address(0) ETH, token2 = this child's
     *      immutable token1). Externally the AMM speaks WETH (token0); _executeSwap wraps/unwraps to bridge
     *      the WETH (ERC20) side to the oracle's native-ETH side.
     */
    function _loadActiveQuote()
        internal
        view
        returns (uint256 currentAmount1, uint256 currentAmount2, QuoteRules memory rules)
    {
        uint256 reportId = highestReportId;
        if (reportId == 0) revert NoQuote();

        rules = quoteRules[reportId];
        if (rules.inactive) revert QuoteInactive();

        uint256 reportNumber = openOracle.reportIdToReportNumber(reportId);
        uint256 reportTimestamp;
        (currentAmount1, currentAmount2, , reportTimestamp) = openOracle.disputeHistory(reportId, reportNumber);

        // disputeHistory can return zeroes if tracking is off or the report doesn't exist.
        if (currentAmount1 == 0 || currentAmount2 == 0) revert InvalidOracleAmounts();
        if (block.timestamp < reportTimestamp + rules.executionDelay) revert QuoteNotReady();
        // Once the oracle game is settleable (no more disputes possible), the quote is dead.
        if (block.timestamp >= reportTimestamp + rules.settlementTime) revert QuoteExpired();

        _checkPriceTolerance(currentAmount1, currentAmount2);
    }

    /**
     * @dev Pulls `amountIn` of the input token from msg.sender and routes `amountOut` of the output
     *      token to `to` through openOracle, then emits Swap. zeroForOne = token0 (WETH) in / token1 out.
     *      The token1->WETH path requires the owner to have called oracleApproval(token1) once at setup.
     */
    function _executeSwap(bool zeroForOne, uint128 amountIn, uint128 amountOut, address to) internal {
        if (zeroForOne) {
            // WETH in, token1 out
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amountIn);
            IWETH(WETH).withdraw(amountIn);
            openOracle.deposit{value: amountIn}(address(0), amountIn, address(this));
            openOracle.pushOrCredit(token1, to, amountOut);
            emit Swap(msg.sender, amountIn, 0, 0, amountOut, to);
        } else {
            // token1 in, WETH out
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amountIn);
            openOracle.deposit(token1, amountIn, address(this));
            openOracle.pushOrCredit(address(0), address(this), amountOut);
            IWETH(WETH).deposit{value: amountOut}();
            IERC20(token0).safeTransfer(to, amountOut);
            emit Swap(msg.sender, 0, amountIn, amountOut, 0, to);
        }
    }

    /**
     * @dev Shared exact-input pricing. Fee is taken on the input (pool-favoring), output rounds down.
     * @param zeroForOne true = token0 (WETH) in / token1 out; false = token1 in / token0 (WETH) out.
     */
    function _getAmountOut(uint amountIn, bool zeroForOne) internal view returns (uint amountOut) {
        (uint256 currentAmount1, uint256 currentAmount2, QuoteRules memory rules) = _loadActiveQuote();

        uint256 amountInAfterFee = amountIn - Math.mulDiv(amountIn, rules.fee, FEE_DENOMINATOR);

        if (zeroForOne) {
            amountOut = Math.mulDiv(amountInAfterFee, currentAmount2, currentAmount1);
        } else {
            amountOut = Math.mulDiv(amountInAfterFee, currentAmount1, currentAmount2);
        }

        _checkInventory(zeroForOne, amountOut);
    }

    /**
     * @dev Shared exact-output pricing. Raw input rounds up, then grosses up for the fee (pool-favoring).
     * @param zeroForOne true = token0 (WETH) in / token1 out; false = token1 in / token0 (WETH) out.
     */
    function _getAmountIn(uint amountOut, bool zeroForOne) internal view returns (uint amountIn) {
        (uint256 currentAmount1, uint256 currentAmount2, QuoteRules memory rules) = _loadActiveQuote();

        uint256 rawIn = zeroForOne
            ? Math.mulDiv(amountOut, currentAmount1, currentAmount2, Math.Rounding.Ceil)
            : Math.mulDiv(amountOut, currentAmount2, currentAmount1, Math.Rounding.Ceil);

        amountIn = _grossUpForFee(rawIn, rules.fee);

        _checkInventory(zeroForOne, amountOut);
    }

    /**
     * @dev Reverts if the AMM's internal balance in openOracle can't cover `amountOut` of the output token,
     *      mirroring pushOrCredit's `bal <= amount` condition so quotes reflect executability.
     *      Output is token1 when zeroForOne, else WETH paid from the AMM's internal ETH (address(0)) balance.
     */
    function _checkInventory(bool zeroForOne, uint256 amountOut) internal view {
        address outputToken = zeroForOne ? token1 : address(0);
        if (openOracle.tokenHolder(address(this), outputToken) <= amountOut) revert InsufficientInventory();
    }

    function _checkFee(uint24 fee) internal pure {
        if (fee >= FEE_DENOMINATOR) revert InvalidFee();
    }

    function _grossUpForFee(uint256 netAmountIn, uint24 fee) internal pure returns (uint256) {
        if (fee == 0) return netAmountIn;
        if (fee >= FEE_DENOMINATOR) revert InvalidFee();

        // exact-output input gross-up:
        // grossIn * (1 - fee) >= netAmountIn
        return Math.mulDiv(netAmountIn, FEE_DENOMINATOR, FEE_DENOMINATOR - uint256(fee), Math.Rounding.Ceil);
    }

    function _checkPriceTolerance(uint256 currentAmount1, uint256 currentAmount2) internal view {
        if (priceTolerated == 0 || toleranceRange == 0) return;

        uint256 price = Math.mulDiv(currentAmount1, 1e30, currentAmount2);

        // Symmetric multiplicative tolerance via reciprocal lower bound.
        uint256 lower = Math.mulDiv(priceTolerated, FEE_DENOMINATOR, FEE_DENOMINATOR + toleranceRange);
        uint256 upper = Math.mulDiv(priceTolerated, FEE_DENOMINATOR + toleranceRange, FEE_DENOMINATOR);

        if (price < lower || price > upper) revert PriceOutOfBounds();
    }

    function oracleApproval(address token) external onlyOwner {                                                                                                                                                                                                                                                                                                          
        IERC20(token).forceApprove(address(openOracle), type(uint256).max);                                                                                                                                                                                                                                                                                                                          
    }

    function oracleInternalTransfer(address token, uint128 amount) external onlyOwner {                                                                                                                                                                                                                                                                                                          
        openOracle.internalTransferFrom(address(this), msg.sender, token, amount);                                                                                                                                                                                                                                                                                                                        
    }

    receive() external payable {}

}
