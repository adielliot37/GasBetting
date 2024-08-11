// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract GasPriceBettingAMM {
    struct Bet {
        address user;
        uint256 amount;
        uint256 totalBetAmount;
        bool isLong;
        bool isClosed;
        uint256 TokensBought;
        uint256 purchaseGasPrice;
    }

    struct Pool {
        uint256 longTokens;
        uint256 shortTokens;
        mapping(address => Bet) bets;
        address[] betters;
        address[] liquidatedBetters;
        uint256 totalCollateral;
        uint256 totalLongCollateral;
        uint256 totalShortCollateral;
        uint256 totalLiquidityProvided;
        uint256 k;
        uint256 totalLongLiquidity;
        uint256 totalShortLiquidity;
        uint256 bettinglongTokens;
        uint256 bettingshortTokens;
        uint256 totalBettingFee;
        mapping(address => uint256) lpContribution;
        address[] lpProviders;
    }

    address public admin;
    uint256 public strikePrice;
    uint256 public contractEndTime;
    uint256 public contractLockTime;
    uint256 public marginPercentage = 10;
    uint256 public tradingFee = 1;
    uint256 public currentGasPrice;
    Pool public pool;

    uint256 public constant PRICE_PRECISION = 1e18;

    uint256 public initialCollateral;
    bool public adminWithdrawn;
    mapping(address => bool) public lpWithdrawn;
    uint256 public liquidityCollection;

    event BetPlaced(address indexed user, uint256 totalBetAmount, bool isLong, uint256 TokensBought);
    event LiquidityAdded(address indexed user, uint256 amount);
    event BetSettled(address indexed user, uint256 payout, bool isWin);
    event PoolEnded();
    event BetLiquidated(address indexed user);
    event RemainingBalanceClaimed(address indexed admin, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyActive() {
        require(block.timestamp < contractLockTime, "Contract locked");
        _;
    }

    modifier onlyOneBet() {
        require(pool.bets[msg.sender].user == address(0), "You can only place one bet at a time");
        _;
    }

    constructor(
        uint256 _duration,
        uint256 _strikePrice,
        uint256 _lockDuration,
        uint256 _initialGasPrice
    ) payable {
        require(msg.value > 0, "Initial collateral must be greater than 0");

        admin = msg.sender;
        contractEndTime = block.timestamp + _duration;
        contractLockTime = block.timestamp + _lockDuration;
        strikePrice = _strikePrice;
        currentGasPrice = _initialGasPrice;
        pool.totalCollateral = msg.value;
        pool.totalLiquidityProvided = msg.value;
        pool.longTokens = msg.value / 2;
        pool.totalLongCollateral = msg.value / 2;
        pool.totalLongLiquidity = msg.value / 2;
        pool.shortTokens = msg.value / 2;
        pool.totalShortCollateral = msg.value / 2;
        pool.totalShortLiquidity = msg.value / 2;
        pool.k = pool.longTokens * pool.shortTokens;
        pool.bettinglongTokens = 0;
        pool.bettingshortTokens = 0;

        initialCollateral = msg.value;

        require(pool.longTokens + pool.shortTokens == msg.value, "Initial token division error");
    }

    function placeBet(bool isLong) external payable onlyActive onlyOneBet {
        uint256 margin = (msg.value * marginPercentage) / 100;
        uint256 fee = (margin * tradingFee) / 100;
        uint256 totalBetAmount = msg.value;
        require(msg.value > 0, "Incorrect ETH amount sent");

        pool.totalCollateral += msg.value;
        pool.totalBettingFee += fee;
        uint256 TokensBought = 0;
        if (isLong) {
            TokensBought = (msg.value * pool.longTokens) / pool.totalLongLiquidity;
            pool.longTokens -= TokensBought;
            pool.totalLongCollateral += msg.value;
            pool.totalLongLiquidity += totalBetAmount;
            pool.shortTokens = pool.k / pool.longTokens;
            pool.bettinglongTokens += TokensBought;
        } else {
            TokensBought = (msg.value * pool.shortTokens) / pool.totalShortLiquidity;
            pool.shortTokens -= TokensBought;
            pool.totalShortCollateral += msg.value;
            pool.longTokens = pool.k / pool.shortTokens;
            pool.totalShortLiquidity += totalBetAmount;
            pool.bettingshortTokens += TokensBought;
        }

        Bet memory newBet = Bet(msg.sender, msg.value, totalBetAmount, isLong, false, TokensBought, currentGasPrice);
        pool.bets[msg.sender] = newBet;
        pool.betters.push(msg.sender);

        emit BetPlaced(msg.sender, totalBetAmount, isLong, TokensBought);
    }

    function setCurrentGasPrice(uint256 _currentGasPrice) external onlyAdmin {
        currentGasPrice = _currentGasPrice;
    }

    function calculateRequiredLiquidity(address user) public view returns (uint256 requiredLiquidity, bool needsLiquidity) {
        Bet memory bet = pool.bets[user];
        require(bet.user != address(0), "Bet does not exist");
        require(!bet.isClosed, "Bet is closed");

        uint256 priceDifference;
        if (bet.isLong) {
            if (currentGasPrice < bet.purchaseGasPrice) {
                priceDifference = ((bet.purchaseGasPrice - currentGasPrice) * 100) / bet.purchaseGasPrice;
            }
        } else {
            if (currentGasPrice > bet.purchaseGasPrice) {
                priceDifference = ((currentGasPrice - bet.purchaseGasPrice) * 100) / bet.purchaseGasPrice;
            }
        }

        if (priceDifference > 0 && priceDifference < 20) {
            requiredLiquidity = (5 * priceDifference * bet.totalBetAmount) / 100;
            needsLiquidity = true;
        } else {
            requiredLiquidity = 0;
            needsLiquidity = false;
        }

        return (requiredLiquidity, needsLiquidity);
    }

    function addLiquidity() external payable onlyActive {
        require(msg.value > 0, "Must provide liquidity");

        uint256 halfLiquidity = msg.value / 2;
        uint256 longTokens = (msg.value * pool.longTokens) / pool.totalLongLiquidity;
        uint256 shortTokens = (msg.value * pool.shortTokens) / pool.totalShortLiquidity;

        pool.longTokens += longTokens;
        pool.shortTokens += shortTokens;
        pool.totalLongLiquidity += halfLiquidity;
        pool.totalShortLiquidity += halfLiquidity;
        pool.totalCollateral += msg.value;
        pool.totalLiquidityProvided += msg.value;
        pool.k = pool.longTokens * pool.shortTokens;

        if (pool.lpContribution[msg.sender] == 0) {
            pool.lpProviders.push(msg.sender);
        }
        pool.lpContribution[msg.sender] += msg.value;

        emit LiquidityAdded(msg.sender, msg.value);
    }

    function addMoreLiquidity() external payable onlyActive {
        Bet storage bet = pool.bets[msg.sender];
        require(bet.user != address(0), "Bet does not exist");
        require(!bet.isClosed, "Bet is closed");

        (uint256 requiredLiquidity, bool needsLiquidity) = calculateRequiredLiquidity(msg.sender);
        require(needsLiquidity, "No additional liquidity needed");
        require(msg.value == requiredLiquidity, "Incorrect liquidity amount provided");

        pool.totalCollateral += msg.value;
        if (bet.isLong) {
            uint256 additionalTokens = (msg.value * pool.longTokens) / pool.totalLongLiquidity;
            pool.longTokens -= additionalTokens;
            pool.totalLongCollateral += msg.value;
            pool.totalLongLiquidity += msg.value;
            pool.bettinglongTokens += additionalTokens;
            bet.TokensBought += additionalTokens;
        } else {
            uint256 additionalTokens = (msg.value * pool.shortTokens) / pool.totalShortLiquidity;
            pool.shortTokens -= additionalTokens;
            pool.totalShortCollateral += msg.value;
            pool.totalShortLiquidity += msg.value;
            pool.bettingshortTokens += additionalTokens;
            bet.TokensBought += additionalTokens;
        }

        bet.totalBetAmount += msg.value;
        bet.purchaseGasPrice = currentGasPrice;
        emit LiquidityAdded(msg.sender, msg.value);
    }

    function checkAndLiquidate() external onlyAdmin {
        for (uint256 i = 0; i < pool.betters.length; i++) {
            address user = pool.betters[i];
            Bet memory bet = pool.bets[user];

            if (!bet.isClosed) {
                uint256 priceDifference;
                if (bet.isLong) {
                    if (currentGasPrice < bet.purchaseGasPrice) {
                        priceDifference = ((bet.purchaseGasPrice - currentGasPrice) * 100) / bet.purchaseGasPrice;
                    }
                } else {
                    if (currentGasPrice > bet.purchaseGasPrice) {
                        priceDifference = ((currentGasPrice - bet.purchaseGasPrice) * 100) / bet.purchaseGasPrice;
                    }
                }

                if (priceDifference >= 20) {
                    // Liquidate the bet
                    pool.bets[user].isClosed = true;
                    pool.liquidatedBetters.push(user);

                    if (bet.isLong) {
                        pool.longTokens += bet.TokensBought;
                        pool.totalLongCollateral -= bet.totalBetAmount;
                        pool.bettinglongTokens -= bet.TokensBought;
                    } else {
                        pool.shortTokens += bet.TokensBought;
                        pool.totalShortCollateral -= bet.totalBetAmount;
                        pool.bettingshortTokens -= bet.TokensBought;
                    }

                    liquidityCollection += bet.totalBetAmount; // Collect liquidated amount
                    pool.bets[user].TokensBought = 0;
                    pool.bets[user].totalBetAmount = 0;
                    emit BetLiquidated(user);
                }
            }
        }
    }

    function settleBets(uint256 finalGasPrice) external onlyAdmin {
        require(block.timestamp >= contractEndTime, "Contract not ended yet");

        uint256 losingSideAmount;
        bool longWon = finalGasPrice > strikePrice;

        if (longWon) {
            losingSideAmount = pool.totalShortCollateral - initialCollateral / 2 - ((pool.totalShortCollateral - (initialCollateral / 2)) * tradingFee) / 100;
        } else {
            losingSideAmount = pool.totalLongCollateral - initialCollateral / 2 - ((pool.totalLongCollateral - (initialCollateral / 2)) * tradingFee) / 100;
        }

        for (uint256 i = 0; i < pool.betters.length; i++) {
            address user = pool.betters[i];
            Bet memory bet = pool.bets[user];
            uint256 payout = 0;

            if (!bet.isClosed && ((bet.isLong && longWon) || (!bet.isLong && !longWon))) {
                uint256 userShare = (bet.TokensBought * PRICE_PRECISION) / (longWon ? pool.bettinglongTokens : pool.bettingshortTokens);
                payout = bet.amount + ((userShare * losingSideAmount) / PRICE_PRECISION);
                emit BetSettled(user, payout, true);
            } else if (!bet.isClosed) {
                payout = bet.amount - ((bet.amount * tradingFee) / 100);
                emit BetSettled(user, payout, false);
            }

            if (payout > 0) {
                payable(user).transfer(payout);
            }
        }

        emit PoolEnded();
    }

    function withdrawCollateral() external onlyAdmin {
        require(block.timestamp >= contractEndTime, "Contract not ended yet");
        require(!adminWithdrawn, "Admin has already withdrawn");

        uint256 adminTradingFeeShare = (pool.totalBettingFee * 30) / 100;
        uint256 adminPayout = initialCollateral + adminTradingFeeShare;

        require(pool.totalCollateral >= adminPayout, "Insufficient contract balance");

        payable(admin).transfer(adminPayout);
        pool.totalCollateral -= adminPayout;
        adminWithdrawn = true;
    }

    function claimLPPayout() external {
        require(block.timestamp >= contractEndTime, "Contract not ended yet");
        require(pool.lpContribution[msg.sender] > 0, "No LP contribution found");
        require(!lpWithdrawn[msg.sender], "LP has already withdrawn");

        uint256 totalDepositedByLPs = 0;
        for (uint256 i = 0; i < pool.lpProviders.length; i++) {
            totalDepositedByLPs += pool.lpContribution[pool.lpProviders[i]];
        }

        uint256 totalLPTradingFeeShare = (pool.totalBettingFee * 70) / 100;
        uint256 userLPShare = (pool.lpContribution[msg.sender] * PRICE_PRECISION) / totalDepositedByLPs;
        uint256 userTradingFeeShare = (userLPShare * totalLPTradingFeeShare) / PRICE_PRECISION;
        uint256 lpPayout = pool.lpContribution[msg.sender] + userTradingFeeShare;

        require(pool.totalCollateral >= lpPayout, "Insufficient contract balance");

        payable(msg.sender).transfer(lpPayout);
        pool.totalCollateral -= lpPayout;
        lpWithdrawn[msg.sender] = true;
    }

    struct BetInfo {
        address user;
        uint256 amount;
        uint256 totalBetAmount;
        bool isLong;
        bool isClosed;
        uint256 TokensBought;
        uint256 purchaseGasPrice;
    }

    function getAllBets() external view returns (BetInfo[] memory) {
        BetInfo[] memory allBets = new BetInfo[](pool.betters.length);
        
        for (uint256 i = 0; i < pool.betters.length; i++) {
            address user = pool.betters[i];
            Bet storage bet = pool.bets[user];
            
            allBets[i] = BetInfo({
                user: bet.user,
                amount: bet.amount,
                totalBetAmount: bet.totalBetAmount,
                isLong: bet.isLong,
                isClosed: bet.isClosed,
                TokensBought: bet.TokensBought,
                purchaseGasPrice: bet.purchaseGasPrice
            });
        }
        
        return allBets;
    }

    function getLiquidatedBets() external view returns (BetInfo[] memory) {
        BetInfo[] memory liquidatedBets = new BetInfo[](pool.liquidatedBetters.length);
        
        for (uint256 i = 0; i < pool.liquidatedBetters.length; i++) {
            address user = pool.liquidatedBetters[i];
            Bet storage bet = pool.bets[user];
            
            liquidatedBets[i] = BetInfo({
                user: bet.user,
                amount: bet.amount,
                totalBetAmount: bet.totalBetAmount,
                isLong: bet.isLong,
                isClosed: bet.isClosed,
                TokensBought: bet.TokensBought,
                purchaseGasPrice: bet.purchaseGasPrice
            });
        }
        
        return liquidatedBets;
    }

    function endContract() external onlyAdmin {
        contractEndTime = block.timestamp;
        contractLockTime = block.timestamp;
        emit PoolEnded();
    }

    function claimRemainingBalance() external onlyAdmin {
        require(block.timestamp >= contractEndTime, "Contract not ended yet");
        require(adminWithdrawn, "Admin has not withdrawn yet");

        uint256 remainingLiquidity = liquidityCollection;

        require(remainingLiquidity > 0, "No liquidity collection to claim");

        payable(admin).transfer(remainingLiquidity);
        liquidityCollection = 0;

        emit RemainingBalanceClaimed(admin, remainingLiquidity);
    }
}