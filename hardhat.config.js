// MING is deployed on BNB Smart Chain Mainnet (chain ID 56).
// Compiler settings match the source verified on BscScan.
module.exports = {
  solidity: {
    version: "0.8.37",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "osaka",
    },
  },
  networks: {
    bsc: {
      url: process.env.BSC_RPC_URL || "https://bsc-dataseed.bnbchain.org",
      chainId: 56,
    },
    bscTestnet: {
      url: process.env.BSC_TESTNET_RPC_URL || "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
      chainId: 97,
    },
  },
};
