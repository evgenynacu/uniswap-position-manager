import "@typechain/hardhat";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-web3";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-etherscan"
import "hardhat-contract-sizer";
import "hardhat-deploy";
import "hardhat-deploy-ethers"
import { resolve } from "path";

import { config as dotenvConfig } from "dotenv";
import { HardhatUserConfig } from "hardhat/config";


dotenvConfig({ path: resolve(__dirname, "./.env") });

const alchemy = {
  mainnet: 'https://eth-mainnet.alchemyapi.io/v2/',
  arbitrum: 'https://arb-mainnet.g.alchemy.com/v2/',
  optimism: 'https://opt-mainnet.g.alchemy.com/v2/',
  polygon: 'https://polygon-mainnet.g.alchemy.com/v2/',
  goerli: 'https://eth-goerli.alchemyapi.io/v2/'
}

let alchemyKey: string;
if (!process.env.ALCHEMY_KEY) {
  throw new Error("Please set your ALCHEMY_KEY in a .env file");
} else {
  alchemyKey = process.env.ALCHEMY_KEY;
}

let etherscanKey: string;
if (!process.env.ETHERSCAN_API_KEY) {
  throw new Error("Please set your ETHERSCAN_API_KEY in a .env file");
} else {
  etherscanKey = process.env.ETHERSCAN_API_KEY;
}

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      forking: {
        // url: alchemy.mainnet + alchemyKey,
        url: alchemy.polygon + alchemyKey,
        // enabled: true,
      }
    },
    polygon: {
      accounts: [process.env.ADMIN_PRIVATE_KEY],
      url: alchemy.polygon + alchemyKey,
      timeout: 200000,
    },
    arbitrum: {
      accounts: [process.env.ADMIN_PRIVATE_KEY],
      url: "https://arbitrum.drpc.org",
      // timeout: 200000,
    },
    arbitrum2: {
      accounts: [process.env.ADMIN_PRIVATE_KEY],
      url: "https://arbitrum.drpc.org",
      chainId: 42161,
      // timeout: 200000,
    },
    optimism: {
      accounts: [process.env.ADMIN_PRIVATE_KEY],
      // gasPrice: 5 * 10 ** 9, // 5 gwei
      url: alchemy.optimism + alchemyKey,
      // timeout: 200000,
    },
    // goerli: {
    //   accounts: [adminPrivateKey],
    //   url: alchemy.goerli + alchemyKey,
    //   timeout: 200000
    // }
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
  },
  solidity: {
    version: "0.7.6",
    settings: {
      metadata: {
        // Not including the metadata hash
        // https://github.com/paulrberg/solidity-template/issues/31
        bytecodeHash: "none",
      },
      // You should disable the optimizer when debugging
      // https://hardhat.org/hardhat-network/#solidity-optimizer-support
      optimizer: {
        enabled: true,
        runs: 7777,
      },
    },
  },
  etherscan: {
    apiKey: etherscanKey
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v5"
  },
  namedAccounts: {
    deployer: 0,
  },
};

export default config;