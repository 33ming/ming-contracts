# MING

A gamified mining protocol built on **BNB Smart Chain (BSC)**. Miners deploy BNB on a 25-tile grid, one tile is drawn every round on chain, and the miners on the drawn tile are paid in BNB and MING, with gold (XAUT) from the goldpot.

- Website: https://www.ming.family
- X: https://x.com/mingbnb
- Discord: https://discord.gg/sSJHJb4hUz

This repository holds the source of MING's core contracts on BNB Smart Chain, exactly as verified on BscScan. Compiling it with the settings in `hardhat.config.js` reproduces the deployed bytecode exactly.

## Technology Stack

- **Blockchain**: BNB Smart Chain Mainnet (Chain ID 56)
- **Smart Contracts**: Solidity 0.8.37, OpenZeppelin Contracts 5.4.0
- **Development**: Hardhat
- **Frontend**: Next.js + wagmi + viem
- **Automation**: Flap Trigger Service settles every round and runs the Treasury's buybacks on BNB Smart Chain
- **Launch**: Flap Pool Launch, which created the MING token, the reward vault and the PancakeSwap pool in one transaction

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56)

## Contract Addresses

BNB Smart Chain Mainnet (Chain ID 56). Each address links to its verified source on BscScan.

| Contract | Address | What it does |
|---|---|---|
| GridMining | [0x50518bfb43d526F0342459cF92CB0AeC25D38Fd9](https://bscscan.com/address/0x50518bfb43d526F0342459cF92CB0AeC25D38Fd9#code) | The game: takes deployments, draws a tile each round, records payouts |
| Treasury | [0x427992090a24122Df5b77b5cC259804af7Ad8844](https://bscscan.com/address/0x427992090a24122Df5b77b5cC259804af7Ad8844#code) | Buys MING back and burns it, and buys gold for stakers |
| Staking | [0x9515533189751237D92A77068a61D1D100ABd966](https://bscscan.com/address/0x9515533189751237D92A77068a61D1D100ABd966#code) | Stake MING, earn gold (XAUT) |
| AutoMiner | [0x0a570E5Ac33118f36c9B0AC7bFFCAB6bde57c308](https://bscscan.com/address/0x0a570E5Ac33118f36c9B0AC7bFFCAB6bde57c308#code) | Mines the same tiles for several rounds in advance |
| MingRewardVault | [0xb007EF6EDEB3bBC3500D820acCE4476CC42188F8](https://bscscan.com/address/0xb007EF6EDEB3bBC3500D820acCE4476CC42188F8#code) | Holds the MING mining pays out, released only to the game. A proxy with Flap as its guardian |
| MING token | [0x35771285a60B2aA5d4f5AcB917cc019Ee1DF7777](https://bscscan.com/token/0x35771285a60B2aA5d4f5AcB917cc019Ee1DF7777) | The protocol token, created by Flap Pool Launch |
| MING/WBNB pool (PancakeSwap) | [0x14BaCB4C10578c6D561b22244b3f5bF0dF1764c8](https://bscscan.com/address/0x14BaCB4C10578c6D561b22244b3f5bF0dF1764c8) | The trading pool opened at launch |
| XAUT (Tether Gold) | [0x21cAef8A43163Eea865baeE23b9C2E327696A3bf](https://bscscan.com/token/0x21cAef8A43163Eea865baeE23b9C2E327696A3bf) | The gold the goldpot and stakers are paid in (external) |

The same addresses, with the chain ID and RPC, are in [`deployments/bsc-mainnet.json`](deployments/bsc-mainnet.json).

## Features

- **The grid**: 25 tiles and 60-second rounds on BNB Smart Chain. One tile is drawn per round on chain, and every tile has the same 1 in 25 chance.
- **Payouts**: miners on the drawn tile share the round's BNB after fees, in proportion to what they deployed on it, plus 1 MING from the reward vault.
- **Fixed supply**: 1,000,000 MING minted once at launch, with no further minting. The reward vault releases MING only to the game, capped at 2,000 MING a day.
- **Fees back into the token**: 1% admin fee on everything deployed. A 10% protocol fee on the BNB on tiles not drawn: 89% buys MING on the market and burns it, 10% buys gold for the goldpot, 1% buys gold for stakers.
- **Goldpot**: gold (XAUT) that builds every round and pays out all at once to the drawn tile, at odds set in the contract.
- **Staking**: stake MING and earn gold (XAUT). Withdraw in full after 24 hours, or at once with 10% burned.
- **Loop**: a per-wallet mining account that puts its payouts back into the same tiles, so mining continues without a new transaction each run.
- **Unprocessed and processed MING**: mined MING arrives unprocessed. Claiming takes 10%, which is shared among holders of unprocessed MING.
- **Gold Reserve**: 2% of the 3% trade tax buys gold (XAUT), placed as liquidity below the MING price.
- **Timelocks**: changes to the game's and Treasury's wiring wait 48 hours in public before they apply.

## Repository Layout

```
contracts/                    Solidity source, as verified on BscScan
  GridMining.sol              The game
  Treasury.sol                Buybacks, burns and stakers' gold
  Staking.sol                 MING staking, paid in gold (XAUT)
  AutoMiner.sol               Mining several rounds in advance
  MingRewardVault.sol         The reward vault
  GoldRequestBase.sol         Gold (XAUT) swaps through Flap's FlapVaultEx
  Timelocked.sol              Public waits on changes to the wiring
  interfaces/, lib/           Interfaces and BNB Smart Chain addresses
deployments/bsc-mainnet.json  Chain ID, RPC and contract addresses on BNB Smart Chain
hardhat.config.js             BNB Smart Chain networks and the compiler settings used for verification
```

## Build

```bash
npm install
npx hardhat compile
```
