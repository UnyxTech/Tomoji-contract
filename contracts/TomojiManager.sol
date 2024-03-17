// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {DataTypes} from "./libraries/DataTypes.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {LibCaculatePair} from "./libraries/LibCaculatePair.sol";
import {Math} from "./libraries/Math.sol";
import {ITomojiManager} from "./interfaces/ITomojiManager.sol";
import {ITomoji} from "./interfaces/ITomoji.sol";
import {ITomojiFactory} from "./interfaces/ITomojiFactory.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

contract TomojiManager is ITomojiManager {
    error OnlyCallByFactory();
    error SendETHFailed();
    error ZeroAddress();
    error X404SwapV3FactoryMismatch();
    error CreatePairFailed();
    error NotExistTokenId();

    DataTypes.SwapRouter public _swapRouter;
    address public _factory;
    mapping(address => uint) private _positionTokenId;

    modifier onlyFactory() {
        if (msg.sender != _factory) {
            revert OnlyCallByFactory();
        }
        _;
    }

    constructor(DataTypes.SwapRouter memory swapRouter, address factory) {
        _swapRouter = swapRouter;
        _factory = factory;
    }

    function prePairTomojiEnv(
        address tomojiAddr,
        uint256 mintPrice
    ) public onlyFactory returns (bool) {
        address routerAddr = _swapRouter.routerAddr;
        if (routerAddr == address(0)) {
            revert ZeroAddress();
        }

        address weth_ = INonfungiblePositionManager(routerAddr).WETH9();
        address swapFactory = INonfungiblePositionManager(routerAddr).factory();
        address v3NonfungiblePositionManager = _swapRouter
            .uniswapV3NonfungiblePositionManager;
        if (v3NonfungiblePositionManager == address(0)) {
            revert ZeroAddress();
        }
        if (
            INonfungiblePositionManager(v3NonfungiblePositionManager)
                .factory() !=
            swapFactory ||
            INonfungiblePositionManager(v3NonfungiblePositionManager).WETH9() !=
            weth_
        ) {
            revert X404SwapV3FactoryMismatch();
        }
        _setV3SwapTransferExempt(tomojiAddr, swapFactory, tomojiAddr, weth_);
        _createUniswapV3Pool(
            v3NonfungiblePositionManager,
            tomojiAddr,
            weth_,
            mintPrice
        );
        return true;
    }

    function addLiquidityForTomoji(
        address tomojiAddr,
        uint256 tokenAmount
    ) public payable returns (bool) {
        address v3NonfungiblePositionManagerAddress = _swapRouter
            .uniswapV3NonfungiblePositionManager;
        address _weth = INonfungiblePositionManager(
            v3NonfungiblePositionManagerAddress
        ).WETH9();
        (address token0, address token1, bool zeroForOne) = tomojiAddr < _weth
            ? (tomojiAddr, _weth, true)
            : (_weth, tomojiAddr, false);

        uint256 ethValue = address(this).balance;
        (uint256 tokenId_, , , ) = INonfungiblePositionManager(
            v3NonfungiblePositionManagerAddress
        ).mint{value: ethValue}(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: uint24(10_000),
                tickLower: int24(-887272),
                tickUpper: int24(887272),
                amount0Desired: zeroForOne ? tokenAmount : ethValue,
                amount1Desired: zeroForOne ? ethValue : tokenAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        _positionTokenId[tomojiAddr] = tokenId_;

        uint256 leftToken = ITomoji(tomojiAddr).balanceOf(tomojiAddr);
        address creator = ITomoji(tomojiAddr).creator();
        if (leftToken > 0) {
            TransferHelper.erc20TransferFrom(
                tomojiAddr,
                tomojiAddr,
                creator,
                leftToken
            );
        }
        INonfungiblePositionManager(v3NonfungiblePositionManagerAddress)
            .refundETH();
        if (address(this).balance > 0) {
            (bool success, ) = payable(creator).call{
                value: address(this).balance
            }("");
            if (!success) {
                revert SendETHFailed();
            }
        }
        return true;
    }

    //collect liqiudity reward
    function collect(
        address tomojiAddr
    ) public returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = _positionTokenId[tomojiAddr];
        if (tokenId == 0) {
            revert NotExistTokenId();
        }
        address v3NonfungiblePositionManagerAddress = _swapRouter
            .uniswapV3NonfungiblePositionManager;
        (amount0, amount1) = INonfungiblePositionManager(
            v3NonfungiblePositionManagerAddress
        ).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        address feeAddr = ITomojiFactory(_factory).protocolFeeAddress();
        uint256 feePercentage = ITomojiFactory(_factory).protocolPercentage();
        uint256 tokenReward = ITomoji(tomojiAddr).balanceOf(address(this));
        uint256 ethReward = address(this).balance;
        address creator = ITomoji(tomojiAddr).creator();
        if (tokenReward > 0) {
            uint256 feeProtocol = (tokenReward * feePercentage) / 10000;
            TransferHelper.erc20Transfer(tomojiAddr, feeAddr, feeProtocol);
            TransferHelper.erc20Transfer(
                tomojiAddr,
                creator,
                tokenReward - feeProtocol
            );
        }
        if (ethReward > 0) {
            uint256 feeProtocol = (ethReward * feePercentage) / 10000;
            (bool success, ) = payable(feeAddr).call{value: feeProtocol}("");
            (bool success1, ) = payable(creator).call{
                value: ethReward - feeProtocol
            }("");
            if (!success || !success1) {
                revert SendETHFailed();
            }
        }
    }

    function getSwapRouter() public view returns (address, address) {
        return (
            _swapRouter.routerAddr,
            _swapRouter.uniswapV3NonfungiblePositionManager
        );
    }

    function _setV3SwapTransferExempt(
        address tomojiAddr,
        address swapFactory,
        address token0,
        address token1
    ) internal {
        uint24[3] memory feeTiers = [
            uint24(500),
            uint24(3_000),
            uint24(10_000)
        ];

        address[] memory pairs;
        for (uint256 i = 0; i < feeTiers.length; ) {
            address v3PairAddr = LibCaculatePair._getUniswapV3Pair(
                swapFactory,
                token0,
                token1,
                feeTiers[i]
            );
            // Set the v3 pair as exempt.
            pairs[i] = v3PairAddr;
            unchecked {
                ++i;
            }
        }
        ITomoji(tomojiAddr).setERC721TransferExempt(pairs, true);
    }

    function _createUniswapV3Pool(
        address v3NonfungiblePositionManager,
        address tokenA,
        address tokenB,
        uint256 mintPrice
    ) internal {
        (address token0, address token1, bool zeroForOne) = tokenA < tokenB
            ? (tokenA, tokenB, true)
            : (tokenB, tokenA, false);

        uint160 sqrtPriceX96;
        if (zeroForOne) {
            sqrtPriceX96 = uint160(Math.sqrt(mintPrice) * (2 ** 96));
        } else {
            sqrtPriceX96 = uint160(Math.sqrt(10 ** 36 / mintPrice) * (2 ** 96));
        }
        address pool = INonfungiblePositionManager(v3NonfungiblePositionManager)
            .createAndInitializePoolIfNecessary(
                token0,
                token1,
                uint24(10_000),
                sqrtPriceX96
            );
        if (pool == address(0)) {
            revert CreatePairFailed();
        }
    }
}
