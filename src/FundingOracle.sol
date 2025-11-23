// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Chainlink AggregatorV3Interface for price feeds
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @notice Interface for price oracles
interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Interface for vAMM hooks to get mark price
interface IVAMMHook {
    function getMarkPrice(PoolId poolId) external view returns (uint256);
    function getMarketState(PoolId poolId)
        external
        view
        returns (
            uint256 virtualBase,
            uint256 virtualQuote,
            uint256 k,
            int256 globalFundingIndex,
            uint256 totalLongOI,
            uint256 totalShortOI,
            uint256 maxOICap,
            uint256 lastFundingTime,
            address spotPriceFeed,
            bool isActive
        );
}

/// @title FundingOracle - Price Aggregation and Funding Rate Oracle using Chainlink
/// @notice Provides robust price data and funding rate calculations for perpetual futures
/// @dev Uses Chainlink price feeds and median calculation for manipulation resistance
contract FundingOracle is Ownable {
    using PoolIdLibrary for PoolId;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Market price data for funding calculations
    struct MarketData {
        uint256 markPrice; // Current mark price (from multiple sources)
        uint256 spotPrice; // Spot price from external oracle
        int256 globalFundingIndex; // Cumulative funding index (1e18 precision)
        uint256 lastFundingUpdate; // Timestamp of last funding update
        uint256 fundingInterval; // How often funding is updated (seconds)
        int256 maxFundingRate; // Maximum funding rate per interval (1e18 precision)
        uint256 fundingRateFactor; // Funding rate sensitivity (k factor)
        bool isActive; // Market is active for funding
    }

    /// @notice Price source configuration
    struct PriceSource {
        address oracle; // Oracle contract address (Chainlink aggregator or other)
        uint256 weight; // Weight in median calculation
        uint256 maxAge; // Maximum age for price data (seconds)
        bool isActive; // Source is active
        bool isChainlinkSource; // Whether this is a Chainlink price feed
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Market data by pool ID
    mapping(PoolId => MarketData) public markets;

    /// @notice External price sources for each market
    mapping(PoolId => PriceSource[]) public priceSources;

    /// @notice vAMM hook addresses for mark price calculation
    mapping(PoolId => address) public vammHooks;

    /// @notice Chainlink price feed aggregators for each market
    mapping(PoolId => address) public chainlinkPriceFeeds;

    /// @notice Maximum price staleness for Chainlink feeds (seconds)
    uint256 public chainlinkMaxStaleness = 3600; // 1 hour default

    /// @notice Default funding parameters
    uint256 public constant DEFAULT_FUNDING_INTERVAL = 1 hours;
    int256 public constant DEFAULT_MAX_FUNDING_RATE = 0.01e18; // 1% per interval
    uint256 public constant DEFAULT_FUNDING_RATE_FACTOR = 0.5e18; // 0.5 sensitivity

    /// @notice Price precision
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant FUNDING_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketAdded(PoolId indexed poolId, address vammHook);
    event FundingUpdated(PoolId indexed poolId, int256 newFundingIndex, int256 fundingRate, uint256 timestamp);
    event PriceSourceAdded(PoolId indexed poolId, address oracle, uint256 weight);
    event PriceSourceUpdated(PoolId indexed poolId, address oracle, uint256 weight, bool isActive);
    event ChainlinkPriceFeedAdded(PoolId indexed poolId, address priceFeed);
    event ChainlinkPriceUpdated(PoolId indexed poolId, uint256 price, uint256 timestamp);
    event MarkPriceUpdated(PoolId indexed poolId, uint256 markPrice, uint256 spotPrice, int256 premium);
    event MarketStatusChanged(PoolId indexed poolId, bool isActive);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MarketNotFound();
    error MarketNotActive();
    error InvalidPriceSource();
    error StalePrice();
    error InsufficientPriceSources();
    error InvalidFundingParameters();
    error InvalidChainlinkFeed();
    error PriceOutOfBounds();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor
    constructor() Ownable(msg.sender) {
        // No Chainlink contract needed - we use individual aggregator addresses
    }

    /*//////////////////////////////////////////////////////////////
                          MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a new market for funding calculations
    /// @param poolId Pool identifier
    /// @param vammHook Address of the vAMM hook contract
    /// @param chainlinkPriceFeed Address of Chainlink price feed aggregator (optional, use address(0) if not using Chainlink)
    function addMarket(PoolId poolId, address vammHook, address chainlinkPriceFeed) external onlyOwner {
        require(vammHook != address(0), "Invalid vAMM hook");

        vammHooks[poolId] = vammHook;
        
        if (chainlinkPriceFeed != address(0)) {
            // Validate Chainlink feed
            try AggregatorV3Interface(chainlinkPriceFeed).latestRoundData() returns (
                uint80,
                int256,
                uint256,
                uint256,
                uint80
            ) {
                chainlinkPriceFeeds[poolId] = chainlinkPriceFeed;
                emit ChainlinkPriceFeedAdded(poolId, chainlinkPriceFeed);
            } catch {
                revert InvalidChainlinkFeed();
            }
        }

        markets[poolId] = MarketData({
            markPrice: 0,
            spotPrice: 0,
            globalFundingIndex: 0,
            lastFundingUpdate: block.timestamp,
            fundingInterval: DEFAULT_FUNDING_INTERVAL,
            maxFundingRate: DEFAULT_MAX_FUNDING_RATE,
            fundingRateFactor: DEFAULT_FUNDING_RATE_FACTOR,
            isActive: true
        });

        emit MarketAdded(poolId, vammHook);
    }

    /// @notice Add price source for a market
    /// @param poolId Pool identifier
    /// @param oracle Oracle contract address
    /// @param weight Weight in median calculation
    /// @param maxAge Maximum age for price data
    function addPriceSource(PoolId poolId, address oracle, uint256 weight, uint256 maxAge) external onlyOwner {
        if (markets[poolId].lastFundingUpdate == 0) revert MarketNotFound();
        require(oracle != address(0), "Invalid oracle");
        require(weight > 0, "Invalid weight");

        priceSources[poolId].push(PriceSource({
            oracle: oracle, 
            weight: weight, 
            maxAge: maxAge, 
            isActive: true,
            isChainlinkSource: false
        }));

        emit PriceSourceAdded(poolId, oracle, weight);
    }

    /// @notice Add Chainlink price source for a market
    /// @param poolId Pool identifier
    /// @param chainlinkPriceFeed Address of Chainlink price feed aggregator
    /// @param weight Weight in median calculation
    /// @param maxAge Maximum age for price data
    function addChainlinkPriceSource(
        PoolId poolId, 
        address chainlinkPriceFeed, 
        uint256 weight, 
        uint256 maxAge
    ) external onlyOwner {
        if (markets[poolId].lastFundingUpdate == 0) revert MarketNotFound();
        require(chainlinkPriceFeed != address(0), "Invalid price feed");
        require(weight > 0, "Invalid weight");

        // Validate Chainlink feed
        try AggregatorV3Interface(chainlinkPriceFeed).latestRoundData() returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        ) {
            priceSources[poolId].push(PriceSource({
                oracle: chainlinkPriceFeed, 
                weight: weight, 
                maxAge: maxAge, 
                isActive: true,
                isChainlinkSource: true
            }));

            emit PriceSourceAdded(poolId, chainlinkPriceFeed, weight);
        } catch {
            revert InvalidChainlinkFeed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                         FUNDING CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update funding for a market
    /// @param poolId Pool identifier
    function updateFunding(PoolId poolId) external {
        MarketData storage market = markets[poolId];
        if (!market.isActive) revert MarketNotActive();

        // Check if enough time has passed
        if (block.timestamp < market.lastFundingUpdate + market.fundingInterval) {
            return; // Too early to update
        }

        // Get current prices
        uint256 markPrice = getMarkPrice(poolId);
        uint256 spotPrice = getSpotPrice(poolId);

        // Calculate funding rate
        int256 fundingRate = _calculateFundingRate(poolId, markPrice, spotPrice);

        // Update global funding index
        market.globalFundingIndex += fundingRate;
        market.lastFundingUpdate = block.timestamp;
        market.markPrice = markPrice;
        market.spotPrice = spotPrice;

        emit FundingUpdated(poolId, market.globalFundingIndex, fundingRate, block.timestamp);
    }

    /// @notice Calculate funding rate based on premium
    /// @param poolId Pool identifier
    /// @param markPrice Current mark price
    /// @param spotPrice Current spot price
    /// @return Funding rate for this interval
    function _calculateFundingRate(PoolId poolId, uint256 markPrice, uint256 spotPrice)
        internal
        view
        returns (int256)
    {
        if (spotPrice == 0) return 0;

        MarketData storage market = markets[poolId];

        // Calculate premium: (mark - spot) / spot
        int256 premium = (int256(markPrice) - int256(spotPrice)) * int256(FUNDING_PRECISION) / int256(spotPrice);

        // Funding rate = k * premium (where k is the funding rate factor)
        int256 fundingRate = (premium * int256(market.fundingRateFactor)) / int256(FUNDING_PRECISION);

        // Apply maximum funding rate cap
        if (fundingRate > market.maxFundingRate) {
            fundingRate = market.maxFundingRate;
        } else if (fundingRate < -market.maxFundingRate) {
            fundingRate = -market.maxFundingRate;
        }

        return fundingRate;
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get mark price using multiple sources and median calculation
    /// @param poolId Pool identifier
    /// @return Mark price in 1e18 precision
    function getMarkPrice(PoolId poolId) public view returns (uint256) {
        address vammHook = vammHooks[poolId];
        if (vammHook == address(0)) revert MarketNotFound();

        // Get vAMM price
        uint256 vammPrice = IVAMMHook(vammHook).getMarkPrice(poolId);

        // Get external prices
        uint256[] memory prices = new uint256[](priceSources[poolId].length + 1);
        prices[0] = vammPrice;

        uint256 validPrices = 1;
        for (uint256 i = 0; i < priceSources[poolId].length; i++) {
            PriceSource storage source = priceSources[poolId][i];
            if (!source.isActive) continue;

            if (source.isChainlinkSource) {
                // Handle Chainlink price source
                try this._getChainlinkPrice(source.oracle, source.maxAge) returns (uint256 price) {
                    if (price > 0) {
                        prices[validPrices] = price;
                        validPrices++;
                    }
                } catch {
                    // Skip failed Chainlink price
                    continue;
                }
            } else {
                // Handle traditional oracle
                try IPriceOracle(source.oracle).getPrice(address(0)) returns (uint256 price, uint256 updatedAt) {
                    if (block.timestamp - updatedAt <= source.maxAge && price > 0) {
                        prices[validPrices] = price;
                        validPrices++;
                    }
                } catch {
                    // Skip failed oracle
                    continue;
                }
            }
        }

        // Return median of valid prices
        return _calculateMedian(prices, validPrices);
    }

    /// @notice Get spot price from external oracles
    /// @param poolId Pool identifier
    /// @return Spot price in 1e18 precision
    /// @dev Reverts if no price sources are configured
    function getSpotPrice(PoolId poolId) public view returns (uint256) {
        PriceSource[] storage sources = priceSources[poolId];
        if (sources.length == 0) {
            // If no external sources, try primary Chainlink feed
            address primaryFeed = chainlinkPriceFeeds[poolId];
            if (primaryFeed != address(0)) {
                try this._getChainlinkPrice(primaryFeed, chainlinkMaxStaleness) returns (uint256 price) {
                    if (price > 0) return price;
                } catch {
                    // Chainlink feed failed
                }
            }
            // No price sources available - revert
            revert InsufficientPriceSources();
        }

        uint256[] memory prices = new uint256[](sources.length);
        uint256 validPrices = 0;

        for (uint256 i = 0; i < sources.length; i++) {
            if (!sources[i].isActive) continue;

            if (sources[i].isChainlinkSource) {
                // Handle Chainlink price source
                try this._getChainlinkPrice(sources[i].oracle, sources[i].maxAge) returns (uint256 price) {
                    if (price > 0) {
                        prices[validPrices] = price;
                        validPrices++;
                    }
                } catch {
                    continue;
                }
            } else {
                // Handle traditional oracle
                try IPriceOracle(sources[i].oracle).getPrice(address(0)) returns (uint256 price, uint256 updatedAt) {
                    if (block.timestamp - updatedAt <= sources[i].maxAge && price > 0) {
                        prices[validPrices] = price;
                        validPrices++;
                    }
                } catch {
                    continue;
                }
            }
        }

        if (validPrices == 0) revert InsufficientPriceSources();

        return _calculateMedian(prices, validPrices);
    }

    /// @notice Get Chainlink price from aggregator
    /// @param aggregator Address of Chainlink price feed aggregator
    /// @param maxAge Maximum age for price data
    /// @return price Price in 1e18 precision
    function _getChainlinkPrice(address aggregator, uint256 maxAge) external view returns (uint256 price) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);
        
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        // Silence unused variable warning
        startedAt;

        // Validate round data
        require(answer > 0, "Invalid price");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale round");
        
        // Check staleness
        if (block.timestamp - updatedAt > maxAge) {
            revert StalePrice();
        }

        // Get decimals from the aggregator
        uint8 decimals = priceFeed.decimals();
        
        // Convert to 1e18 precision
        price = _convertChainlinkPrice(uint256(answer), decimals);
        
        return price;
    }

    /// @notice Convert Chainlink price to 1e18 precision
    /// @param price Chainlink price
    /// @param decimals Number of decimals in Chainlink price
    /// @return price Price in 1e18 precision
    function _convertChainlinkPrice(uint256 price, uint8 decimals) internal pure returns (uint256) {
        // Chainlink prices typically have 8 decimals
        // We need to convert to 1e18 precision
        
        if (decimals == 18) {
            return price; // Already in correct precision
        } else if (decimals < 18) {
            // Scale up: multiply by 10^(18 - decimals)
            return price * (10 ** (18 - decimals));
        } else {
            // Scale down: divide by 10^(decimals - 18)
            return price / (10 ** (decimals - 18));
        }
    }

    /// @notice Get premium (mark - spot) in 1e18 precision
    /// @param poolId Pool identifier
    /// @return Premium as signed integer
    function premiumX18(PoolId poolId) external view returns (int256) {
        uint256 markPrice = getMarkPrice(poolId);
        uint256 spotPrice = getSpotPrice(poolId);

        return int256(markPrice) - int256(spotPrice);
    }

    /// @notice Calculate median of price array
    /// @param prices Array of prices
    /// @param length Number of valid prices
    /// @return Median price
    function _calculateMedian(uint256[] memory prices, uint256 length) internal pure returns (uint256) {
        if (length == 0) return 0;
        if (length == 1) return prices[0];

        // Simple bubble sort for small arrays
        for (uint256 i = 0; i < length - 1; i++) {
            for (uint256 j = 0; j < length - i - 1; j++) {
                if (prices[j] > prices[j + 1]) {
                    uint256 temp = prices[j];
                    prices[j] = prices[j + 1];
                    prices[j + 1] = temp;
                }
            }
        }

        // Return median
        if (length % 2 == 0) {
            return (prices[length / 2 - 1] + prices[length / 2]) / 2;
        } else {
            return prices[length / 2];
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CHAINLINK UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get Chainlink price for a specific aggregator
    /// @param aggregator Address of Chainlink price feed aggregator
    /// @return price Price in 1e18 precision
    /// @return updatedAt When the price was updated
    function getChainlinkPrice(address aggregator) external view returns (uint256 price, uint256 updatedAt) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);
        
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(answer > 0, "Invalid price");
        require(updatedAt_ > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale round");

        uint8 decimals = priceFeed.decimals();
        price = _convertChainlinkPrice(uint256(answer), decimals);
        updatedAt = updatedAt_;
    }

    /// @notice Get Chainlink price for a market's primary feed
    /// @param poolId Pool identifier
    /// @return price Price in 1e18 precision
    /// @return updatedAt When the price was updated
    function getMarketChainlinkPrice(PoolId poolId) external view returns (uint256 price, uint256 updatedAt) {
        address priceFeed = chainlinkPriceFeeds[poolId];
        if (priceFeed == address(0)) return (0, 0);
        
        return this.getChainlinkPrice(priceFeed);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get market data
    /// @param poolId Pool identifier
    /// @return Market data struct
    function getMarketData(PoolId poolId) external view returns (MarketData memory) {
        return markets[poolId];
    }

    /// @notice Get current funding index
    /// @param poolId Pool identifier
    /// @return Current global funding index
    function getFundingIndex(PoolId poolId) external view returns (int256) {
        return markets[poolId].globalFundingIndex;
    }

    /// @notice Check if funding update is needed
    /// @param poolId Pool identifier
    /// @return True if update is needed
    function needsFundingUpdate(PoolId poolId) external view returns (bool) {
        MarketData storage market = markets[poolId];
        return block.timestamp >= market.lastFundingUpdate + market.fundingInterval;
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update market status
    /// @param poolId Pool identifier
    /// @param isActive New status
    function setMarketStatus(PoolId poolId, bool isActive) external onlyOwner {
        markets[poolId].isActive = isActive;
        emit MarketStatusChanged(poolId, isActive);
    }

    /// @notice Update funding parameters
    /// @param poolId Pool identifier
    /// @param fundingInterval New funding interval
    /// @param maxFundingRate New maximum funding rate
    /// @param fundingRateFactor New funding rate factor
    function updateFundingParameters(
        PoolId poolId,
        uint256 fundingInterval,
        int256 maxFundingRate,
        uint256 fundingRateFactor
    ) external onlyOwner {
        if (fundingInterval == 0 || maxFundingRate <= 0 || fundingRateFactor == 0) {
            revert InvalidFundingParameters();
        }

        MarketData storage market = markets[poolId];
        market.fundingInterval = fundingInterval;
        market.maxFundingRate = maxFundingRate;
        market.fundingRateFactor = fundingRateFactor;
    }

    /// @notice Update price source configuration
    /// @param poolId Pool identifier
    /// @param sourceIndex Index of price source
    /// @param weight New weight
    /// @param isActive New active status
    function updatePriceSource(PoolId poolId, uint256 sourceIndex, uint256 weight, bool isActive) external onlyOwner {
        require(sourceIndex < priceSources[poolId].length, "Invalid source index");

        PriceSource storage source = priceSources[poolId][sourceIndex];
        source.weight = weight;
        source.isActive = isActive;

        emit PriceSourceUpdated(poolId, source.oracle, weight, isActive);
    }

    /// @notice Set Chainlink price feed for a market
    /// @param poolId Pool identifier
    /// @param priceFeed Address of Chainlink price feed aggregator
    function setChainlinkPriceFeed(PoolId poolId, address priceFeed) external onlyOwner {
        if (markets[poolId].lastFundingUpdate == 0) revert MarketNotFound();
        
        if (priceFeed != address(0)) {
            // Validate Chainlink feed
            try AggregatorV3Interface(priceFeed).latestRoundData() returns (
                uint80,
                int256,
                uint256,
                uint256,
                uint80
            ) {
                chainlinkPriceFeeds[poolId] = priceFeed;
                emit ChainlinkPriceFeedAdded(poolId, priceFeed);
            } catch {
                revert InvalidChainlinkFeed();
            }
        } else {
            chainlinkPriceFeeds[poolId] = address(0);
        }
    }

    /// @notice Set maximum staleness for Chainlink prices
    /// @param maxStaleness Maximum staleness in seconds
    function setChainlinkMaxStaleness(uint256 maxStaleness) external onlyOwner {
        require(maxStaleness > 0, "Invalid staleness");
        chainlinkMaxStaleness = maxStaleness;
    }

    /// @notice Check if market has Chainlink integration
    /// @param poolId Pool identifier
    /// @return True if market has Chainlink price feed set
    function hasMarketChainlinkIntegration(PoolId poolId) external view returns (bool) {
        return chainlinkPriceFeeds[poolId] != address(0);
    }

    /// @notice Get all price sources for a market
    /// @param poolId Pool identifier
    /// @return Array of price sources
    function getMarketPriceSources(PoolId poolId) external view returns (PriceSource[] memory) {
        return priceSources[poolId];
    }
}

