// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {PositionLib} from "./libraries/PositionLib.sol";
import {PositionManager} from "./PositionManager.sol";
import {PositionFactory} from "./PositionFactory.sol";
import {MarginAccount} from "./MarginAccount.sol";
import {FundingOracle} from "./FundingOracle.sol";


contract PerpsHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PriceBandExceeded();
    error OpenInterestCapExceeded();
    error InsufficientMargin();
    error InvalidOperation();
    error LiquidityOperationsDisabled();
    error UnauthorizedCaller();
    error InvalidPrice();
    error MarketNotInitialized();
    error MissingHookData();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketInitialized(PoolId indexed poolId, uint256 virtualBase, uint256 virtualQuote, uint256 k);
    event VirtualReservesUpdated(PoolId indexed poolId, uint256 virtualBase, uint256 virtualQuote);
    event FundingIndexUpdated(PoolId indexed poolId, int256 fundingIndex);
    event PositionOpened(PoolId indexed poolId, address indexed trader, uint256 tokenId, int256 size, uint256 margin);
    event PositionClosed(PoolId indexed poolId, address indexed trader, uint256 tokenId, int256 pnl);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct MarketState {
        uint256 virtualBase;      // Virtual base reserve (e.g., ETH in wei)
        uint256 virtualQuote;     // Virtual quote reserve (USDC in 6 decimals)
        uint256 k;                // Constant product K = virtualBase * virtualQuote
        int256 globalFundingIndex; // Global funding index for this market
        uint256 totalLongOI;      // Total long open interest (in quote terms)
        uint256 totalShortOI;     // Total short open interest (in quote terms)
        uint256 maxOICap;         // Maximum open interest cap
        uint256 lastFundingTime;  // Last time funding was updated
        address spotPriceFeed;    // Deprecated: kept for storage layout compatibility
        bool isActive;            // Market active status
    }

    struct TradeParams {
        uint8 operation;          // 0=open_long, 1=open_short, 2=close_long, 3=close_short, 4=add_margin, 5=remove_margin
        uint256 tokenId;          // Position NFT token ID (0 for new positions)
        uint256 size;             // Trade size in base asset terms (18 decimals)
        uint256 margin;           // Margin amount (6 decimals for USDC)
        uint256 maxSlippage;      // Maximum acceptable slippage (basis points)
        address trader;           // Trader address
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    PositionManager public immutable positionManager;
    PositionFactory public immutable positionFactory;
    MarginAccount public immutable marginAccount;
    FundingOracle public immutable fundingOracle;
    IERC20 public immutable USDC;
    
    // Market configurations
    mapping(PoolId => MarketState) public markets;
    
    // Risk parameters
    uint256 public constant MAX_LEVERAGE = 20e18;              // 20x leverage (18 decimals)
    uint256 public constant MIN_MARGIN = 10e6;                 // $10 minimum margin (6 decimals)
    uint256 public constant MAX_DEVIATION_BPS = 500;           // 5% max price deviation
    uint256 public constant TRADE_FEE_BPS = 30;               // 0.3% base trade fee
    uint256 public constant FUNDING_RATE_PRECISION = 1e18;     // Funding rate precision
    uint256 public constant FUNDING_INTERVAL = 1 hours;        // Funding update interval

    // Owner for administrative functions
    address public owner;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedCaller();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager, PositionManager _positionManager, PositionFactory _positionFactory, MarginAccount _marginAccount, FundingOracle _fundingOracle, IERC20 _usdc, address _initialOwner) BaseHook(_poolManager) {
        positionManager = _positionManager;
        positionFactory = _positionFactory;
        marginAccount = _marginAccount;
        fundingOracle = _fundingOracle;
        USDC = _usdc;
        owner = _initialOwner != address(0) ? _initialOwner : msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,  // Critical: Enable custom delta returns for vAMM pricing
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                            HOOK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        
        // Get initial price from Chainlink oracle - required to work
        uint256 initialPrice = _getInitialPrice(poolId);
        uint256 virtualLiquidity = 1000000e6; // 1M USDC
        uint256 maxOICap = 10000000e6; // 10M USDC
        
        // Calculate virtual reserves based on initial price and liquidity
        // For ETH/USDC: virtualQuote = 1M USDC (in 6 decimals), virtualBase = liquidity/price (in 18 decimals)
        uint256 virtualQuote = virtualLiquidity; // e.g., 1M USDC (1e12 in 6 decimals)
        uint256 virtualBase = (virtualLiquidity * 1e30) / initialPrice; // Convert USDC to 18 decimals then divide by price
        uint256 k = virtualBase * virtualQuote;
        
        markets[poolId] = MarketState({
            virtualBase: virtualBase,
            virtualQuote: virtualQuote,
            k: k,
            globalFundingIndex: 0,
            totalLongOI: 0,
            totalShortOI: 0,
            maxOICap: maxOICap,
            lastFundingTime: block.timestamp,
            spotPriceFeed: address(0), // Deprecated field, kept for storage layout
            isActive: true
        });

        emit MarketInitialized(poolId, virtualBase, virtualQuote, k);
        return BaseHook.afterInitialize.selector;
    }

    /// @notice Get initial price for market initialization
    /// @param poolId Pool identifier 
    /// @return price Initial price in 18 decimals
    /// @dev Reverts if oracle fails or returns invalid price
    function _getInitialPrice(PoolId poolId) internal view returns (uint256 price) {
        uint256 spotPrice = fundingOracle.getSpotPrice(poolId);
        if (spotPrice == 0) revert InvalidPrice();
        if (spotPrice < 1e18 || spotPrice > 100000e18) revert InvalidPrice();
        return spotPrice;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        MarketState storage market = markets[poolId];
        
        if (!market.isActive) revert InvalidOperation();
        
        // Require hookData for all swaps - no regular swaps allowed
        if (hookData.length == 0) revert MissingHookData();
        
        // Decode trade parameters
        TradeParams memory trade = abi.decode(hookData, (TradeParams));
        
        // Update funding if enough time has passed
        _updateFundingIfNeeded(poolId);
        
        // Perform validations and calculations
        _validateTrade(poolId, trade, params);
        
        // For position operations, we need to implement custom vAMM pricing curve
        if (trade.operation <= 3) { // Position operations
            return _executeVAMMPricing(poolId, key, params, trade, sender);
        }
        
        // For non-position operations (margin adjustments), allow normal processing
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address /* sender */, PoolKey calldata key, SwapParams calldata params, BalanceDelta /* delta */, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        
        // Require hookData for all swaps
        if (hookData.length == 0) revert MissingHookData();
        
        // Decode trade parameters
        TradeParams memory trade = abi.decode(hookData, (TradeParams));
        
        // Execute perp-specific logic based on operation type
        if (trade.operation == 0 || trade.operation == 1) { // Open long/short
            _executeOpenPosition(poolId, trade, params);
        } else if (trade.operation == 2 || trade.operation == 3) { // Close long/short
            _executeClosePosition(poolId, trade, params);
        } else if (trade.operation == 4) { // Add margin
            _executeAddMargin(trade);
        } else if (trade.operation == 5) { // Remove margin
            _executeRemoveMargin(trade);
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        // Disable all liquidity operations
        revert LiquidityOperationsDisabled();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        // Disable all liquidity operations
        revert LiquidityOperationsDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                        VAMM PRICING IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute vAMM pricing curve for perp trades
    /// @param poolId Pool identifier
    /// @param key Pool key
    /// @param params Swap parameters
    /// @param trade Trade parameters
    /// @return Selector, delta, and dynamic fee
    function _executeVAMMPricing(PoolId poolId, PoolKey calldata key, SwapParams calldata params, TradeParams memory trade, address sender)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get mark price (mean of vAMM and spot price) 
        uint256 markPrice = _getMarkPrice(poolId);
        
        // Calculate dynamic fee including funding adjustment
        bool isLong = (trade.operation == 0 || trade.operation == 2);
        int256 fundingAdjustment = _calculateFundingFeeAdjustment(poolId, isLong);
        int256 feeSum = int256(TRADE_FEE_BPS) + fundingAdjustment;
        
        // Ensure fee is within valid range for uint24
        if (feeSum < 0) feeSum = 0;
        if (feeSum > 16777215) feeSum = 16777215; // type(uint24).max
        uint24 dynamicFee = uint24(uint256(feeSum));
        
        // Execute the custom vAMM swap with proper currency settlement
        BeforeSwapDelta delta = _executeVAMMSwap(key, params, markPrice, sender);
        
        return (BaseHook.beforeSwap.selector, delta, dynamicFee);
    }

    /// @notice Execute vAMM swap with proper currency settlement
    /// @param key Pool key
    /// @param params Swap parameters  
    /// @param markPrice Current mark price
    /// @param sender Address of the swap sender (user)
    /// @return BeforeSwapDelta for the executed swap
    function _executeVAMMSwap(PoolKey calldata key, SwapParams calldata params, uint256 markPrice, address sender)
        internal
        returns (BeforeSwapDelta)
    {
        bool exactInput = params.amountSpecified < 0;
        bool zeroForOne = params.zeroForOne;
        
        // Determine input and output currencies
        (Currency inputCurrency, Currency outputCurrency) = zeroForOne 
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
            
        if (exactInput) {
            uint256 inputAmount = uint256(-params.amountSpecified);
            uint256 outputAmount;
            
            if (zeroForOne) {
                // Selling currency0 (ETH) for currency1 (USDC)
                outputAmount = (inputAmount * markPrice) / 1e30;
            } else {
                // Buying currency0 (ETH) with currency1 (USDC)
                outputAmount = (inputAmount * 1e30) / markPrice;
            }
            
            // Return delta - PoolManager will handle token transfers
            // The user will settle by transferring tokens to PoolManager
            // We'll handle position logic in afterSwap after tokens are settled
            return toBeforeSwapDelta(int128(-params.amountSpecified), int128(int256(outputAmount)));
        } else {
            uint256 outputAmount = uint256(params.amountSpecified);
            uint256 inputAmount;
            
            if (zeroForOne) {
                // User wants specific USDC, calculate ETH input
                inputAmount = (outputAmount * 1e30) / markPrice;
            } else {
                // User wants specific ETH, calculate USDC input
                inputAmount = (outputAmount * markPrice) / 1e30;
            }
            
            // Return delta - PoolManager will handle token transfers
            // The user will settle by transferring tokens to PoolManager
            // We'll handle position logic in afterSwap after tokens are settled
            return toBeforeSwapDelta(-int128(int256(inputAmount)), int128(params.amountSpecified));
        }
    }

    /// @notice Settle a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param amount Amount to settle
    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateTrade(PoolId poolId, TradeParams memory trade, SwapParams calldata /* params */) internal view {
        MarketState storage market = markets[poolId];
        
        // Price band check - requires oracle to work
        uint256 currentMarkPrice = _getMarkPrice(poolId);
        uint256 spotPrice = fundingOracle.getSpotPrice(poolId);
        
        if (spotPrice == 0) revert InvalidPrice();
        
        uint256 deviation = currentMarkPrice > spotPrice ? 
            ((currentMarkPrice - spotPrice) * 10000) / spotPrice :
            ((spotPrice - currentMarkPrice) * 10000) / spotPrice;
        
        if (deviation > MAX_DEVIATION_BPS) {
            revert PriceBandExceeded();
        }
        
        // Open interest cap check for new positions
        if (trade.operation <= 1) { // Opening positions
            uint256 notionalSize = (trade.size * currentMarkPrice) / 1e18;  // This gives us USDC in 18 decimals
            notionalSize = notionalSize / 1e12;  // Convert to 6 decimals to match USDC
            
            if (trade.operation == 0) { // Long
                if (market.totalLongOI + notionalSize > market.maxOICap) {
                    revert OpenInterestCapExceeded();
                }
            } else { // Short
                if (market.totalShortOI + notionalSize > market.maxOICap) {
                    revert OpenInterestCapExceeded();
                }
            }
        }
        
        // Margin requirement check for position operations
        if (trade.operation <= 1 && trade.margin > 0) {
            uint256 requiredMargin = _calculateRequiredMargin(trade.size, currentMarkPrice);
            
            if (trade.margin < requiredMargin) {
                revert InsufficientMargin();
            }
        }
    }


    function _executeOpenPosition(PoolId poolId, TradeParams memory trade, SwapParams calldata /* params */) internal {
        MarketState storage market = markets[poolId];
        
        // Calculate entry price and update virtual reserves
        uint256 entryPrice = _getMarkPrice(poolId);
        bool isLong = (trade.operation == 0);
        
        // Update virtual reserves
        if (isLong) {
            uint256 quoteIn = (trade.size * entryPrice) / 1e18;
            market.virtualQuote += quoteIn;
            market.virtualBase = market.k / market.virtualQuote;
            market.totalLongOI += quoteIn / 1e12;  // Convert to 6 decimals
        } else {
            market.virtualBase += trade.size;
            market.virtualQuote = market.k / market.virtualBase;
            uint256 shortNotional = (trade.size * entryPrice) / 1e18;
            market.totalShortOI += shortNotional / 1e12;  // Convert to 6 decimals
        }
        
        // Create or update position via PositionManager
        bytes32 marketId = bytes32(PoolId.unwrap(poolId));
        
        if (trade.tokenId == 0) {
            // New position - Margin should already be deposited by the caller
            // The hook assumes margin is already in the MarginAccount
            
            // Create position using the hook-specific function
            // PositionManager will lock the margin from the user's free balance
            uint256 tokenId = positionManager.openPositionFor(
                trade.trader, // The actual user
                marketId,
                isLong ? int256(trade.size) : -int256(trade.size),
                entryPrice,
                trade.margin
            );
            
            emit PositionOpened(poolId, trade.trader, tokenId, 
                isLong ? int256(trade.size) : -int256(trade.size), trade.margin);
        } else {
            // Increase existing position size
            // Get current position details
            PositionLib.Position memory position = positionManager.getPosition(trade.tokenId);
            
            // Validate position exists and belongs to trader
            if (position.owner != trade.trader) revert InvalidOperation();
            
            // Validate position direction matches trade direction
            bool positionIsLong = position.sizeBase > 0;
            if (positionIsLong != isLong) revert InvalidOperation(); // Cannot change direction
            
            // Calculate new total size and margin
            uint256 currentAbsoluteSize = uint256(positionIsLong ? position.sizeBase : -position.sizeBase);
            uint256 newAbsoluteSize = currentAbsoluteSize + trade.size;
            int256 newSizeBase = isLong ? int256(newAbsoluteSize) : -int256(newAbsoluteSize);
            uint256 newMargin = uint256(position.margin) + trade.margin;
            
            // Update position in PositionManager
            bool success = positionManager.updatePositionFor(
                trade.trader,
                trade.tokenId,
                newSizeBase,
                newMargin
            );
            
            if (!success) revert InvalidOperation();
            
            emit PositionOpened(poolId, trade.trader, trade.tokenId, 
                newSizeBase, newMargin);
        }
        
        emit VirtualReservesUpdated(poolId, market.virtualBase, market.virtualQuote);
    }

    function _executeClosePosition(PoolId poolId, TradeParams memory trade, SwapParams calldata /* params */) internal {
        MarketState storage market = markets[poolId];
        
        // Get position details
        PositionLib.Position memory position = positionManager.getPosition(trade.tokenId);
        
        // Calculate exit price and PnL
        uint256 exitPrice = _getMarkPrice(poolId);
        bool wasLong = position.sizeBase > 0;
        uint256 positionSize = uint256(wasLong ? position.sizeBase : -position.sizeBase);
        
        // Update virtual reserves (opposite of opening)
        if (wasLong) {
            uint256 quoteOut = (positionSize * exitPrice) / 1e18;
            market.virtualQuote -= quoteOut;
            market.virtualBase = market.k / market.virtualQuote;
            market.totalLongOI -= quoteOut / 1e12;  // Convert to 6 decimals
        } else {
            market.virtualBase -= positionSize;
            market.virtualQuote = market.k / market.virtualBase;
            uint256 shortNotional = (positionSize * exitPrice) / 1e18;
            market.totalShortOI -= shortNotional / 1e12;  // Convert to 6 decimals
        }
        
        // Close position via PositionManager
        positionManager.closePosition(trade.tokenId, exitPrice);
        
        emit PositionClosed(poolId, trade.trader, trade.tokenId, 0); // PnL calculated in PositionManager
        emit VirtualReservesUpdated(poolId, market.virtualBase, market.virtualQuote);
    }

    function _executeAddMargin(TradeParams memory trade) internal {
        // Margin should already be deposited by the caller
        // Add margin to position (PositionManager will lock it from free balance)
        positionManager.addMargin(trade.tokenId, trade.margin);
    }

    function _executeRemoveMargin(TradeParams memory trade) internal {
        // Remove margin from position (PositionManager will unlock it to free balance)
        positionManager.removeMargin(trade.tokenId, trade.margin);
    }

    function _updateFundingIfNeeded(PoolId poolId) internal {
        MarketState storage market = markets[poolId];
        
        if (block.timestamp >= market.lastFundingTime + FUNDING_INTERVAL) {
            int256 fundingRate = _calculateFundingRate(poolId);
            market.globalFundingIndex += fundingRate;
            market.lastFundingTime = block.timestamp;
            
            emit FundingIndexUpdated(poolId, market.globalFundingIndex);
        }
    }

    function _calculateFundingRate(PoolId poolId) internal view returns (int256) {
        // Get mark price and spot price from FundingOracle
        uint256 markPrice = _getMarkPrice(poolId);
        uint256 spotPrice = fundingOracle.getSpotPrice(poolId);
        
        if (spotPrice == 0) revert InvalidPrice();
        
        // Calculate premium: (mark - spot) / spot
        int256 premium = (int256(markPrice) - int256(spotPrice)) * int256(FUNDING_RATE_PRECISION) / int256(spotPrice);
        
        // Apply time factor (1 hour = 1/8760 of year)
        int256 fundingRate = premium / 8760; // Simplified for hourly funding
        
        return fundingRate;
    }

    function _calculateFundingFeeAdjustment(PoolId poolId, bool isLong) internal view returns (int256) {
        // If funding rate is positive (perp > spot), longs pay more, shorts pay less
        int256 fundingRate = _calculateFundingRate(poolId);
        int256 adjustment = isLong ? fundingRate / 100 : -fundingRate / 100; // Convert to basis points
        
        return adjustment;
    }

    function _calculateRequiredMargin(uint256 size, uint256 price) internal pure returns (uint256) {
        uint256 notional = (size * price) / 1e18;  // This gives USDC in 18 decimals
        notional = notional / 1e12;  // Convert to 6 decimals to match USDC
        uint256 marginRequired = notional / (MAX_LEVERAGE / 1e18);
        return marginRequired < MIN_MARGIN ? MIN_MARGIN : marginRequired;
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate mean price between vAMM and spot price
    /// @param vammPrice Virtual AMM price
    /// @param spotPrice Spot price from external oracle
    /// @return Mean price
    /// @dev Reverts if spot price is invalid or deviates too much
    function _calculateMeanPrice(uint256 vammPrice, uint256 spotPrice) internal pure returns (uint256) {
        // Validate spot price is reasonable (between $1 and $100,000)
        if (spotPrice < 1e18 || spotPrice > 100000e18) {
            revert InvalidPrice();
        }
        
        // Check for extreme deviation (more than 50% difference)
        uint256 maxPrice = vammPrice > spotPrice ? vammPrice : spotPrice;
        uint256 minPrice = vammPrice > spotPrice ? spotPrice : vammPrice;
        
        // If prices differ by more than 50%, revert (potential oracle manipulation)
        if ((maxPrice - minPrice) * 100 / minPrice > 50) {
            revert PriceBandExceeded();
        }
        
        // Return arithmetic mean
        return (vammPrice + spotPrice) / 2;
    }

    function _getMarkPrice(PoolId poolId) internal view returns (uint256) {
        MarketState storage market = markets[poolId];
        
        // Validate market is initialized
        if (market.virtualBase == 0) revert MarketNotInitialized();
        
        // Get vAMM virtual price
        // virtualQuote is in 6 decimals (USDC), virtualBase is in 18 decimals (ETH)
        // Price should be in 18 decimals: (virtualQuote * 1e30) / virtualBase
        // We multiply by 1e30 = 1e12 (convert USDC 6->18 decimals) * 1e18 (price precision)
        uint256 vammPrice = (market.virtualQuote * 1e30) / market.virtualBase;
        
        // Get spot price from FundingOracle - required to work
        uint256 spotPrice = fundingOracle.getSpotPrice(poolId);
        if (spotPrice == 0) revert InvalidPrice();
        
        // Return mean of vAMM price and spot price with validation
        return _calculateMeanPrice(vammPrice, spotPrice);
    }


    function getMarkPrice(PoolId poolId) external view returns (uint256) {
        return _getMarkPrice(poolId);
    }

    /// @notice Get both vAMM price and spot price for transparency
    /// @param poolId Pool identifier
    /// @return vammPrice Current vAMM virtual price
    /// @return spotPrice Current spot price from oracle
    /// @return meanPrice Current mean price used for trading
    /// @dev Reverts if oracle fails or market not initialized
    function getPriceBreakdown(PoolId poolId) external view returns (uint256 vammPrice, uint256 spotPrice, uint256 meanPrice) {
        MarketState storage market = markets[poolId];
        
        if (market.virtualBase == 0) revert MarketNotInitialized();
        
        vammPrice = (market.virtualQuote * 1e30) / market.virtualBase;
        spotPrice = fundingOracle.getSpotPrice(poolId);
        
        if (spotPrice == 0) revert InvalidPrice();
        
        meanPrice = _calculateMeanPrice(vammPrice, spotPrice);
    }

    function getMarketState(PoolId poolId) external view returns (MarketState memory) {
        return markets[poolId];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pokeFunding(PoolId poolId) external {
        _updateFundingIfNeeded(poolId);
    }

    function setMarketStatus(PoolId poolId, bool isActive) external onlyOwner {
        markets[poolId].isActive = isActive;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}

