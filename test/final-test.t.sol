// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Deployers} from "./utils/Deployers.sol";

import {PerpsHook} from "../src/PerpsHook.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {PositionFactory} from "../src/PositionFactory.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {MarketManager} from "../src/MarketManager.sol";
import {MarginAccount} from "../src/MarginAccount.sol";
import {FundingOracle} from "../src/FundingOracle.sol";
import {MockUSDC} from "./utils/mocks/MockUSDC.sol";
import {MockVETH} from "./utils/mocks/MockVETH.sol";

/// @title Complete Perpetual Trading Flow Test
/// @notice Tests the full flow: pool initialization → swaps → position management → funding
/// @dev REQUIRES MAINNET FORK: Run with --fork-url http://127.0.0.1:8545 (or your anvil fork URL)
///      This test uses real Chainlink price feeds from mainnet
contract FinalTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    
    /*//////////////////////////////////////////////////////////////
                                CONTRACTS
    //////////////////////////////////////////////////////////////*/
    
    PerpsHook public perpsHook;
    PositionManager public perpPositionManager;
    PositionFactory public positionFactory;
    PositionNFT public positionNFT;
    MarketManager public marketManager;
    MarginAccount public marginAccount;
    FundingOracle public fundingOracle;
    MockUSDC public usdc;
    MockVETH public veth;
    PoolSwapTest public poolSwapTest;
    
    /*//////////////////////////////////////////////////////////////
                            UNISWAP V4 SETUP
    //////////////////////////////////////////////////////////////*/
    
    Currency currency0; // Lower address token
    Currency currency1; // Higher address token
    
    PoolKey poolKey;
    PoolId poolId;
    
    /*//////////////////////////////////////////////////////////////
                                TEST USERS
    //////////////////////////////////////////////////////////////*/
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    
    uint256 public constant INITIAL_USDC_SUPPLY = 50000e6; // $50,000 USDC
    uint256 public constant INITIAL_VETH_SUPPLY = 25e18;   // 25 vETH
    uint256 public constant INITIAL_ETH_PRICE = 2000e18;   // $2,000
    uint256 public constant INITIAL_MARGIN = 20000e6;      // $20,000 initial margin
    
    bytes constant ZERO_BYTES = "";
    
    function setUp() public {
        console.log("=== SETTING UP COMPLETE PERPETUAL TRADING TEST ===");
        
        // Deploy all required Uniswap V4 artifacts
        deployArtifacts();
        
        // Deploy swap router for testing
        poolSwapTest = new PoolSwapTest(IPoolManager(address(poolManager)));
        
        // Deploy our tokens
        usdc = new MockUSDC();
        veth = new MockVETH();
        
        console.log("Deployed MockUSDC at:", address(usdc));
        console.log("Deployed MockVETH at:", address(veth));
        
        // Set up currencies (ordered by address)
        (currency0, currency1) = address(usdc) < address(veth) ? 
            (Currency.wrap(address(usdc)), Currency.wrap(address(veth))) :
            (Currency.wrap(address(veth)), Currency.wrap(address(usdc)));
        
        console.log("Currency0:", Currency.unwrap(currency0));
        console.log("Currency1:", Currency.unwrap(currency1));
        
        // Deploy our core contracts
        marginAccount = new MarginAccount(address(usdc));
        positionFactory = new PositionFactory(address(usdc), address(marginAccount));
        positionNFT = new PositionNFT();
        marketManager = new MarketManager();
        perpPositionManager = new PositionManager(
            address(positionFactory),
            address(positionNFT),
            address(marketManager)
        );
        
        // Setup position factory and NFT
        positionFactory.setPositionNFT(address(positionNFT));
        positionNFT.setFactory(address(positionFactory));
        
        // Deploy FundingOracle (no constructor params needed)
        fundingOracle = new FundingOracle();
        
        console.log("Deployed MarginAccount at:", address(marginAccount));
        console.log("Deployed PositionManager at:", address(perpPositionManager));
        console.log("Deployed FundingOracle at:", address(fundingOracle));
        
        // Setup authorizations (before transferring ownership)
        marginAccount.addAuthorizedContract(address(perpPositionManager));
        marginAccount.addAuthorizedContract(address(positionFactory));
        
        // Deploy the PerpsHook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.AFTER_SWAP_FLAG | 
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        
        bytes memory constructorArgs = abi.encode(
            poolManager, 
            perpPositionManager, 
            positionFactory,
            marginAccount, 
            fundingOracle,
            usdc,
            address(0) // _initialOwner (0 means use msg.sender)
        );
        deployCodeTo("PerpsHook.sol:PerpsHook", constructorArgs, flags);
        perpsHook = PerpsHook(flags);
        
        console.log("Deployed PerpsHook at:", address(perpsHook));
        
        // Additional authorizations for hook (before transferring ownership)
        marginAccount.addAuthorizedContract(address(perpsHook));
        perpPositionManager.addAuthorizedContract(address(perpsHook));
        positionFactory.addAuthorizedContract(address(perpsHook));
        
        // Transfer ownership to PositionManager (after all authorizations are done)
        positionFactory.transferOwnership(address(perpPositionManager));
        marketManager.transferOwnership(address(perpPositionManager));
        
        // Create the pool with our hook
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(perpsHook));
        poolId = poolKey.toId();
        
        // Register the market in PositionManager (REQUIRED for hook to work)
        bytes32 marketId = bytes32(PoolId.unwrap(poolId));
        address baseAsset = address(veth);
        address quoteAsset = address(usdc);
        
        perpPositionManager.addMarket(
            marketId,
            baseAsset,  // base asset (vETH)
            quoteAsset, // quote asset (USDC)
            address(poolManager)  // pool address
        );
        
        console.log("Registered market in PositionManager");
        
        // Add market to FundingOracle BEFORE initializing pool
        // Use mainnet Chainlink ETH/USD price feed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        // This requires running with --fork-url to mainnet
        address chainlinkETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        fundingOracle.addMarket(poolId, address(perpsHook), chainlinkETHUSD);
        console.log("Registered market in FundingOracle with Chainlink feed:", chainlinkETHUSD);
        
        // Initialize the pool (this will trigger afterInitialize hook)
        // afterInitialize needs getSpotPrice() which now has Chainlink feed
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        
        console.log("Initialized pool with ID:", uint256(PoolId.unwrap(poolId)));
        
        // Setup test users
        _setupTestUsers();
        
        console.log("=== SETUP COMPLETE ===");
        console.log("");
    }
    
    function _setupTestUsers() internal {
        // Mint tokens to users
        usdc.mint(alice, INITIAL_USDC_SUPPLY);
        usdc.mint(bob, INITIAL_USDC_SUPPLY);
        
        veth.mint(alice, INITIAL_VETH_SUPPLY);
        veth.mint(bob, INITIAL_VETH_SUPPLY);
        
        console.log("Minted tokens to test users");
        
        // Setup approvals for all users
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        
        for (uint i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            
            // Approve tokens for the hook, margin account, and swap router
            usdc.approve(address(perpsHook), type(uint256).max);
            usdc.approve(address(marginAccount), type(uint256).max);
            veth.approve(address(perpsHook), type(uint256).max);
            
            // Approve for pool manager and swap router
            usdc.approve(address(poolManager), type(uint256).max);
            veth.approve(address(poolManager), type(uint256).max);
            usdc.approve(address(poolSwapTest), type(uint256).max);
            veth.approve(address(poolSwapTest), type(uint256).max);
            
            // Deposit initial amounts to margin account
            marginAccount.deposit(INITIAL_MARGIN);
            
            vm.stopPrank();
        }
        
        console.log("Setup approvals and initial deposits for all users");
    }
    
    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function _logVAMMState(string memory description) internal view {
        console.log("--- VIRTUAL AMM STATE:", description, "---");
        
        PerpsHook.MarketState memory market = perpsHook.getMarketState(poolId);
        uint256 markPrice = perpsHook.getMarkPrice(poolId);
        
        console.log("Virtual Base Reserve:", market.virtualBase);
        console.log("Virtual Quote Reserve:", market.virtualQuote);
        console.log("K Constant:", market.k);
        console.log("Mark Price: $", markPrice / 1e18);
        console.log("Total Long OI:", market.totalLongOI / 1e18);
        console.log("Total Short OI:", market.totalShortOI / 1e18);
        console.log("Net Skew (Long - Short):", (int256(market.totalLongOI) - int256(market.totalShortOI)) / 1e18);
        console.log("Max OI Cap:", market.maxOICap / 1e18);
        console.log("Market Active:", market.isActive);
        console.log("Last Funding Time:", market.lastFundingTime);
        console.log("Global Funding Index:", market.globalFundingIndex);
        console.log("---");
    }
    
    function _logUserState(address user, string memory userName) internal view {
        console.log("--- USER STATE:", userName, "---");
        
        uint256 availableBalance = marginAccount.getAvailableBalance(user);
        uint256 lockedBalance = marginAccount.getLockedBalance(user);
        uint256 totalMargin = availableBalance + lockedBalance;
        
        console.log("Available Balance: $", availableBalance / 1e6);
        console.log("Locked Balance: $", lockedBalance / 1e6);
        console.log("Total Margin: $", totalMargin / 1e6);
        console.log("---");
    }
    
    function _executeSwap(
        address trader,
        PerpsHook.TradeParams memory trade,
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        bytes memory hookData = abi.encode(trade);
        
        // Calculate price limit (allow 10% slippage)
        (uint160 currentSqrtPrice,,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(currentSqrtPrice);
        uint160 sqrtPriceLimit = zeroForOne 
            ? TickMath.getSqrtPriceAtTick(currentTick - 1000)
            : TickMath.getSqrtPriceAtTick(currentTick + 1000);
        
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimit
        });
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        vm.prank(trader);
        poolSwapTest.swap(poolKey, params, testSettings, hookData);
    }
    
    /*//////////////////////////////////////////////////////////////
                            COMPLETE FLOW TEST
    //////////////////////////////////////////////////////////////*/
    
    function test_CompletePerpetualTradingFlow() public {
        console.log("=== COMPLETE PERPETUAL TRADING FLOW TEST ===");
        console.log("");
        
        // STEP 1: Show initial state
        console.log("STEP 1: Initial State");
        console.log("=====================");
        _logVAMMState("INITIAL STATE");
        _logUserState(alice, "ALICE");
        _logUserState(bob, "BOB");
        console.log("");
        
        // STEP 2: Alice opens 2x leveraged long position
        console.log("STEP 2: Alice Opens 2x Leveraged Long Position");
        console.log("================================================");
        
        uint256 aliceMargin = 5000e6;  // $5,000
        uint256 aliceLeverage = 2;     // 2x leverage
        uint256 alicePositionValue = aliceMargin * aliceLeverage; // $10,000
        uint256 markPrice = perpsHook.getMarkPrice(poolId);
        uint256 aliceEthSize = (alicePositionValue * 1e18) / markPrice; // ETH amount
        
        console.log("Alice's Trade Plan:");
        console.log("  Margin: $", aliceMargin / 1e6);
        console.log("  Leverage:", aliceLeverage, "x");
        console.log("  Position Value: $", alicePositionValue / 1e6);
        console.log("  Current Mark Price: $", markPrice / 1e18);
        console.log("  ETH Size:", aliceEthSize / 1e18);
        console.log("");
        
        PerpsHook.TradeParams memory aliceTrade = PerpsHook.TradeParams({
            operation: 0, // open_long
            tokenId: 0,   // new position
            size: aliceEthSize,
            margin: aliceMargin,
            maxSlippage: 500, // 5%
            trader: alice
        });
        
        // Determine swap direction: 
        // Long = buy base (vETH) = sell quote (USDC) for base
        // If currency0 = vETH, currency1 = USDC: long = sell USDC (currency1) for vETH (currency0) = zeroForOne = false
        // If currency0 = USDC, currency1 = vETH: long = sell USDC (currency0) for vETH (currency1) = zeroForOne = true
        bool aliceZeroForOne = Currency.unwrap(currency0) == address(usdc);
        // Use negative value for exact input (amountSpecified < 0 means exact input)
        // We're specifying input amount in USDC terms for a long position
        int256 aliceAmountSpecified = -int256(aliceMargin); // Negative = exact input of USDC
        
        console.log("Executing Alice's swap...");
        _executeSwap(alice, aliceTrade, aliceZeroForOne, aliceAmountSpecified);
        console.log("Alice's position opened successfully");
        console.log("");
        
        _logVAMMState("AFTER ALICE 2X LONG");
        _logUserState(alice, "ALICE AFTER TRADE");
        console.log("");
        
        // STEP 3: Bob opens 3x leveraged short position
        console.log("STEP 3: Bob Opens 3x Leveraged Short Position");
        console.log("==============================================");
        
        uint256 bobMargin = 4000e6;  // $4,000
        uint256 bobLeverage = 3;     // 3x leverage
        uint256 bobPositionValue = bobMargin * bobLeverage; // $12,000
        markPrice = perpsHook.getMarkPrice(poolId); // Get updated price
        uint256 bobEthSize = (bobPositionValue * 1e18) / markPrice; // ETH amount
        
        console.log("Bob's Trade Plan:");
        console.log("  Margin: $", bobMargin / 1e6);
        console.log("  Leverage:", bobLeverage, "x");
        console.log("  Position Value: $", bobPositionValue / 1e6);
        console.log("  Current Mark Price: $", markPrice / 1e18);
        console.log("  ETH Size (SHORT):", bobEthSize / 1e18);
        console.log("");
        
        PerpsHook.TradeParams memory bobTrade = PerpsHook.TradeParams({
            operation: 1, // open_short
            tokenId: 0,   // new position
            size: bobEthSize,
            margin: bobMargin,
            maxSlippage: 500, // 5%
            trader: bob
        });
        
        // Short = sell base (vETH) = sell vETH for USDC
        // If currency0 = vETH, currency1 = USDC: short = sell vETH (currency0) for USDC (currency1) = zeroForOne = true
        // If currency0 = USDC, currency1 = vETH: short = sell vETH (currency1) for USDC (currency0) = zeroForOne = false
        bool bobZeroForOne = Currency.unwrap(currency0) == address(veth);
        // Use negative value for exact input (amountSpecified < 0 means exact input)
        // For short, we're selling vETH, so we need to specify vETH amount
        // But the hook handles this via TradeParams.size, so we use a small trigger amount
        int256 bobAmountSpecified = -int256(bobEthSize / 100); // Negative = exact input of vETH
        
        console.log("Executing Bob's swap...");
        _executeSwap(bob, bobTrade, bobZeroForOne, bobAmountSpecified);
        console.log("Bob's position opened successfully");
        console.log("");
        
        _logVAMMState("AFTER BOB 3X SHORT");
        _logUserState(bob, "BOB AFTER TRADE");
        console.log("");
        
        // Show net market state
        PerpsHook.MarketState memory market = perpsHook.getMarketState(poolId);
        int256 netSkew = int256(market.totalLongOI) - int256(market.totalShortOI);
        console.log("NET MARKET POSITION:");
        console.log("  Total Long OI: $", market.totalLongOI / 1e18);
        console.log("  Total Short OI: $", market.totalShortOI / 1e18);
        console.log("  Net Skew: $", netSkew / 1e18);
        
        if (netSkew > 0) {
            console.log("  Market is NET LONG (more longs than shorts)");
        } else if (netSkew < 0) {
            console.log("  Market is NET SHORT (more shorts than longs)");
        } else {
            console.log("  Market is BALANCED (equal longs and shorts)");
        }
        console.log("");
        
        // STEP 4: Test funding mechanism
        console.log("STEP 4: Funding Rate Update");
        console.log("===========================");
        
        uint256 initialPrice = perpsHook.getMarkPrice(poolId);
        console.log("Initial Mark Price: $", initialPrice / 1e18);
        console.log("Initial Funding Index:", market.globalFundingIndex);
        console.log("");
        
        // Fast forward time to trigger funding update
        console.log("TIME PASSES: 1 hour later...");
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Update funding
        perpsHook.pokeFunding(poolId);
        
        market = perpsHook.getMarketState(poolId);
        uint256 updatedPrice = perpsHook.getMarkPrice(poolId);
        
        console.log("Updated Mark Price: $", updatedPrice / 1e18);
        console.log("Updated Funding Index:", market.globalFundingIndex);
        console.log("Last Funding Time:", market.lastFundingTime);
        console.log("");
        
        _logVAMMState("AFTER FUNDING UPDATE");
        console.log("");
        
        // STEP 5: Final state summary
        console.log("STEP 5: Final State Summary");
        console.log("============================");
        _logVAMMState("FINAL STATE");
        _logUserState(alice, "ALICE FINAL");
        _logUserState(bob, "BOB FINAL");
        
        console.log("=== COMPLETE PERPETUAL TRADING FLOW TEST COMPLETE ===");
    }
    
    /*//////////////////////////////////////////////////////////////
                            INDIVIDUAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_PoolInitialization() public {
        console.log("=== TESTING POOL INITIALIZATION ===");
        
        // Verify pool was initialized
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertTrue(sqrtPriceX96 > 0, "Pool should be initialized");
        
        // Verify market state was set up
        PerpsHook.MarketState memory market = perpsHook.getMarketState(poolId);
        assertTrue(market.isActive, "Market should be active");
        assertGt(market.virtualBase, 0, "Virtual base should be > 0");
        assertGt(market.virtualQuote, 0, "Virtual quote should be > 0");
        assertGt(market.k, 0, "K constant should be > 0");
        
        uint256 markPrice = perpsHook.getMarkPrice(poolId);
        assertGt(markPrice, 0, "Mark price should be > 0");
        
        console.log("Pool initialized successfully");
        console.log("Virtual Base:", market.virtualBase);
        console.log("Virtual Quote:", market.virtualQuote);
        console.log("Mark Price: $", markPrice / 1e18);
    }
    
    function test_OpenLongPosition() public {
        console.log("=== TESTING OPEN LONG POSITION ===");
        
        uint256 margin = 1000e6; // $1,000
        uint256 markPrice = perpsHook.getMarkPrice(poolId);
        uint256 ethSize = (margin * 2 * 1e18) / markPrice; // 2x leverage
        
        PerpsHook.TradeParams memory trade = PerpsHook.TradeParams({
            operation: 0, // open_long
            tokenId: 0,
            size: ethSize,
            margin: margin,
            maxSlippage: 500,
            trader: alice
        });
        
        bool zeroForOne = Currency.unwrap(currency0) == address(usdc);
        _executeSwap(alice, trade, zeroForOne, -int256(margin)); // Negative = exact input of USDC
        
        // Verify position was created
        PerpsHook.MarketState memory market = perpsHook.getMarketState(poolId);
        assertGt(market.totalLongOI, 0, "Long OI should increase");
        
        console.log("Long position opened successfully");
        console.log("Total Long OI:", market.totalLongOI / 1e18);
    }
    
    function test_OpenShortPosition() public {
        console.log("=== TESTING OPEN SHORT POSITION ===");
        
        uint256 margin = 1000e6; // $1,000
        uint256 markPrice = perpsHook.getMarkPrice(poolId);
        uint256 ethSize = (margin * 2 * 1e18) / markPrice; // 2x leverage
        
        PerpsHook.TradeParams memory trade = PerpsHook.TradeParams({
            operation: 1, // open_short
            tokenId: 0,
            size: ethSize,
            margin: margin,
            maxSlippage: 500,
            trader: bob
        });
        
        bool zeroForOne = Currency.unwrap(currency0) == address(veth);
        _executeSwap(bob, trade, zeroForOne, -int256(ethSize / 100)); // Negative = exact input of vETH
        
        // Verify position was created
        PerpsHook.MarketState memory market = perpsHook.getMarketState(poolId);
        assertGt(market.totalShortOI, 0, "Short OI should increase");
        
        console.log("Short position opened successfully");
        console.log("Total Short OI:", market.totalShortOI / 1e18);
    }
    
    function test_FundingMechanism() public {
        console.log("=== TESTING FUNDING MECHANISM ===");
        
        PerpsHook.MarketState memory initialMarket = perpsHook.getMarketState(poolId);
        int256 initialFundingIndex = initialMarket.globalFundingIndex;
        uint256 initialTime = initialMarket.lastFundingTime;
        
        // Fast forward time
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Trigger funding update
        perpsHook.pokeFunding(poolId);
        
        PerpsHook.MarketState memory updatedMarket = perpsHook.getMarketState(poolId);
        
        assertGt(updatedMarket.lastFundingTime, initialTime, "Funding time should update");
        assertTrue(
            updatedMarket.globalFundingIndex != initialFundingIndex || 
            updatedMarket.totalLongOI == 0 && updatedMarket.totalShortOI == 0,
            "Funding index should update if there's OI"
        );
        
        console.log("Funding mechanism working correctly");
        console.log("Initial Funding Index:", initialFundingIndex);
        console.log("Updated Funding Index:", updatedMarket.globalFundingIndex);
    }
}

