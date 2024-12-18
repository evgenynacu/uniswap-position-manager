// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract AutoPositionManager is Initializable, ContextUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event Repositioned(
        uint256 indexed oldPositionId,
        uint256 indexed newPositionId,
        int24 oldLowerTick,
        int24 oldUpperTick,
        int24 newLowerTick,
        int24 newUpperTick,
        uint256 startValue,
        uint256 endValue,
        uint160 poolPrice
    );

    // ----- Data Types ----- //

    // Parameters for reposition function input
    struct RepositionParams {
        // todo verify ticks?
        int24 newTickLower;
        int24 newTickUpper;
        uint256 minAmount0Staked;
        uint256 minAmount1Staked;
        address exchange;
        bytes swapData;
    }

    struct Pool {
        address id;
        address token0;
        address token1;
        uint24 fee;
        uint160 price;
    }

    struct Position {
        uint256 id;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    enum Side {
        TOKEN0, TOKEN1
    }

    // ----- never changed after init ----- //

    INonfungiblePositionManager public nftManager;
    IUniswapV3Factory public uniswapFactory;
    IQuoter public quoter;

    // ----- configuration of the Vault, usually should not be changed during the operation ----- //

    // width of the interval (in bp, e.g 1.01 = 10100. 1.01 means lower price = price / width, higher = price * width)
    uint public width;
    // minimal share of token0. if it's less then position should be repositioned (in basis points, e.g 5% = 500)
    uint public minShare;
    // maximal share of token0. if it's more then position should be repositioned (in basis points, e.g. 95% = 9500)
    uint public maxShare;
    // Side of the pool which is used to value calculation
    Side public mainSide;
    // maximal loss for every reposition operation (in terms of one of the tokens)
    int256 public maxLoss;

    // ----- state of the Vault ----- //

    // currenct position id. if 0, then it's not yet initialized
    uint public positionId;

    //----------------------------------------//

    mapping(address => bool) private operators;

    // ----- Constants ----- //

    uint256 private constant MINT_BURN_SLIPPAGE = 100; // 1%

    // ----- Initalizers ----- //

    function __AutoPositionManager_init(
        INonfungiblePositionManager _nftManager,
        IUniswapV3Factory _uniswapFactory,
        IQuoter _quoter,
        uint256 _width,
        uint _minShare,
        uint _maxShare,
        Side _mainSide,
        int _maxLoss
    ) external initializer {
        __Context_init_unchained();
        __AutoPositionManager_init_unchained(_nftManager, _uniswapFactory, _quoter, _width, _minShare, _maxShare, _mainSide, _maxLoss);
    }

    function __AutoPositionManager_init_unchained(
        INonfungiblePositionManager _nftManager,
        IUniswapV3Factory _uniswapFactory,
        IQuoter _quoter,
        uint256 _width,
        uint _minShare,
        uint _maxShare,
        Side _mainSide,
        int _maxLoss
    ) internal {
        nftManager = _nftManager;
        uniswapFactory = _uniswapFactory;
        quoter = _quoter;
        width = _width;
        minShare = _minShare;
        maxShare = _maxShare;
        mainSide = _mainSide;
        maxLoss = _maxLoss;
    }

    //----------------------------------------//

    function withdraw() external onlyOwner {
        require(positionId != 0, "Nothing to withdraw");

        if (positionId != 0) {
            Position memory pos = readPosition(positionId);

            nftManager.transferFrom(address(this), _msgSender(), positionId);
            positionId = 0;

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
    }

    function onERC721Received(
        address, address from, uint256 tokenId, bytes calldata
    ) external override returns (bytes4) {
        require(_msgSender() == address(nftManager));
        require(from == _owner(), "Not owner!");
        require(positionId == 0, "Initialized");

        positionId = tokenId;

        return this.onERC721Received.selector;
    }

    function reposition(RepositionParams calldata params) external onlyOperator {
        Position memory pos = readPosition(positionId);
        _verifyPositionAndParams(params, pos);

        Pool memory pool = _readPool(pos);

        // withdraw entire liquidity from the position
        _withdrawPositionWithFees(pool, pos);

        // burn current position NFT
        _burn(pos.id);

        (,, uint startValue) = _calculateValue(pool);

        // swap using external exchange and stake all tokens in position after swap
        if (params.swapData.length != 0) {
            _approveSwap(pool, params.exchange);
            _exchange(params.exchange, params.swapData);

            //re-read price as it can change after the swap
            pool.price = getPoolPriceFromAddress(pool.id);
        }

        (,, uint endValue) = _calculateValue(pool);
        _verifyLoss(SafeCast.toInt256(startValue), SafeCast.toInt256(endValue));

        _approveNftManager(pool);
        Position memory newPos = _estimateAndCreatePosition(pool, params);
        positionId = newPos.id;

        emitRepositioned(pool.price, pos, newPos, startValue, endValue);
    }

    // ----- Helper functions ----- //

    function emitRepositioned(
        uint160 poolPrice,
        Position memory pos,
        Position memory newPos,
        uint startValue,
        uint endValue
    ) internal {
        emit Repositioned(
            pos.id,
            newPos.id,
            pos.tickLower,
            pos.tickUpper,
            newPos.tickLower,
            newPos.tickUpper,
            startValue,
            endValue,
            poolPrice
        );
    }

    function _verifyLoss(int256 startValue, int256 endValue) internal view returns (int256 loss) {
        loss = (endValue - startValue) / startValue * 10000;
        require(loss < maxLoss, "LossExceeds!");
    }

    function _estimateAndCreatePosition(
        Pool memory pool,
        RepositionParams memory params
    ) internal returns (Position memory newPos) {
        (uint256 amount0Minted, uint256 amount1Minted) = calculatePoolMintedAmounts(
            IERC20(pool.token0).balanceOf(address(this)),
            IERC20(pool.token1).balanceOf(address(this)),
            pool.price,
            getPriceFromTick(params.newTickLower),
            getPriceFromTick(params.newTickUpper)
        );

        newPos = createPosition(
            amount0Minted,
            amount1Minted,
            pool,
            params.newTickLower,
            params.newTickUpper
        );
    }

    /**
     * @dev Creates the NFT token representing the pool position
     * @dev Mint initial liquidity
     */
    function createPosition(
        uint256 amount0,
        uint256 amount1,
        Pool memory pool,
        int24 newTickLower,
        int24 newTickUpper
    ) private returns (Position memory) {
        (uint _tokenId, , ,) = nftManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: pool.token0,
                token1: pool.token1,
                fee: pool.fee,
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0.sub(amount0.div(MINT_BURN_SLIPPAGE)),
                amount1Min: amount1.sub(amount1.div(MINT_BURN_SLIPPAGE)),
                recipient: _msgSender(),
                deadline: block.timestamp
            })
        );
        return readPosition(_tokenId);
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
      * Approve NFT Manager for deposits
      */
    function _approveNftManager(Pool memory pool) private {
        if (IERC20(pool.token0).allowance(address(this), address(nftManager)) == 0) {
            IERC20(pool.token0).safeApprove(address(nftManager), type(uint256).max);
        }

        if (IERC20(pool.token1).allowance(address(this), address(nftManager)) == 0) {
            IERC20(pool.token1).safeApprove(address(nftManager), type(uint256).max);
        }
    }

    /**
     * Approve assets for swaps
     */
    function _approveSwap(Pool memory pool, address exchange) private {
        if (
            IERC20(pool.token0).allowance(address(this), address(exchange)) == 0
        ) {
            IERC20(pool.token0).safeApprove(exchange, type(uint256).max);
        }
        if (
            IERC20(pool.token1).allowance(address(this), address(exchange)) == 0
        ) {
            IERC20(pool.token1).safeApprove(exchange, type(uint256).max);
        }
    }

    /**
     * @dev Swap tokens in CLR (mining pool) using external swap
     * @param _swapData - Swap calldata, generated off-chain
     */
    function _exchange(address exchange, bytes memory _swapData) private {
        (bool success,) = exchange.call(_swapData);

        require(success, "Swap call failed");
    }

    function _calculateValue(Pool memory pool) private returns (uint token0Balance, uint token1Balance, uint value) {
        token0Balance = IERC20(pool.token0).balanceOf(address(this));
        token1Balance = IERC20(pool.token1).balanceOf(address(this));
        if (mainSide == Side.TOKEN1) {
            if (token0Balance == 0) {
                value = token1Balance;
            } else {
                value = token1Balance + quoter.quoteExactInputSingle(pool.token0, pool.token1, pool.fee, token0Balance, 0);
            }
        } else {
            if (token1Balance == 0) {
                value = token0Balance;
            } else {
                value = token0Balance + quoter.quoteExactInputSingle(pool.token1, pool.token0, pool.fee, token1Balance, 0);
            }
        }
    }

    /**
     * @dev Withdraws all current liquidity from the position
     */
    function _withdrawPositionWithFees(
        Pool memory pool,
        Position memory pos
    ) private returns (uint256 _amount0, uint256 _amount1) {
        (_amount0, _amount1) = _withdrawPositionFully(pool, pos);
        _collectFees(type(uint128).max, type(uint128).max, pos.id);
    }

    /**
     * @dev Removes all liquidity from the Uni V3 position
     * @return amount0 token0 amount unstaked
     * @return amount1 token1 amount unstaked
     */
    function _withdrawPositionFully(
        Pool memory pool,
        Position memory pos
    ) private returns (uint256 amount0, uint256 amount1) {
        // calculate amounts to withdraw
        (uint256 _amount0, uint256 _amount1) = getAmountsForLiquidity(pos.liquidity, pool.price, pos);
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
     *  @dev Collect token amounts from pool position
     */
    function _collectFees(
        uint128 _amount0,
        uint128 _amount1,
        uint256 _positionId
    ) private returns (uint256 collected0, uint256 collected1) {
        (collected0, collected1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: _positionId,
                recipient: address(this),
                amount0Max: _amount0,
                amount1Max: _amount1
            })
        );
    }

    function _verifyPositionAndParams(RepositionParams memory params, Position memory pos) pure private {
        require(
            params.newTickLower != pos.tickLower ||
            params.newTickUpper != pos.tickUpper,
            "TicksNotChanged"
        );
    }

    function _readPool(Position memory pos) internal view returns (Pool memory pool) {
        address poolAddress = getPoolAddress(pos);
        pool = Pool({
            id: poolAddress,
            token0: pos.token0,
            token1: pos.token1,
            fee: pos.fee,
            price: getPoolPriceFromAddress(poolAddress)
        });
    }

    function getPoolAddress(
        Position memory pos
    ) public view returns (address pool) {
        return uniswapFactory.getPool(pos.token0, pos.token1, pos.fee);
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
        (uint160 sqrtRatioX96, , , , , ,) = pool.slot0();
        return sqrtRatioX96;
    }

    /**
     * @dev Returns the parameters needed for reposition function
     * @param _positionId the nft id of the position
     */
    function readPosition(
        uint256 _positionId
    ) public view returns (Position memory) {
        require(_positionId != 0, "posId=0!");

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

        ) = nftManager.positions(_positionId);
        return
            Position({
            id: _positionId,
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
    }

    /**
     * @dev burn NFT representing a pool position with tokenId
     * @dev uses NFT Position Manager
     */
    function _burn(uint256 tokenId) private {
        nftManager.burn(tokenId);
    }

    //----------------------------------------//

    // @dev functions which can be only called by the operators
    modifier onlyOperator() {
        require(_isOperator(), "NotOperator");
        _;
    }

    function _isOperator() internal view returns (bool) {
        return operators[_msgSender()];
    }

    function setOperator(address account, bool _operator) external onlyOwner() {
        operators[account] = _operator;
    }

    modifier onlyOwner() {
        require(_msgSender() == _owner(), "NOT_AUTHORIZED");
        _;
    }

    function _owner() internal view returns (address adminAddress) {
        // solhint-disable-next-line security/no-inline-assembly
        assembly {
            adminAddress := sload(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103)
        }
    }

    function readOwner() external view returns (address) {
        return _owner();
    }

    function claimOwner() external {
        require(_owner() == 0x0000000000000000000000000000000000000000, "owner already set");
        _setOwner(_msgSender());
    }

    function _setOwner(address newOwner) internal {
        address previousOwner = _owner();
        // solhint-disable-next-line security/no-inline-assembly
        assembly {
            sstore(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103, newOwner)
        }
        emit OwnershipTransferred(previousOwner, newOwner);
    }

}
