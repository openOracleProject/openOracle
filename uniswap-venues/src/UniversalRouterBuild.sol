// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Compilation shim ONLY.
//
// The real Universal Router's V4Router pins `=0.8.26` while every OpenPunt source pins exactly
// 0.8.28, and a file's whole import closure must resolve to one solc version. No test can
// therefore import both the router and OracleDisputeHelper directly.
//
// This shim exists purely so the router's artifact is produced (at 0.8.26). Tests running at
// 0.8.28 then deploy the REAL router with `vm.deployCode` and talk to it through a minimal
// interface — the same technique the Permit2 tranche uses to place authentic runtime code.
import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";

abstract contract UniversalRouterBuild {
    function _unused(RouterParameters memory p) internal pure returns (RouterParameters memory) {
        return p;
    }
}
