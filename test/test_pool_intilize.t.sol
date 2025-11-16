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

/// @title Pool Initialization Test
/// @notice Simple test to verify that the pool initializes correctly
contract PoolInitializeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    
    PerpsHook public perpsHook;
    PositionManager public perpPositionManager;
    PositionFactory public positionFactory;
    PositionNFT public positionNFT;
    MarketManager public marketManager;
    MarginAccount public marginAccount;
    FundingOracle public fundingOracle;
    MockUSDC public usdc;
    MockVETH public veth;
    
    Currency currency0;
    Currency currency1;
    
    PoolKey poolKey;
    PoolId poolId;
    
    function setUp() public {
        console.log("=== SETTING UP POOL INITIALIZATION TEST ===");
        
        // Deploy all required Uniswap V4 artifacts
        deployArtifacts();
        
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
        
        // Deploy FundingOracle
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
        
        console.log("=== SETUP COMPLETE ===");
        console.log("");
    }
    
    function test_PoolInitialization() public {
        console.log("=== TESTING POOL INITIALIZATION ===");
        
        // Initialize the pool (this will trigger afterInitialize hook)
        // afterInitialize needs getSpotPrice() which now has Chainlink feed
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        
        console.log("Pool initialized successfully");
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        
        // Verify pool is initialized by checking slot0
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = 
            StateLibrary.getSlot0(poolManager, poolId);
        
        console.log("SqrtPriceX96:", sqrtPriceX96);
        console.log("Tick:", tick);
        console.log("Protocol Fee:", protocolFee);
        console.log("LP Fee:", lpFee);
        
        // Verify pool state is not zero (initialized)
        assertTrue(sqrtPriceX96 > 0, "Pool should be initialized with non-zero price");
        
        // Check hook's market state
        PerpsHook.MarketState memory market = perpsHook.getMarketState(poolId);
        
        console.log("Virtual Base:", market.virtualBase);
        console.log("Virtual Quote:", market.virtualQuote);
        console.log("Market Active:", market.isActive);
        
        // Verify market is initialized
        assertTrue(market.virtualBase > 0, "Virtual base should be initialized");
        assertTrue(market.virtualQuote > 0, "Virtual quote should be initialized");
        assertTrue(market.isActive, "Market should be active");
        
        console.log("");
        console.log("Pool initialization test PASSED");
    }
}

