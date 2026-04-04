// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwapV2.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

// ERC20 with permit support
contract MockERC20Permit is ERC20, ERC20Permit {
    constructor(string memory name, string memory symbol)
        ERC20(name, symbol)
        ERC20Permit(name)
    {
        _mint(msg.sender, 1_000_000e18);
    }
}

// Plain ERC20 without permit (for negative tests)
contract MockERC20NoPermit is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract OpenSwapPermitFlowTest is Test {
    OpenOracle internal oracle;
    openSwapV2Permit internal swapContract;
    MockERC20Permit internal sellToken;
    MockERC20Permit internal buyToken;

    address constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal swapperPk = 0xA11CE;
    address internal swapper;
    address internal matcher = address(0x2);

    uint96 constant SETTLER_REWARD = 0.001 ether;
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant PROTOCOL_FEE = 0;
    uint24 constant MAX_GAME_TIME = 7200;

    uint128 constant SELL_AMT = 10e18;
    uint128 constant MIN_OUT = 19000e18;
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant GAS_COMPENSATION = 0.001 ether;

    function setUp() public {
        vm.etch(WETH, address(new MockERC20NoPermit("WETH", "WETH")).code);

        swapper = vm.addr(swapperPk);

        oracle = new OpenOracle();
        swapContract = new openSwapV2Permit(address(oracle));

        sellToken = new MockERC20Permit("SellToken", "SELL");
        buyToken = new MockERC20Permit("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(matcher, 100e18);
        buyToken.transfer(matcher, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);

        // Matcher approves normally (not testing permit for matcher)
        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        // NOTE: swapper does NOT approve — permit should handle it
    }

    function _oracleParams() internal pure returns (openSwapV2Permit.OracleParams memory) {
        return openSwapV2Permit.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            maxGameTime: MAX_GAME_TIME,
            blocksPerSecond: uint16(500),
            disputeDelay: DISPUTE_DELAY,
            protocolFee: PROTOCOL_FEE,
            multiplier: uint16(110),
            timeType: true
        });
    }

    function _slippageParams() internal pure returns (openSwapV2Permit.SlippageParams memory) {
        return openSwapV2Permit.SlippageParams({ priceTolerated: 5e14, toleranceRange: 1e7 - 1 });
    }

    function _fulfillFeeParams() internal pure returns (openSwapV2Permit.FulfillFeeParams memory) {
        return openSwapV2Permit.FulfillFeeParams({
            startFulfillFeeIncrease: 0, maxFee: 10000, startingFee: 10000,
            roundLength: 60, growthRate: 15000, maxRounds: 10
        });
    }

    function _emptyPermit() internal pure returns (openSwapV2Permit.PermitParams memory) {
        return openSwapV2Permit.PermitParams(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _signPermit(uint256 ownerPk, address token, address spender, uint256 value, uint256 deadline)
        internal view returns (openSwapV2Permit.PermitParams memory)
    {
        address owner = vm.addr(ownerPk);
        uint256 nonce = ERC20Permit(token).nonces(owner);

        bytes32 domainSeparator = ERC20Permit(token).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            owner, spender, value, nonce, deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        return openSwapV2Permit.PermitParams(value, deadline, v, r, s);
    }

    // ============ 1. Happy path: valid permit, no prior allowance, successful swap ============

    function testPermit_HappyPath_NoPriorAllowance() public {
        // Swapper has NO allowance
        assertEq(sellToken.allowance(swapper, address(swapContract)), 0, "No prior allowance");

        // Sign permit
        openSwapV2Permit.PermitParams memory permit = _signPermit(
            swapperPk, address(sellToken), address(swapContract), SELL_AMT, block.timestamp + 1 hours
        );

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );
        vm.stopPrank();

        // Swap succeeded — sellToken was pulled via permit
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "SellToken transferred via permit");
        assertTrue(swapContract.getSwap(swapId).active, "Swap should be active");

        // Allowance should be set (or consumed) after permit
        // permit set allowance to SELL_AMT, transferFrom consumed it → 0
        assertEq(sellToken.allowance(swapper, address(swapContract)), 0, "Allowance consumed after transfer");
    }

    // ============ 2. Fallback: permit omitted (zeroed), normal pre-approval works ============

    function testPermit_Omitted_FallsBackToAllowance() public {
        // Swapper pre-approves normally
        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(),
            _emptyPermit() // deadline=0 → permit skipped
        );
        vm.stopPrank();

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Transfer via pre-approval");
        assertTrue(swapContract.getSwap(swapId).active, "Swap active");
    }

    // ============ 3. Invalid permit but existing allowance → silent catch, transferFrom succeeds ============

    function testPermit_InvalidSig_FallsBackToExistingAllowance() public {
        // Swapper pre-approves
        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        // Craft a bad permit (wrong signer)
        uint256 wrongPk = 0xDEAD;
        openSwapV2Permit.PermitParams memory badPermit = _signPermit(
            wrongPk, address(sellToken), address(swapContract), SELL_AMT, block.timestamp + 1 hours
        );

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        // Should succeed — permit fails silently (catch {}), transferFrom uses existing allowance
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), badPermit
        );
        vm.stopPrank();

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Transfer via fallback allowance");
        assertTrue(swapContract.getSwap(swapId).active, "Swap active despite bad permit");
    }

    // ============ 4. Invalid permit AND no allowance → transferFrom reverts ============

    function testPermit_InvalidSigAndNoAllowance_Reverts() public {
        // No allowance
        assertEq(sellToken.allowance(swapper, address(swapContract)), 0, "No allowance");

        // Bad permit (wrong signer)
        uint256 wrongPk = 0xDEAD;
        openSwapV2Permit.PermitParams memory badPermit = _signPermit(
            wrongPk, address(sellToken), address(swapContract), SELL_AMT, block.timestamp + 1 hours
        );

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);
        vm.expectRevert(); // transferFrom fails — no allowance and permit was bad
        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), badPermit
        );
        vm.stopPrank();
    }

    // ============ 5. Permit with non-permit token (no permit function) → catch, falls back ============

    function testPermit_TokenWithoutPermitSupport_FallsBackToAllowance() public {
        // Deploy a non-permit token
        MockERC20NoPermit noPermitToken = new MockERC20NoPermit("NoPermit", "NP");
        noPermitToken.transfer(swapper, 100e18);

        // Swapper pre-approves
        vm.prank(swapper);
        noPermitToken.approve(address(swapContract), type(uint256).max);

        // Try to use permit params — the permit call will revert (no permit function), catch handles it
        openSwapV2Permit.PermitParams memory permit = openSwapV2Permit.PermitParams(
            SELL_AMT, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2))
        );

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;
        MockERC20Permit buyToken2 = new MockERC20Permit("Buy2", "B2");
        buyToken2.transfer(matcher, 100_000e18);
        vm.prank(matcher);
        buyToken2.approve(address(swapContract), type(uint256).max);

        uint256 balBefore = noPermitToken.balanceOf(swapper);

        vm.startPrank(swapper);
        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(noPermitToken), MIN_OUT, address(buyToken2), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );
        vm.stopPrank();

        assertEq(noPermitToken.balanceOf(swapper), balBefore - SELL_AMT, "Transfer via fallback on non-permit token");
    }

    // ============ 6. Expired permit, no allowance → reverts ============

    function testPermit_Expired_NoAllowance_Reverts() public {
        assertEq(sellToken.allowance(swapper, address(swapContract)), 0, "No allowance");

        // Sign permit with deadline in the past
        openSwapV2Permit.PermitParams memory permit = _signPermit(
            swapperPk, address(sellToken), address(swapContract), SELL_AMT, block.timestamp - 1
        );

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        // Permit fails (expired), catch swallows it, transferFrom fails (no allowance)
        vm.startPrank(swapper);
        vm.expectRevert();
        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );
        vm.stopPrank();
    }

    // ============ 7. Expired permit but existing allowance → catch, fallback works ============

    function testPermit_Expired_WithAllowance_FallsBack() public {
        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        openSwapV2Permit.PermitParams memory permit = _signPermit(
            swapperPk, address(sellToken), address(swapContract), SELL_AMT, block.timestamp - 1
        );

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );
        vm.stopPrank();

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Fallback to allowance on expired permit");
        assertTrue(swapContract.getSwap(swapId).active, "Swap active");
    }

    // ============ 8. Reused signature (nonce consumed) → catch, needs allowance ============

    function testPermit_ReusedSignature_SecondSwapNeedsAllowance() public {
        assertEq(sellToken.allowance(swapper, address(swapContract)), 0, "No allowance");

        openSwapV2Permit.PermitParams memory permit = _signPermit(
            swapperPk, address(sellToken), address(swapContract), SELL_AMT, block.timestamp + 1 hours
        );

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        // First swap succeeds via permit
        vm.startPrank(swapper);
        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );

        // Nonce consumed — same signature is now invalid
        // No allowance remains (permit set exactly SELL_AMT, transferFrom consumed it)
        // Second swap should revert
        vm.expectRevert();
        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );
        vm.stopPrank();
    }

    // ============ 9. permit.value < sellAmt → permit succeeds but transferFrom reverts ============

    function testPermit_ValueLessThanSellAmt_Reverts() public {
        assertEq(sellToken.allowance(swapper, address(swapContract)), 0, "No allowance");

        // Sign permit for less than sellAmt
        uint256 insufficientValue = SELL_AMT / 2;
        openSwapV2Permit.PermitParams memory permit = _signPermit(
            swapperPk, address(sellToken), address(swapContract), insufficientValue, block.timestamp + 1 hours
        );

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD;

        // Permit succeeds (sets allowance to insufficientValue), but transferFrom(sellAmt) > allowance → revert
        vm.startPrank(swapper);
        vm.expectRevert();
        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken), MIN_FULFILL_LIQUIDITY,
            uint48(1 hours), GAS_COMPENSATION, _oracleParams(), _slippageParams(), _fulfillFeeParams(), permit
        );
        vm.stopPrank();
    }
}
