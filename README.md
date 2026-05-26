# openOracle

openOracle is a trust-minimized, permissionless mechanism for resolving token prices onchain.

An openOracle report is two limit orders: a buy order and a sell order at the same price. These orders remain active until either the timer runs out or one side is taken. To take one of the orders, the taker must replace both orders with larger orders at a new price, and the timer resets. When the timer runs out without another dispute, the final surviving price can be used by applications.

## Deployments

### Base

<table>
<tr>
<th>Contract</th>
<th>Deployment Address</th>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xa731450131bE0120420e211a35704A19382489fb#code">OpenOracle</a></td>
<td><code>0xa731450131bE0120420e211a35704A19382489fb</code></td>
</tr>
</table>

## Docs

- [openOracle documentation](https://docs.openoracle.org)

## Usage

### Install
To install dependencies and compile contracts:

```bash
git clone 
forge install
forge build
```

### Foundry Tests

```bash
forge test
```

### Format

```bash
forge fmt
```

## Socials

- [X](https://x.com/OpenOracleEth)
- [Discord](https://discord.gg/jQGeX6CAJB)
