pragma solidity =0.5.16;

// Compilation shim only — forces the real Uniswap V2 factory/pair artifacts to be produced at
// their pinned 0.5.16 so tests at 0.8.28 can place them with vm.deployCode.
import "v2-core/contracts/UniswapV2Factory.sol";
