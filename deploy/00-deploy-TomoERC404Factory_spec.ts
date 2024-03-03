/* Imports: Internal */
import { DeployFunction } from 'hardhat-deploy/dist/types'

import { ZeroAddress } from 'ethers';
import { ethers, upgrades } from 'hardhat';

const deployFn: DeployFunction = async (hre) => {
  
  const { deployer, owner } = await hre.getNamedAccounts()
  const swapRouterArray = [
    {
      bV2orV3: true,
      routerAddr: '0x3512ebD0Eb455f2FFDE4908D24F64aba7995951C',
      uniswapV3NonfungiblePositionManager: ZeroAddress,
    },
  ];
  const TomojiFactory = await ethers.getContractFactory("TomojiFactory");
  const proxy = await upgrades.deployProxy(TomojiFactory, [deployer, swapRouterArray]);
  const proxyAddress = await proxy.getAddress()
  console.log("proxy address: ", proxyAddress)
  console.log("admin address: ", await upgrades.erc1967.getAdminAddress(proxyAddress))
  console.log("implement address: ", await upgrades.erc1967.getImplementationAddress(proxyAddress))
}

// This is kept during an upgrade. So no upgrade tag.
deployFn.tags = ['TomojiFactory']

export default deployFn
