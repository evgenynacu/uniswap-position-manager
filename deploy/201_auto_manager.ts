import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'

import uniswapAddresses from '../scripts/uniswapAddresses.json';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
	console.log(`deploying contracts on network ${hre.network.name}`)

	const { deploy } = hre.deployments;
	const { deployer } = await hre.getNamedAccounts();

	console.log("deploying contracts with the account:", deployer);

	let nftManagerAddress = uniswapAddresses.nonfungibleTokenPositionManagerAddress
	let uniFactoryAddress = uniswapAddresses.v3CoreFactoryAddress
	let quoterAddress = uniswapAddresses.quoterAddress

	await deploy("AutoPositionManager", {
		from: deployer,
		proxy: {
			execute: {
				init: {
					methodName: "__AutoPositionManager_init",
					args: [nftManagerAddress, uniFactoryAddress, quoterAddress, 10050, 500, 9500, 1, 1000],
				},
			}
		},
		autoMine: true,
		log: true,
	})
}

export default func
func.tags = ['deploy-auto-manager', 'all']
