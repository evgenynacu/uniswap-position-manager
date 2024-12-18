// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/**
 * Contract which manages an Uniswap V3 Position
 * Can rebalance and change the ticks of the position
 */
contract UniswapPositionManager {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  INonfungiblePositionManager public nftManager;
  IUniswapV3Factory public uniswapFactory;
  IQuoter public quoter;

  uint256 private constant MINT_BURN_SLIPPAGE = 100; // 1%
  // exchange router address
  address private constant exchange = 0x111111125421cA6dc452d289314280a0f8842A65;

  constructor(
    INonfungiblePositionManager _nftManager,
    IUniswapV3Factory _uniswapFactory,
    IQuoter _quoter
  ) {
    nftManager = _nftManager;
    uniswapFactory = _uniswapFactory;
    quoter = _quoter;
  }

  /* ========================================================================================= */
  /*                                          Structs                                          */
  /* ========================================================================================= */

  // Parameters for reposition function input
  struct RepositionParams {
    uint256 positionId;
    int24 newTickLower;
    int24 newTickUpper;
    uint256 minAmount0Staked;
    uint256 minAmount1Staked;
    bytes swapData;
  }

  //todo add Pool struct to make it more readable

  // Main position parameters
  struct Position {
    uint256 id;
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
  }

  /* ========================================================================================= */
  /*                                          Events                                           */
  /* ========================================================================================= */

  event Repositioned(
    uint256 indexed oldPositionId,
    uint256 indexed newPositionId,
    int24 oldLowerTick,
    int24 oldUpperTick,
    int24 newLowerTick,
    int24 newUpperTick,
    uint256 newStakedToken0Balance,
    uint256 newStakedToken1Balance
  );

  event PositionState(
    uint256 token0Balance,
    uint256 token1Balance,
    uint256 value
  );

  /* ========================================================================================= */
  /*                                        User-facing                                        */
  /* ========================================================================================= */

  /**
   * @dev Rebalance a given Uni V3 position to a new price range
   * @param params Reposition parameter structure
   */
  function reposition(RepositionParams calldata params) public {
    Position memory pos = readPosition(params.positionId);
    require(
      nftManager.ownerOf(params.positionId) == msg.sender,
      "Caller must own position"
    );
    require(
      params.newTickLower != pos.tickLower ||
        params.newTickUpper != pos.tickUpper,
      "Need to change ticks"
    );

    address poolAddress = getPoolAddress(pos);
    uint160 poolPrice = getPoolPriceFromAddress(poolAddress);

    // withdraw entire liquidity from the position
    withdrawAll(poolPrice, pos);
    // burn current position NFT
    burn(params.positionId);

    _emitState(pos);

    // swap using external exchange and stake all tokens in position after swap
    if (params.swapData.length != 0) {
      approveSwap(pos);
      exchangeSwap(params.swapData);

      poolPrice = getPoolPriceFromAddress(poolAddress);
    }

    approveNftManager(pos);

    _emitState(pos);

    (uint256 amount0Minted, uint256 amount1Minted) = calculatePoolMintedAmounts(
      IERC20(pos.token0).balanceOf(address(this)),
      IERC20(pos.token1).balanceOf(address(this)),
      poolPrice,
      getPriceFromTick(params.newTickLower),
      getPriceFromTick(params.newTickUpper)
    );

    Position memory newPos = createPosition(
      amount0Minted,
      amount1Minted,
      pos,
      params.newTickLower,
      params.newTickUpper
    );

    _returnChange(pos);

    // Check if balances meet min threshold
    (
      uint256 stakedToken0Balance,
      uint256 stakedToken1Balance
    ) = getStakedTokenBalances(poolPrice, newPos);
    require(
      params.minAmount0Staked <= stakedToken0Balance &&
        params.minAmount1Staked <= stakedToken1Balance,
      "Staked amounts after rebalance are insufficient"
    );

    emit Repositioned(
      params.positionId,
      newPos.id,
      pos.tickLower,
      pos.tickUpper,
      params.newTickLower,
      params.newTickUpper,
      stakedToken0Balance,
      stakedToken1Balance
    );
  }

  function _emitState(Position memory pos) private {
    uint256 token0Balance = IERC20(pos.token0).balanceOf(address(this));
    uint256 token1Balance = IERC20(pos.token1).balanceOf(address(this));
    if (token0Balance == 0) {
      emit PositionState(token0Balance, token1Balance, token1Balance);
    } else {
      uint256 totalValue = token1Balance + quoter.quoteExactInputSingle(pos.token0, pos.token1, pos.fee, token0Balance, 0);
      emit PositionState(token0Balance, token1Balance, totalValue);
    }
  }

  /**
   * @dev Returns tokens left on the contract balance to the caller
   */
  function _returnChange(Position memory pos) internal {
    // Return balance not sent to user
    IERC20(pos.token0).safeTransfer(
      msg.sender,
      IERC20(pos.token0).balanceOf(address(this))
    );
    IERC20(pos.token1).safeTransfer(
      msg.sender,
      IERC20(pos.token1).balanceOf(address(this))
    );
  }

  /**
   * @dev Withdraws all current liquidity from the position
   */
  function withdrawAll(
    uint160 poolPrice,
    Position memory pos
  ) private returns (uint256 _amount0, uint256 _amount1) {
    // Collect fees
    collect(pos.id);
    (_amount0, _amount1) = unstakePosition(poolPrice, pos);
    collectPosition(uint128(_amount0), uint128(_amount1), pos.id);
    //todo simplify. why we need several times to collect here?
  }

  /**
   * @dev Removes all liquidity from the Uni V3 position
   * @return amount0 token0 amount unstaked
   * @return amount1 token1 amount unstaked
   */
  function unstakePosition(
    uint160 poolPrice,
    Position memory pos
  ) private returns (uint256 amount0, uint256 amount1) {
    // calculate amounts to withdraw
    (uint256 _amount0, uint256 _amount1) = getAmountsForLiquidity(pos.liquidity, poolPrice, pos);
    // withdraw liquidity
    (amount0, amount1) = nftManager.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: pos.id,
        liquidity: pos.liquidity,
        amount0Min: _amount0,
        amount1Min: _amount1,
        deadline: block.timestamp
      })
    );
  }

  /**
   * @dev Stake liquidity in position represented by tokenId NFT
   */
  function stakePosition(
    uint256 amount0,
    uint256 amount1,
    uint256 tokenId,
    uint160 poolPrice,
    uint160 priceLower,
    uint160 priceUpper
  ) private returns (uint256 stakedAmount0, uint256 stakedAmount1) {
    (uint256 stakeAmount0, uint256 stakeAmount1) = calculatePoolMintedAmounts(
      amount0,
      amount1,
      poolPrice,
      priceLower,
      priceUpper
    );
    (, stakedAmount0, stakedAmount1) = nftManager.increaseLiquidity(
      INonfungiblePositionManager.IncreaseLiquidityParams({
        tokenId: tokenId,
        amount0Desired: stakeAmount0,
        amount1Desired: amount1,
        amount0Min: stakeAmount0.sub(stakeAmount0.div(MINT_BURN_SLIPPAGE)),
        amount1Min: stakeAmount1.sub(stakeAmount1.div(MINT_BURN_SLIPPAGE)),
        deadline: block.timestamp
      })
    );
  }

  /**
   * @notice Collect fees generated from position
   */
  function collect(
    uint256 positionId
  ) private returns (uint256 collected0, uint256 collected1) {
    (collected0, collected1) = collectPosition(
      type(uint128).max,
      type(uint128).max,
      positionId
    );
  }

  /**
   *  @dev Collect token amounts from pool position
   */
  function collectPosition(
    uint128 amount0,
    uint128 amount1,
    uint256 positionId
  ) private returns (uint256 collected0, uint256 collected1) {
    (collected0, collected1) = nftManager.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: positionId,
        recipient: address(this),
        amount0Max: amount0,
        amount1Max: amount1
      })
    );
  }

  /**
   * @dev burn NFT representing a pool position with tokenId
   * @dev uses NFT Position Manager
   */
  function burn(uint256 tokenId) private {
    nftManager.burn(tokenId);
  }

  /**
   * @dev Creates the NFT token representing the pool position
   * @dev Mint initial liquidity
   */
  //todo replace Position with Pool
  function createPosition(
    uint256 amount0,
    uint256 amount1,
    Position memory pos,
    int24 newTickLower,
    int24 newTickUpper
  ) private returns (Position memory) {
    (uint _tokenId, , , ) = nftManager.mint(
      INonfungiblePositionManager.MintParams({
        token0: pos.token0,
        token1: pos.token1,
        fee: pos.fee,
        tickLower: newTickLower,
        tickUpper: newTickUpper,
        amount0Desired: amount0,
        amount1Desired: amount1,
        amount0Min: amount0.sub(amount0.div(MINT_BURN_SLIPPAGE)),
        amount1Min: amount1.sub(amount1.div(MINT_BURN_SLIPPAGE)),
        recipient: msg.sender,
        deadline: block.timestamp
      })
    );
    return readPosition(_tokenId);
  }

  /* ========================================================================================= */
  /*                               Swap Swap Helper functions                                 */
  /* ========================================================================================= */

  /**
   * @dev Swap tokens in CLR (mining pool) using external swap
   * @param _swapData - Swap calldata, generated off-chain
   */
  function exchangeSwap(bytes memory _swapData) private {
    (bool success, ) = exchange.call(_swapData);

    require(success, "Swap call failed");
  }

  /**
   * Approve NFT Manager for deposits
   */
  //todo replace with Pool
  function approveNftManager(Position memory pos) private {
    if (IERC20(pos.token0).allowance(address(this), address(nftManager)) == 0) {
      IERC20(pos.token0).safeApprove(address(nftManager), type(uint256).max);
    }

    if (IERC20(pos.token1).allowance(address(this), address(nftManager)) == 0) {
      IERC20(pos.token1).safeApprove(address(nftManager), type(uint256).max);
    }
  }

  /**
   * Approve assets for swaps
   */
  //todo replace with Pool
  function approveSwap(Position memory pos) private {
    if (
      IERC20(pos.token0).allowance(address(this), address(exchange)) == 0
    ) {
      IERC20(pos.token0).safeApprove(exchange, type(uint256).max);
    }
    if (
      IERC20(pos.token1).allowance(address(this), address(exchange)) == 0
    ) {
      IERC20(pos.token1).safeApprove(exchange, type(uint256).max);
    }
  }

  /* ========================================================================================= */
  /*                               Uniswap Getter Helper functions                             */
  /* ========================================================================================= */

  /**
   * @notice Get token balances in the position
   */
  function getStakedTokenBalance(
    uint256 positionId
  ) external view returns (uint256 amount0, uint256 amount1) {
    Position memory pos = readPosition(positionId);
    uint160 poolPrice = getPoolPriceFromAddress(getPoolAddress(pos));
    (amount0, amount1) = getStakedTokenBalances(poolPrice, pos);
  }

  /**
   * @notice Get token balances in the position
   */
  function getStakedTokenBalances(
    uint160 poolPrice,
    Position memory pos
  ) internal view returns (uint256 amount0, uint256 amount1) {
    (amount0, amount1) = getAmountsForLiquidity(
      pos.liquidity,
      poolPrice,
      pos
    );
  }

  /**
   * @dev Calculates the amounts deposited/withdrawn from the pool
   * amount0, amount1 - amounts to deposit/withdraw
   * amount0Minted, amount1Minted - actual amounts which can be deposited
   */
  function calculatePoolMintedAmounts(
    uint256 amount0,
    uint256 amount1,
    uint160 poolPrice,
    uint160 priceLower,
    uint160 priceUpper
  ) public pure returns (uint256 amount0Minted, uint256 amount1Minted) {
    uint128 liquidityAmount = getLiquidityForAmounts(
      amount0,
      amount1,
      poolPrice,
      priceLower,
      priceUpper
    );
    (amount0Minted, amount1Minted) = getAmountsForLiquidity(
      liquidityAmount,
      poolPrice,
      priceLower,
      priceUpper
    );
  }

  /**
   * @dev Calculate pool liquidity for given token amounts
   */
  function getLiquidityForAmounts(
    uint256 amount0,
    uint256 amount1,
    uint160 poolPrice,
    uint160 priceLower,
    uint160 priceUpper
  ) public pure returns (uint128 liquidity) {
    liquidity = LiquidityAmounts.getLiquidityForAmounts(
      poolPrice,
      priceLower,
      priceUpper,
      amount0,
      amount1
    );
  }

  /**
   * @dev Calculate token amounts for given pool liquidity
   */
  function getAmountsForLiquidity(
    uint128 liquidity,
    uint160 poolPrice,
    Position memory pos
  ) public pure returns (uint256 amount0, uint256 amount1) {
    (amount0, amount1) = getAmountsForLiquidity(
      liquidity,
      poolPrice,
      getPriceFromTick(pos.tickLower),
      getPriceFromTick(pos.tickUpper)
    );
  }

  /**
   * @dev Calculate token amounts for given pool liquidity
   */
  function getAmountsForLiquidity(
    uint128 liquidity,
    uint160 poolPrice,
    uint160 priceLower,
    uint160 priceUpper
  ) public pure returns (uint256 amount0, uint256 amount1) {
    (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
      poolPrice,
      priceLower,
      priceUpper,
      liquidity
    );
  }

  /**
   * @dev get price from tick
   */
  function getPriceFromTick(int24 tick) public pure returns (uint160) {
    return TickMath.getSqrtRatioAtTick(tick);
  }

  /**
   * @dev Get a pool's price from position id
   * @param positionId the position id
   */
  function getPoolPrice(
    uint256 positionId
  ) external view returns (uint160 price) {
    return getPoolPriceFromAddress(getPoolAddress(readPosition(positionId)));
  }

  /**
   * @dev Get a pool's price from pool address
   * @param _pool the pool address
   */
  function getPoolPriceFromAddress(
    address _pool
  ) public view returns (uint160 price) {
    IUniswapV3Pool pool = IUniswapV3Pool(_pool);
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    return sqrtRatioX96;
  }

  /* ========================================================================================= */
  /*                               Uni V3 NFT Manager Helper functions                         */
  /* ========================================================================================= */

  function getPoolAddress(
    Position memory pos
  ) public view returns (address pool) {
    return uniswapFactory.getPool(pos.token0, pos.token1, pos.fee);
  }

  /**
   * @dev Returns the parameters needed for reposition function
   * @param positionId the nft id of the position
   */
  function readPosition(
    uint256 positionId
  ) public view returns (Position memory) {
    (
      ,
      ,
      address token0,
      address token1,
      uint24 fee,
      int24 tickLower,
      int24 tickUpper,
      uint128 liquidity,
      ,
      ,
      ,

    ) = nftManager.positions(positionId);
    return
      Position({
        id: positionId,
        token0: token0,
        token1: token1,
        fee: fee,
        tickLower: tickLower,
        tickUpper: tickUpper,
        liquidity: liquidity
      });
  }
}
