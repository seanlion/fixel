pragma solidity ^0.8.9;
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ILpPool.sol";
import "./interfaces/IPositionController.sol";

contract PositionController is ERC721Enumerable, Ownable, IPositionController {
    using SafeMath for uint256;
    using SafeMath for uint32;

    uint256 public LEVERAGE_DECIMAL = 2;

    address GD_TOKEN_ADDRESS = address(0);
    address USDC_TOKEN_ADDRESS = address(0);

    IERC20 USDC;// = IERC20(USDC_TOKEN_ADDRESS);
    IERC20 GD;// = IERC20(GD_TOKEN_ADDRESS);

    //TODO: make marketInfo structure
    mapping(uint80 => string) public markets;
    mapping(uint80 => uint32) public maxLeverage;
    mapping(uint80 => uint256) public liquidationThreshold; //bp
    uint80 marketCount;

    mapping(uint256 => address) private _tokenApprovals;
    mapping(uint256 => Position) positions;
    mapping(uint256 => MarketStatus) marketStatus;

    IFactory factoryContract;

    constructor(address _factoryContract, address _usdc, address _gd)
        ERC721("Renaissance Position", "rPos")
    {
        factoryContract = IFactory(_factoryContract);
        USDC = IERC20(_usdc);
        GD = IERC20(_gd);
    }

    function openPosition(
        uint80 marketId,
        uint256 liquidity,
        uint32 leverage,
        Side side
    ) external {
        require(
            USDC.balanceOf(msg.sender) >= liquidity,
            "Insufficient Balance"
        );

        ILpPool poolContract = ILpPool(factoryContract.getLpPool());
        IPriceOracle priceOracle = IPriceOracle(
            factoryContract.getPriceOracle()
        );

        USDC.transferFrom(msg.sender, address(this), liquidity);
        USDC.approve(address(poolContract), liquidity);

        uint256 margin = poolContract.addLiquidity(
            msg.sender,
            liquidity,
            ILpPool.exchangerCall.yes
        );
        uint256 price = priceOracle.getPrice(marketId);

        require(leverage <= maxLeverage[marketId], "Excessive Leverage");

        uint256 tokenId = totalSupply();
        _mint(msg.sender, tokenId);
        positions[tokenId] = Position(
            marketId,
            leverage,
            margin,
            price,
            side,
            Status.OPEN
        );

        updateMarketStatusAfterTrade(
            marketId,
            side,
            TradeType.OPEN,
            margin,
            margin.mul(leverage).div(price)
        );

        emit OpenPosition(
            msg.sender,
            marketId,
            margin,
            leverage,
            side,
            tokenId
        );
    }

    function closePosition(uint80 marketId, uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Invalid Token Id");
        require(positions[tokenId].status == Status.OPEN, "Already Closed");
        uint256 returnAmount = _closePosition(marketId, tokenId);
        USDC.transfer(ownerOf(tokenId), returnAmount);
    }

    function liquidate(uint80 marketId, uint256 tokenId) external {
        require(positions[tokenId].status == Status.OPEN, "Already Closed");
        uint256 currentMargin = calculateMargin(tokenId);
        uint256 marginRatio = currentMargin.mul(uint256(10000)).div(
            positions[tokenId].margin
        );
        require(
            marginRatio < liquidationThreshold[marketId],
            "Not Liquidatable"
        );
        uint256 returnAmount = _closePosition(marketId, tokenId);
        USDC.transfer(msg.sender, returnAmount);
        emit Liquidation(ownerOf(tokenId), msg.sender, marketId, tokenId);
    }

    function calculateMargin(uint256 tokenId) public view returns (uint256) {
        require(positions[tokenId].status == Status.OPEN, "Alread Closed");
        uint256 currentPrice = IPriceOracle(factoryContract.getPriceOracle())
            .getPrice(positions[tokenId].marketId);
        uint256 multiplier = positions[tokenId]
            .leverage
            .mul(positions[tokenId].margin)
            .div(positions[tokenId].price)
            .div(uint256(10)**LEVERAGE_DECIMAL);
        if (positions[tokenId].side == Side.LONG) {
            if (currentPrice > positions[tokenId].price) {
                return
                    positions[tokenId].margin.add(
                        (currentPrice.sub(positions[tokenId].price)).mul(
                            multiplier
                        )
                    );
            } else {
                return
                    positions[tokenId].margin.sub(
                        (positions[tokenId].price.sub(currentPrice)).mul(
                            multiplier
                        )
                    );
            }
        } else {
            if (currentPrice > positions[tokenId].price) {
                return
                    positions[tokenId].margin.sub(
                        (currentPrice.sub(positions[tokenId].price)).mul(
                            multiplier
                        )
                    );
            } else {
                return
                    positions[tokenId].margin.add(
                        (positions[tokenId].price.sub(currentPrice)).mul(
                            multiplier
                        )
                    );
            }
        }
    }

    function _closePosition(uint80 marketId, uint256 tokenId)
        internal
        returns (uint256)
    {
        updateMarketStatusAfterTrade(
            marketId,
            positions[tokenId].side,
            TradeType.CLOSE,
            positions[tokenId].margin,
            positions[tokenId].margin.mul(positions[tokenId].leverage).div(
                positions[tokenId].price
            )
        );

        bool isProfit;
        uint256 pnl;
        uint256 factor = positions[tokenId]
            .margin
            .mul(positions[tokenId].leverage)
            .div(positions[tokenId].price);

        if (positions[tokenId].side == Side.LONG) {
            if (marketStatus[marketId].lastPrice > positions[tokenId].price) {
                isProfit = true;
                pnl = (
                    marketStatus[marketId].lastPrice.sub(
                        positions[tokenId].price
                    )
                ).mul(factor).div(uint256(10)**LEVERAGE_DECIMAL);
            } else {
                isProfit = false;
                pnl = (
                    positions[tokenId].price.sub(
                        marketStatus[marketId].lastPrice
                    )
                ).mul(factor).div(uint256(10)**LEVERAGE_DECIMAL);
            }
        } else {
            if (marketStatus[marketId].lastPrice > positions[tokenId].price) {
                isProfit = false;
                pnl = (
                    marketStatus[marketId].lastPrice.sub(
                        positions[tokenId].price
                    )
                ).mul(factor).div(uint256(10)**LEVERAGE_DECIMAL);
            } else {
                isProfit = true;
                pnl = (
                    positions[tokenId].price.sub(
                        marketStatus[marketId].lastPrice
                    )
                ).mul(factor).div(uint256(10)**LEVERAGE_DECIMAL);
            }
        }

        uint256 refundGd;

        ILpPool lpPool = ILpPool(factoryContract.getLpPool());

        if (isProfit) {
            marketStatus[marketId].unrealizedPnl = marketStatus[marketId]
                .unrealizedPnl
                .sub(pnl);
            lpPool.mint(address(this), pnl);
            refundGd = positions[tokenId].margin.add(pnl);
        } else {
            marketStatus[marketId].unrealizedPnl = marketStatus[marketId]
                .unrealizedPnl
                .add(pnl);
            uint256 burnAmount = pnl > positions[marketId].margin
                ? positions[marketId].margin
                : pnl;
            lpPool.burn(address(this), burnAmount);
            refundGd = positions[tokenId].margin.sub(burnAmount);
        }

        marketStatus[marketId].margin = marketStatus[marketId].margin.sub(
            positions[tokenId].margin
        );
        positions[tokenId].status = Status.CLOSE;

        uint256 receiveAmount = lpPool.removeLiquidity(
            ownerOf(tokenId),
            refundGd,
            ILpPool.exchangerCall.yes
        );
        emit ClosePosition(
            ownerOf(tokenId),
            marketId,
            positions[tokenId].margin,
            positions[tokenId].side,
            tokenId,
            isProfit,
            pnl,
            receiveAmount
        );
        return receiveAmount;
    }

    function updateMarketStatusAfterTrade(
        uint80 marketId,
        Side side,
        TradeType tradeType,
        uint256 margin,
        uint256 factor
    ) internal {
        applyUnrealizedPnl(marketId);
        if (tradeType == TradeType.OPEN) {
            marketStatus[marketId].margin = marketStatus[marketId].margin.add(
                margin
            );
            if (side == Side.LONG) {
                marketStatus[marketId].totalLongPositionFactor = marketStatus[
                    marketId
                ].totalLongPositionFactor.add(factor);
            } else {
                marketStatus[marketId].totalShortPositionFactor = marketStatus[
                    marketId
                ].totalShortPositionFactor.add(factor);
            }
        } else if (tradeType == TradeType.CLOSE) {
            if (side == Side.LONG) {
                marketStatus[marketId].totalLongPositionFactor = marketStatus[
                    marketId
                ].totalLongPositionFactor.sub(factor);
            } else {
                marketStatus[marketId].totalShortPositionFactor = marketStatus[
                    marketId
                ].totalShortPositionFactor.sub(factor);
            }
        }
    }

    function addMarket(
        string memory name,
        uint32 _maxLeverage,
        uint256 threshold
    ) public onlyOwner {
        markets[marketCount] = name;
        maxLeverage[marketCount] = _maxLeverage;
        liquidationThreshold[marketCount] = threshold;
        emit AddMarket(marketCount, name, _maxLeverage);
        marketCount = marketCount + 1;
    }

    function changeMaxLeverage(uint80 marketId, uint32 _maxLeverage)
        public
        onlyOwner
    {
        require(_maxLeverage > 0, "Max Leverage Should Be Positive");
        require(marketId < marketCount, "Invalid Pool Id");
        maxLeverage[marketId] = _maxLeverage;
        emit ChangeMaxLeverage(marketId, _maxLeverage);
    }

    function getMarketMaxLeverage(uint80 marketId)
        external
        view
        returns (uint32)
    {
        require(marketId < marketCount, "Invalid Pool Id");
        return maxLeverage[marketId];
    }

    function getTotalUnrealizedPnl()
        public
        view
        returns (bool isPositive, uint256 value)
    {
        uint256 totalProfit = 0;
        uint256 totalLoss = 0;
        for (uint80 i = 0; i < marketCount; i = i + 1) {
            (Sign sign, uint256 pnl, ) = getUnrealizedPnl(i);
            if (sign == Sign.POS) {
                totalProfit = totalProfit.add(pnl);
            } else {
                totalLoss = totalLoss.add(pnl);
            }
        }
        if (totalProfit > totalLoss) {
            isPositive = true;
            value = totalProfit.sub(totalLoss);
        } else {
            isPositive = false;
            value = totalLoss.sub(totalProfit);
        }
    }

    function applyUnrealizedPnl(uint80 marketId)
        public
        returns (Sign, uint256)
    {
        require(marketId < marketCount, "Invalid Pool Id");
        (Sign isPositive, uint256 pnl, uint256 currentPrice) = getUnrealizedPnl(
            marketId
        );
        marketStatus[marketId].lastPrice = currentPrice;
        marketStatus[marketId].lastBlockNumber = block.number;
        marketStatus[marketId].pnlSign = isPositive;
        marketStatus[marketId].unrealizedPnl = pnl;
        return (
            marketStatus[marketId].pnlSign,
            marketStatus[marketId].unrealizedPnl
        );
    }

    function getUnrealizedPnl(uint80 marketId)
        public
        view
        returns (
            Sign isPositive,
            uint256 pnl,
            uint256 currentPrice
        )
    {
        require(marketId < marketCount, "Invalid Pool Id");

        currentPrice = IPriceOracle(factoryContract.getPriceOracle()).getPrice(
            marketId
        );

        if (marketStatus[marketId].lastBlockNumber == block.number) {
            return (
                marketStatus[marketId].pnlSign,
                marketStatus[marketId].unrealizedPnl,
                currentPrice
            );
        }
        isPositive = marketStatus[marketId].pnlSign;

        if (marketStatus[marketId].lastPrice < currentPrice) {
            uint256 longPositionsProfit = marketStatus[marketId]
                .totalLongPositionFactor
                .mul(currentPrice.sub(marketStatus[marketId].lastPrice));
            uint256 shortPositionsLoss = marketStatus[marketId]
                .totalShortPositionFactor
                .mul(currentPrice.sub(marketStatus[marketId].lastPrice));

            if (longPositionsProfit > shortPositionsLoss) {
                uint256 profit = (longPositionsProfit.sub(shortPositionsLoss))
                    .div(uint256(10)**LEVERAGE_DECIMAL);
                if (marketStatus[marketId].pnlSign == Sign.POS) {
                    pnl = marketStatus[marketId].unrealizedPnl.add(profit);
                } else {
                    if (marketStatus[marketId].unrealizedPnl < profit) {
                        isPositive = Sign.POS;
                        pnl = profit.sub(marketStatus[marketId].unrealizedPnl);
                    } else {
                        pnl = marketStatus[marketId].unrealizedPnl.sub(profit);
                    }
                }
            } else {
                uint256 loss = (shortPositionsLoss.sub(longPositionsProfit))
                    .div(uint256(10)**LEVERAGE_DECIMAL);
                if (marketStatus[marketId].pnlSign == Sign.NEG) {
                    pnl = marketStatus[marketId].unrealizedPnl.add(loss);
                } else {
                    if (marketStatus[marketId].unrealizedPnl < loss) {
                        isPositive = Sign.NEG;
                        pnl = loss.sub(marketStatus[marketId].unrealizedPnl);
                    } else {
                        pnl = marketStatus[marketId].unrealizedPnl.sub(loss);
                    }
                }
            }
        } else {
            uint256 longPositionsLoss = marketStatus[marketId]
                .totalLongPositionFactor
                .mul(marketStatus[marketId].lastPrice.sub(currentPrice));
            uint256 shortPositionsProfit = marketStatus[marketId]
                .totalShortPositionFactor
                .mul(marketStatus[marketId].lastPrice.sub(currentPrice));

            if (shortPositionsProfit > longPositionsLoss) {
                uint256 profit = (shortPositionsProfit.sub(longPositionsLoss))
                    .div(uint256(10)**LEVERAGE_DECIMAL);
                if (marketStatus[marketId].pnlSign == Sign.POS) {
                    pnl = marketStatus[marketId].unrealizedPnl.add(profit);
                } else {
                    if (marketStatus[marketId].unrealizedPnl < profit) {
                        isPositive = Sign.POS;
                        pnl = profit.sub(marketStatus[marketId].unrealizedPnl);
                    } else {
                        pnl = marketStatus[marketId].unrealizedPnl.sub(profit);
                    }
                }
            } else {
                uint256 loss = (longPositionsLoss.sub(shortPositionsProfit))
                    .div(uint256(10)**LEVERAGE_DECIMAL);
                if (marketStatus[marketId].pnlSign == Sign.NEG) {
                    pnl = marketStatus[marketId].unrealizedPnl.add(loss);
                } else {
                    if (marketStatus[marketId].unrealizedPnl < loss) {
                        isPositive = Sign.NEG;
                        pnl = loss.sub(marketStatus[marketId].unrealizedPnl);
                    } else {
                        pnl = marketStatus[marketId].unrealizedPnl.sub(loss);
                    }
                }
            }
        }
    }
}