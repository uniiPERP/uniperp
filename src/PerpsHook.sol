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
    
    // Store calculated trade sizes between beforeSwap and afterSwap
    mapping(bytes32 => uint256) private tradeSizes;
    
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
            afterSwapReturnDelta: false, // Not needed - we only do virtual accounting, no token transfers
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
        
        // For position operations, lock margin before swap (operations 0 and 1 are opening positions)
        if (trade.operation <= 1 && trade.margin > 0) {
            marginAccount.lockMargin(trade.trader, trade.margin);
        }
        
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
        
        // Use trade.size directly from TradeParams (user-specified position size)
        // The virtual swap in beforeSwap updates reserves, but we use the user-specified size for OI tracking
        // Only use calculatedSize if trade.size is 0 (fallback)
        if (trade.operation <= 3 && trade.size == 0) {
            bytes32 swapKey = keccak256(abi.encodePacked(poolId, trade.trader, trade.operation, trade.tokenId, block.number));
            uint256 calculatedSize = tradeSizes[swapKey];
            if (calculatedSize > 0) {
                trade.size = calculatedSize;
                delete tradeSizes[swapKey]; // Clean up
            }
        }
        
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
        
        // Return zero delta - we only do virtual accounting, no token transfers
        // Margin is already locked, virtual reserves already updated
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
        BeforeSwapDelta delta = _executeVAMMSwap(poolId, key, params, trade);
        
        return (BaseHook.beforeSwap.selector, delta, dynamicFee);
    }

    /// @notice Execute vAMM swap using constant product formula
    /// @param poolId Pool identifier
    /// @param params Swap parameters  
    /// @param trade Trade parameters (contains operation type)
    /// @return BeforeSwapDelta for the executed swap
    function _executeVAMMSwap(PoolId poolId, PoolKey calldata key, SwapParams calldata params, TradeParams memory trade)
        internal
        returns (BeforeSwapDelta)
    {
        MarketState storage market = markets[poolId];
        bool exactInput = params.amountSpecified < 0;
        bool isLong = (trade.operation == 0 || trade.operation == 2);
        bool isClose = (trade.operation == 2 || trade.operation == 3);
        
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 calculatedSize;
        
        if (exactInput) {
            inputAmount = uint256(-params.amountSpecified);
            
            if (isLong && !isClose) {
                // Opening Long: User adds USDC (quote), gets ETH (base)
                // Update virtual reserves using constant product: K = base * quote
                uint256 oldBase = market.virtualBase;
                market.virtualQuote += inputAmount; // Add USDC to quote reserve
                market.virtualBase = market.k / market.virtualQuote; // Calculate new base
                outputAmount = oldBase - market.virtualBase; // ETH "bought"
                calculatedSize = outputAmount; // Position size in ETH
                
            } else if (!isLong && !isClose) {
                // Opening Short: User adds ETH (base), gets USDC (quote)
                uint256 oldQuote = market.virtualQuote;
                market.virtualBase += inputAmount; // Add ETH to base reserve
                market.virtualQuote = market.k / market.virtualBase; // Calculate new quote
                outputAmount = oldQuote - market.virtualQuote; // USDC "bought"
                calculatedSize = inputAmount; // Position size in ETH
                
            } else if (isClose && isLong) {
                // Closing Long: User adds ETH (base), gets USDC (quote)
                // Reverse of opening long
                uint256 oldQuote = market.virtualQuote;
                market.virtualBase += inputAmount; // Add ETH back to base
                market.virtualQuote = market.k / market.virtualBase;
                outputAmount = market.virtualQuote - oldQuote; // USDC "received"
                calculatedSize = inputAmount;
                
            } else { // isClose && !isLong
                // Closing Short: User adds USDC (quote), gets ETH (base)
                // Reverse of opening short
                uint256 oldBase = market.virtualBase;
                market.virtualQuote += inputAmount; // Add USDC back to quote
                market.virtualBase = market.k / market.virtualQuote;
                outputAmount = market.virtualBase - oldBase; // ETH "received"
                calculatedSize = outputAmount;
            }
            
        } else {
            // Exact output - calculate input needed
            outputAmount = uint256(params.amountSpecified);
            
            if (isLong && !isClose) {
                // Opening Long: User wants specific ETH, calculate USDC needed
                uint256 oldBase = market.virtualBase;
                uint256 newBase = oldBase - outputAmount; // Remove ETH from base
                uint256 newQuote = market.k / newBase;
                inputAmount = newQuote - market.virtualQuote; // USDC needed
                market.virtualQuote = newQuote;
                market.virtualBase = newBase;
                calculatedSize = outputAmount;
                
            } else if (!isLong && !isClose) {
                // Opening Short: User wants specific USDC, calculate ETH needed
                uint256 oldQuote = market.virtualQuote;
                uint256 newQuote = oldQuote - outputAmount; // Remove USDC from quote
                uint256 newBase = market.k / newQuote;
                inputAmount = newBase - market.virtualBase; // ETH needed
                market.virtualBase = newBase;
                market.virtualQuote = newQuote;
                calculatedSize = inputAmount;
                
            } else if (isClose && isLong) {
                // Closing Long: User wants specific USDC, calculate ETH needed
                uint256 oldQuote = market.virtualQuote;
                uint256 newQuote = oldQuote + outputAmount; // Add USDC to quote
                uint256 newBase = market.k / newQuote;
                inputAmount = market.virtualBase - newBase; // ETH needed
                market.virtualBase = newBase;
                market.virtualQuote = newQuote;
                calculatedSize = inputAmount;
                
            } else { // isClose && !isLong
                // Closing Short: User wants specific ETH, calculate USDC needed
                uint256 oldBase = market.virtualBase;
                uint256 newBase = oldBase + outputAmount; // Add ETH to base
                uint256 newQuote = market.k / newBase;
                inputAmount = newQuote - market.virtualQuote; // USDC needed
                market.virtualBase = newBase;
                market.virtualQuote = newQuote;
                calculatedSize = outputAmount;
            }
        }
        
        // Store calculated trade size for afterSwap (using trader address and operation as key)
        bytes32 swapKey = keccak256(abi.encodePacked(poolId, trade.trader, trade.operation, trade.tokenId, block.number));
        tradeSizes[swapKey] = calculatedSize;
        
        // Emit reserve update event
        emit VirtualReservesUpdated(poolId, market.virtualBase, market.virtualQuote);
        
        // For virtual AMM: Cancel the main pool swap completely (amountToSwap = 0)
        // The BeforeSwapDelta modifies amountToSwap: amountToSwap = params.amountSpecified + hookDeltaSpecified
        // We want amountToSwap = 0, so hookDeltaSpecified = -params.amountSpecified
        // This skips the core swap logic in PoolManager (see Pool.sol line 320)
        // We only do virtual accounting - no token transfers needed (margin already locked)
        int128 cancelDelta = -int128(params.amountSpecified);
        
        // Handle the delta created by BeforeSwapDelta to avoid CurrencyNotSettled error
        // Since we're canceling the swap, we need to take the specified amount from the pool
        // (similar to BaseAsyncSwap) so the hook receives it and the user doesn't owe anything
        // The tokens remain in the hook's pool balance (virtual accounting only)
        if (cancelDelta > 0) {
            // Positive delta means hook receives tokens (take from pool)
            Currency specifiedCurrency = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
            uint256 amount = uint256(uint128(cancelDelta));
            // Take tokens from pool to hook's balance (virtual accounting - tokens stay in pool)
            specifiedCurrency.take(poolManager, address(this), amount, true);
        } else if (cancelDelta < 0) {
            // Negative delta means hook pays tokens (settle to pool)
            // But we don't have tokens to settle since margin is already locked
            // For exact output swaps, we would need to settle, but since we're only doing
            // virtual accounting, we should handle this differently
            // For now, we'll skip settlement and see if this causes issues
        }
        
        // Return delta that cancels the main pool swap (virtual accounting only, no token transfers)
        return toBeforeSwapDelta(cancelDelta, 0);
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
        
        // Calculate entry price (virtual reserves already updated in beforeSwap)
        uint256 entryPrice = _getMarkPrice(poolId);
        bool isLong = (trade.operation == 0);
        
        // Update open interest (virtual reserves already updated in _executeVAMMSwap)
        if (isLong) {
            uint256 quoteIn = (trade.size * entryPrice) / 1e18;
            market.totalLongOI += quoteIn / 1e12;  // Convert to 6 decimals
        } else {
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
    }

    function _executeClosePosition(PoolId poolId, TradeParams memory trade, SwapParams calldata /* params */) internal {
        MarketState storage market = markets[poolId];
        
        // Get position details
        PositionLib.Position memory position = positionManager.getPosition(trade.tokenId);
        
        // Calculate exit price and PnL (virtual reserves already updated in _executeVAMMSwap)
        uint256 exitPrice = _getMarkPrice(poolId);
        bool wasLong = position.sizeBase > 0;
        uint256 positionSize = uint256(wasLong ? position.sizeBase : -position.sizeBase);
        
        // Update open interest (virtual reserves already updated in _executeVAMMSwap)
        if (wasLong) {
            uint256 quoteOut = (positionSize * exitPrice) / 1e18;
            market.totalLongOI -= quoteOut / 1e12;  // Convert to 6 decimals
        } else {
            uint256 shortNotional = (positionSize * exitPrice) / 1e18;
            market.totalShortOI -= shortNotional / 1e12;  // Convert to 6 decimals
        }
        
        // Close position via PositionManager
        positionManager.closePosition(trade.tokenId, exitPrice);
        
        emit PositionClosed(poolId, trade.trader, trade.tokenId, 0); // PnL calculated in PositionManager
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

