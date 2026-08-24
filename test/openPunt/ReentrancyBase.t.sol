// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TokenCompatBase.t.sol";
import {ReentrantActor} from "./util/ReentrantActor.sol";
import {HookERC20, CloseWindowObserver} from "./util/HookERC20.sol";

/**
 * @notice Fixture for the reentrancy and callback matrix.
 *
 * @dev Every callback boundary is modelled as though the recipient receives all remaining
 *      gas. Affordability is never a security conclusion: no path is classified unreachable
 *      because a payload is expensive, and no fixture machinery exists to squeeze observations
 *      under a stipend. A gas schedule, compiler or storage-warmness change must not be able to
 *      turn a "safe" path into a reachable one.
 *
 *      The matrix is driven through OpenPunt's unbounded production paths:
 *
 *        cancelSwapOpen ......... ERC20 margin refund via `oracle.pushOrCredit`
 *        bailOut ................ ERC20 refund via `refund()`
 *        cancelCloseAuction ..... ERC20 Dutch refund via `oracle.pushOrCredit`
 *        execute (terminal) ..... ERC20 payout via `oracle.pushOrCredit`
 *        propose / close ........ ERC20 / Permit2 funding callback
 *        withdraw ............... unbounded ETH call
 *
 *      `oracle.pushOrCredit`'s gas limit applies only to its ETH branch; the ERC20 branch forwards
 *      all remaining gas. Using a hook token as position collateral therefore gives a real,
 *      production-code callback with an unbounded budget at exactly the right ordering boundary.
 *
 *      Guard map:
 *
 *        nonReentrant .............. cancelSwapOpen, bailOut, withdraw,
 *                                    deployAndDistributeFeeReceiver
 *        CEI + hash gating ......... propose, matchSwap, cancelCloseAuction,
 *                                    liquidationHeartbeat, report, execute, dust
 *        fund-then-compare-and-commit  close
 *
 *      The guard lives in `OpenPuntStorage`, which both the core and lifecycle module inherit,
 *      so a delegatecalled module function shares the core's guard slot.
 *
 *      ETH fallback-delivery behaviour (a failed push becoming a `tempHolding` or oracle credit)
 *      is covered by the dedicated ETH-delivery compatibility suites rather than this fixture.
 */
abstract contract ReentrancyBase is TokenCompatBase {
    ReentrantActor internal actor;
    ReentrantActor internal actor2;
    HookERC20 internal hookToken;
    CloseWindowObserver internal observer;

    function _setUpReentrancy() internal {
        _setUpTokenCompat();
        vm.txGasPrice(1 gwei);

        actor = new ReentrantActor();
        actor2 = new ReentrantActor();
        hookToken = new HookERC20("HookUSD", "HKUSD");
        observer = new CloseWindowObserver();

        vm.deal(address(actor), 10_000 ether);
        vm.deal(address(actor2), 10_000 ether);

        collat.mint(address(actor), 1_000_000e18);
        collat.mint(address(actor2), 1_000_000e18);
        actor.approveToken(address(collat), PERMIT2, type(uint256).max);
        actor2.approveToken(address(collat), PERMIT2, type(uint256).max);

        // the hook token is position collateral, so every ERC20 refund and payout is a
        // genuine unbounded callback through production code
        hookToken.mint(address(actor), 1_000_000e18);
        hookToken.mint(address(actor2), 1_000_000e18);
        hookToken.mint(swapper, 1_000_000e18);
        actor.approveToken(address(hookToken), PERMIT2, type(uint256).max);
        actor2.approveToken(address(hookToken), PERMIT2, type(uint256).max);
        vm.prank(swapper);
        hookToken.approve(PERMIT2, type(uint256).max);

        // the matcher posts from the oracle ledger, so matching never fires the hook
        hookToken.mint(matcher, 5_000_000e18);
        vm.startPrank(matcher);
        hookToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(hookToken), 5_000_000e18, matcher);
        oracle.approveInternal(address(punt), address(hookToken), type(uint256).max);
        vm.stopPrank();

        // the actors are funded as genuine reporters, so a callback can submit a real report()
        _fundAsReporter(address(actor));
        _fundAsReporter(address(actor2));
    }

    function _fundAsReporter(address who) internal {
        tokenA.mint(who, 5_000e18);
        tokenB.mint(who, 5_000_000e18);
        vm.deal(who, 10_000 ether);
        vm.startPrank(who);
        tokenA.approve(address(oracle), type(uint256).max);
        tokenB.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(tokenA), 5_000e18, who);
        oracle.deposit(address(tokenB), 5_000_000e18, who);
        oracle.deposit{value: 1 ether}(address(0), 1 ether, who);
        oracle.approveInternal(address(punt), address(tokenA), type(uint256).max);
        oracle.approveInternal(address(punt), address(tokenB), type(uint256).max);
        oracle.approveInternal(address(punt), address(0), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Position configuration whose COLLATERAL is the hook token, giving every ERC20 refund,
    ///      payout and funding step an unbounded callback at the production ordering boundary.
    function _hookCfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _tokenCfg(address(tokenA), address(tokenB), address(hookToken), false);
    }

    /// @dev The canonical Dutch struct `close()` stores, rebuilt for an arbitrary owner.
    function _canonicalFor(
        OpenPuntStorage.CloseDutch memory input,
        uint256 swapId,
        address collatToken,
        address owner,
        uint48 startTs
    ) internal pure returns (OpenPuntStorage.CloseDutch memory d) {
        d = _copy(input);
        d.swapper = owner;
        d.collatToken = collatToken;
        d.swapId = swapId;
        d.useInternalBalances = false;
        d.start = startTs;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Callback liveness
    // ══════════════════════════════════════════════════════════════════

    /// @dev A passing outer transaction with a callback count of zero proves nothing.
    function _assertCallbackReached(ReentrantActor a, uint256 expectedCount, string memory what) internal view {
        require(a.callbackCount() == expectedCount, string.concat(what, ": wrong callback count"));
        require(a.payloadExecuted(), string.concat(what, ": the reentrant payload never ran"));
    }

    /// @dev Requires a nonempty selector, so a claim that a particular guard fired cannot be
    ///      satisfied by an anonymous failure.
    function _assertInnerRevertedWith(ReentrantActor a, bytes4 expected, string memory what) internal view {
        require(!a.lastInnerOk(), string.concat(what, ": the reentrant call SUCCEEDED"));
        require(
            a.lastInnerReturndataLength() >= 4,
            string.concat(what, ": empty inner returndata - cannot distinguish a guard from out-of-gas")
        );
        require(a.lastInnerSelector() == expected, string.concat(what, ": wrong inner revert selector"));
    }

    function _assertInnerSucceeded(ReentrantActor a, string memory what) internal view {
        require(a.lastInnerOk(), string.concat(what, ": the reentrant call was expected to SUCCEED"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Strictly separated ledgers
    //
    //  Kept separate because aggregate ETH assertions can hide reversed or duplicated flows,
    //  especially through the shared address(0) oracle slot.
    // ══════════════════════════════════════════════════════════════════

    struct Ledgers {
        // raw ETH
        uint256 rawCore;
        uint256 rawModule;
        uint256 rawActor;
        uint256 rawActor2;
        uint256 rawOracle;
        // OpenPunt tempHolding
        uint256 tempActor;
        uint256 tempActor2;
        uint256 tempCore;
        // OpenOracle internal ETH
        uint256 oracleEthCore;
        uint256 oracleEthActor;
        uint256 oracleEthActor2;
        uint256 oracleEthModule;
        // external collateral
        uint256 extCollatActor;
        uint256 extCollatCore;
        uint256 extCollatOracle;
        // OpenOracle internal collateral
        uint256 oracleCollatCore;
        uint256 oracleCollatActor;
        uint256 oracleCollatModule;
    }

    function _ledgers(address collatToken) internal view returns (Ledgers memory l) {
        l.rawCore = address(punt).balance;
        l.rawModule = address(lifecycleModule).balance;
        l.rawActor = address(actor).balance;
        l.rawActor2 = address(actor2).balance;
        l.rawOracle = address(oracle).balance;

        l.tempActor = punt.tempHolding(address(actor));
        l.tempActor2 = punt.tempHolding(address(actor2));
        l.tempCore = punt.tempHolding(address(punt));

        l.oracleEthCore = _spendable(address(punt), address(0));
        l.oracleEthActor = _spendable(address(actor), address(0));
        l.oracleEthActor2 = _spendable(address(actor2), address(0));
        l.oracleEthModule = _spendable(address(lifecycleModule), address(0));

        if (collatToken != address(0)) {
            l.extCollatActor = _erc20(collatToken, address(actor));
            l.extCollatCore = _erc20(collatToken, address(punt));
            l.extCollatOracle = _erc20(collatToken, address(oracle));
            l.oracleCollatCore = _spendable(address(punt), collatToken);
            l.oracleCollatActor = _spendable(address(actor), collatToken);
            l.oracleCollatModule = _spendable(address(lifecycleModule), collatToken);
        }
    }

    function _erc20(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(ret, (uint256));
    }

    function _assertLedgersUnchanged(Ledgers memory a, address collatToken, string memory w) internal view {
        Ledgers memory b = _ledgers(collatToken);
        require(a.rawCore == b.rawCore, string.concat(w, ": raw core ETH"));
        require(a.rawModule == b.rawModule, string.concat(w, ": raw module ETH"));
        require(a.rawActor == b.rawActor, string.concat(w, ": raw actor ETH"));
        require(a.rawActor2 == b.rawActor2, string.concat(w, ": raw actor2 ETH"));
        require(a.rawOracle == b.rawOracle, string.concat(w, ": raw oracle ETH"));
        require(a.tempActor == b.tempActor, string.concat(w, ": tempHolding actor"));
        require(a.tempActor2 == b.tempActor2, string.concat(w, ": tempHolding actor2"));
        require(a.tempCore == b.tempCore, string.concat(w, ": tempHolding core"));
        require(a.oracleEthCore == b.oracleEthCore, string.concat(w, ": oracle ETH core"));
        require(a.oracleEthActor == b.oracleEthActor, string.concat(w, ": oracle ETH actor"));
        require(a.oracleEthActor2 == b.oracleEthActor2, string.concat(w, ": oracle ETH actor2"));
        require(a.oracleEthModule == b.oracleEthModule, string.concat(w, ": oracle ETH module"));
        require(a.extCollatActor == b.extCollatActor, string.concat(w, ": external collateral actor"));
        require(a.extCollatCore == b.extCollatCore, string.concat(w, ": external collateral core"));
        require(a.extCollatOracle == b.extCollatOracle, string.concat(w, ": external collateral oracle"));
        require(a.oracleCollatCore == b.oracleCollatCore, string.concat(w, ": oracle collateral core"));
        require(a.oracleCollatActor == b.oracleCollatActor, string.concat(w, ": oracle collateral actor"));
        require(a.oracleCollatModule == b.oracleCollatModule, string.concat(w, ": oracle collateral module"));
    }

    /// @dev The module must never retain funds or position state of its own.
    function _assertModuleClean(address t1, address t2, string memory w) internal view {
        require(address(lifecycleModule).balance == 0, string.concat(w, ": module raw ETH"));
        require(_spendable(address(lifecycleModule), address(0)) == 0, string.concat(w, ": module oracle ETH"));
        require(punt.tempHolding(address(lifecycleModule)) == 0, string.concat(w, ": module tempHolding"));
        // the hook collateral token is always checked, whether or not it is a leg of this test
        require(_erc20(address(hookToken), address(lifecycleModule)) == 0, string.concat(w, ": module raw hook token"));
        require(
            _spendable(address(lifecycleModule), address(hookToken)) == 0,
            string.concat(w, ": module oracle hook token")
        );
        require(_erc20(address(collat), address(lifecycleModule)) == 0, string.concat(w, ": module raw collateral"));
        require(
            _spendable(address(lifecycleModule), address(collat)) == 0, string.concat(w, ": module oracle collateral")
        );
        if (t1 != address(0)) {
            require(_erc20(t1, address(lifecycleModule)) == 0, string.concat(w, ": module raw token1"));
            require(_spendable(address(lifecycleModule), t1) == 0, string.concat(w, ": module oracle token1"));
        }
        if (t2 != address(0)) {
            require(_erc20(t2, address(lifecycleModule)) == 0, string.concat(w, ": module raw token2"));
            require(_spendable(address(lifecycleModule), t2) == 0, string.concat(w, ": module oracle token2"));
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Phase state
    // ══════════════════════════════════════════════════════════════════

    struct Phase {
        bytes32 swapHash;
        bytes32 dutchHash;
        bool closeIntent;
        uint128 pendingComp;
        uint128 hbReportId;
        uint48 hbTimestamp;
        uint256 nextSwapId;
        uint128 execComp;
        bytes32 oracleHash;
    }

    function _phase(uint256 swapId, uint256 reportId) internal view returns (Phase memory p) {
        p.swapHash = punt.swaps(swapId);
        p.dutchHash = _storedDutchState(swapId);
        (p.pendingComp,, p.closeIntent) = _closeState(swapId);
        (p.hbReportId, p.hbTimestamp) = punt.liquidationHeartbeats(swapId);
        p.nextSwapId = punt.nextSwapId();
        p.execComp = punt.executionGasComp(reportId);
        p.oracleHash = oracle.oracleGame(reportId);
    }

    function _assertPhaseUnchanged(Phase memory a, uint256 swapId, uint256 reportId, string memory w) internal view {
        Phase memory b = _phase(swapId, reportId);
        require(a.swapHash == b.swapHash, string.concat(w, ": position hash"));
        require(a.dutchHash == b.dutchHash, string.concat(w, ": Dutch hash"));
        require(a.closeIntent == b.closeIntent, string.concat(w, ": close intent"));
        require(a.pendingComp == b.pendingComp, string.concat(w, ": pending execution comp"));
        require(a.hbReportId == b.hbReportId, string.concat(w, ": heartbeat report id"));
        require(a.hbTimestamp == b.hbTimestamp, string.concat(w, ": heartbeat timestamp"));
        require(a.nextSwapId == b.nextSwapId, string.concat(w, ": nextSwapId"));
        require(a.execComp == b.execComp, string.concat(w, ": execution compensation"));
        require(a.oracleHash == b.oracleHash, string.concat(w, ": oracle hash"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  Actor-driven lifecycle
    // ══════════════════════════════════════════════════════════════════

    /// @dev The actor genuinely proposes as itself, so it really owns the position.
    function _actorPropose(
        ReentrantActor a,
        OpenPuntStorage.ProposedSwap memory s,
        OpenPuntStorage.MatcherPreimage memory m
    ) internal returns (Proposal memory p) {
        // _correctMsgValue already folds in the ETH margin for ETH-collateral proposals
        uint256 value = _correctMsgValue(s);

        vm.recordLogs();
        bytes memory ret = a.exec(address(punt), value, abi.encodeCall(punt.propose, (s, m, _emptyPermit2())));
        p.swapId = abi.decode(ret, (uint256));
        (p.swap, p.preimage) = _decodeSwapProposed(vm.getRecordedLogs(), p.swapId);
    }

    /// @dev ETH-collateral configuration, so ETH delivery genuinely reaches a contract swapper.
    function _ethCfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.isLong = true;
        s.collatToken = address(0);
        s.maturityWindow = MATURITY_LONG;
    }

    function _erc20Cfg()
        internal
        view
        returns (OpenPuntStorage.ProposedSwap memory s, OpenPuntStorage.MatcherPreimage memory m)
    {
        (s, m) = _cfgZeroFee(0);
        s.isLong = true;
        s.maturityWindow = MATURITY_LONG;
    }
}
