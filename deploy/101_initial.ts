import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'

import uniswapAddresses from '../scripts/uniswapAddresses.json';
import { verifyContractWithArgs } from "../scripts/helpers"

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
	console.log(`deploying contracts on network ${hre.network.name}`)

	const { deploy } = hre.deployments;
	const { deployer } = await hre.getNamedAccounts();

	console.log("deploying contracts with the account:", deployer);

	let nftManagerAddress = uniswapAddresses.nonfungibleTokenPositionManagerAddress
	let uniFactoryAddress = uniswapAddresses.v3CoreFactoryAddress
	await deploy("UniswapPositionManager", {
		from: deployer,
		args: [nftManagerAddress, uniFactoryAddress]
	})

	await verifyContractWithArgs("0xd2c516C2312a02591d5546CE87B9e14C4Ec25DB2", nftManagerAddress, uniFactoryAddress)
}

export default func
func.tags = ['deploy-manager', 'all']
