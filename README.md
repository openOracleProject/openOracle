# OpenOracle Gas Golfing

This repository is an experimental gas-golfing workspace for openOracle and openSwap.

The point is to see how far the oracle game and swap flow can be compressed while preserving the important mechanics.

This is not production-ready code. It is a research prototype for measuring tradeoffs, finding the practical gas floor, and stress-testing design ideas.

## Where We Are Today

The latest prototype `src/OpenOracleSlim.sol` uses a single state hash with state derived from calldata as well as forced sentinels and internal balances. Measured end-to-end on Base, with the reporter and disputer funding their token legs from pre-deposited internal balances (via `deposit` / `tryInternalBalance{1,2}`), and with no protocol fees:

| Path | Oracle Slim |
| --- | ---: |
| `report`  | 69k |
| `dispute` | 60k |
| `settle` | 48k |
| **Lifecycle total** | **178k** |

The swapping application `src/OpenSwapSlim.sol` uses a propose -> match -> execute flow, where the match creates an oracle report and execution uses the final oracle price. openSwap matching uses internal oracle balances for swap liquidity as well. Swappers can either use internal oracle game balances for the whole flow or transfer in on swap and receive on execution. 

Tested with the external transfers for the swapper but internal for matcher (ETH in from swapper during propose, matcher puts up USDC, USDC out to swapper on execute, ETH to matcher internally):

| Path | Swap Slim |
| --- | ---: |
| `propose`  | 79k |
| `match` | 107k |
| `execute` | 114k |
| **Lifecycle total** | **300k** |

```

## Upstream Project

OpenOracle docs: https://docs.openoracle.org
