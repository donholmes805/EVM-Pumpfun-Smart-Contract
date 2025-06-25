// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IUniswapV2Factory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);
}

contract ThousandXMeme is ReentrancyGuard, Ownable {
    receive() external payable {}

    // Platform configuration
    address private platformFeeRecipient;
    uint256 private platformCreateFee;
    uint256 private platformTradeFee; // basis points (100 = 1%)
    uint256 private creatorFee; // basis points for token creators
    
    // Bonding curve parameters
    uint256 private initialVirtualTokenReserves;
    uint256 private initialVirtualEthReserves;
    uint256 private tokenTotalSupply;
    uint256 private mcapLimit;
    
    // Platform stats
    uint256 public totalTokensCreated;
    uint256 public totalVolumeETH;
    uint256 public totalFeesCollected;

    IUniswapV2Router02 private uniswapV2Router;

    struct Token {
        address tokenMint;
        address creator;
        uint256 virtualTokenReserves;
        uint256 virtualEthReserves;
        uint256 realTokenReserves;
        uint256 realEthReserves;
        uint256 tokenTotalSupply;
        uint256 mcapLimit;
        uint256 createdAt;
        uint256 totalVolume;
        bool complete;
        bool migrated;
    }

    struct CreatorStats {
        uint256 tokensCreated;
        uint256 totalVolume;
        uint256 feesEarned;
    }

    mapping(address => Token) public bondingCurve;
    mapping(address => CreatorStats) public creatorStats;
    mapping(address => bool) public authorizedOperators;
    
    // Events
    event TokenCreated(
        address indexed tokenMint, 
        address indexed creator, 
        string name, 
        string symbol,
        uint256 timestamp
    );
    
    event Trade(
        address indexed tokenMint, 
        uint256 ethAmount, 
        uint256 tokenAmount, 
        bool isBuy, 
        address indexed trader, 
        uint256 timestamp, 
        uint256 virtualEthReserves, 
        uint256 virtualTokenReserves
    );
    
    event TokenCompleted(
        address indexed tokenMint, 
        address indexed creator, 
        uint256 timestamp,
        uint256 finalMcap
    );
    
    event FeesWithdrawn(
        address indexed recipient, 
        uint256 amount, 
        uint256 timestamp
    );

    modifier onlyAuthorized() {
        require(
            msg.sender == owner() || authorizedOperators[msg.sender], 
            "Not authorized"
        );
        _;
    }

    constructor(
        address _platformFeeRecipient,
        uint256 _platformCreateFee,
        uint256 _platformTradeFee,
        uint256 _creatorFee
    ) Ownable(msg.sender) {
        require(_platformFeeRecipient != address(0), "Invalid fee recipient");
        require(_platformTradeFee <= 1000, "Trade fee too high"); // Max 10%
        require(_creatorFee <= 500, "Creator fee too high"); // Max 5%
        
        platformFeeRecipient = _platformFeeRecipient;
        platformCreateFee = _platformCreateFee;
        platformTradeFee = _platformTradeFee;
        creatorFee = _creatorFee;
        
        // Default bonding curve parameters
        initialVirtualTokenReserves = 10**27; // 1B tokens
        initialVirtualEthReserves = 3*10**21; // 3000 ETH
        tokenTotalSupply = 10**27; // 1B tokens
        mcapLimit = 10**23; // 100K ETH mcap
    }

    function createToken(
        address token,
        uint256 amount,
        string memory name,
        string memory symbol
    ) external payable nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(msg.value >= platformCreateFee, "Insufficient create fee");
        require(bondingCurve[token].tokenMint == address(0), "Token already exists");

        // Transfer tokens to contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Send platform fee
        payable(platformFeeRecipient).transfer(platformCreateFee);

        // Initialize bonding curve
        bondingCurve[token] = Token({
            tokenMint: token,
            creator: msg.sender,
            virtualTokenReserves: initialVirtualTokenReserves,
            virtualEthReserves: initialVirtualEthReserves,
            realTokenReserves: amount,
            realEthReserves: 0,
            tokenTotalSupply: tokenTotalSupply,
            mcapLimit: mcapLimit,
            createdAt: block.timestamp,
            totalVolume: 0,
            complete: false,
            migrated: false
        });

        // Update stats
        totalTokensCreated++;
        creatorStats[msg.sender].tokensCreated++;

        emit TokenCreated(token, msg.sender, name, symbol, block.timestamp);
    }

    function buy(
        address token,
        uint256 amount,
        uint256 maxEthCost
    ) external payable nonReentrant {
        Token storage tokenCurve = bondingCurve[token];
        require(tokenCurve.tokenMint != address(0), "Token not found");
        require(amount > 0, "Amount must be > 0");
        require(!tokenCurve.complete, "Token trading completed");
        require(!tokenCurve.migrated, "Token migrated");

        // Check if enough tokens available (keep 20% minimum)
        uint256 remainingAfterPurchase = tokenCurve.realTokenReserves - amount;
        uint256 remainingPercentage = (remainingAfterPurchase * 100) / tokenCurve.tokenTotalSupply;
        require(remainingPercentage >= 20, "Insufficient tokens available");

        uint256 ethCost = calculateEthCost(tokenCurve, amount);
        require(ethCost <= maxEthCost, "Exceeds max ETH cost");
        require(msg.value >= ethCost, "Insufficient ETH sent");

        // Calculate fees
        uint256 platformFeeAmount = (ethCost * platformTradeFee) / 10000;
        uint256 creatorFeeAmount = (ethCost * creatorFee) / 10000;
        uint256 liquidityAmount = ethCost - platformFeeAmount - creatorFeeAmount;

        // Transfer fees
        payable(platformFeeRecipient).transfer(platformFeeAmount);
        payable(tokenCurve.creator).transfer(creatorFeeAmount);

        // Transfer tokens to buyer
        IERC20(token).transfer(msg.sender, amount);

        // Update reserves
        tokenCurve.realTokenReserves -= amount;
        tokenCurve.virtualTokenReserves -= amount;
        tokenCurve.virtualEthReserves += liquidityAmount;
        tokenCurve.realEthReserves += liquidityAmount;
        tokenCurve.totalVolume += ethCost;

        // Update global stats
        totalVolumeETH += ethCost;
        totalFeesCollected += platformFeeAmount;
        creatorStats[tokenCurve.creator].totalVolume += ethCost;
        creatorStats[tokenCurve.creator].feesEarned += creatorFeeAmount;

        // Check completion conditions
        uint256 currentMcap = (tokenCurve.virtualEthReserves * tokenCurve.tokenTotalSupply) / tokenCurve.virtualTokenReserves;
        uint256 currentPercentage = (tokenCurve.realTokenReserves * 100) / tokenCurve.tokenTotalSupply;

        if (currentMcap >= tokenCurve.mcapLimit || currentPercentage <= 20) {
            tokenCurve.complete = true;
            emit TokenCompleted(token, tokenCurve.creator, block.timestamp, currentMcap);
        }

        emit Trade(
            token, 
            ethCost, 
            amount, 
            true, 
            msg.sender, 
            block.timestamp, 
            tokenCurve.virtualEthReserves, 
            tokenCurve.virtualTokenReserves
        );

        // Refund excess ETH
        if (msg.value > ethCost) {
            payable(msg.sender).transfer(msg.value - ethCost);
        }
    }

    function sell(
        address token,
        uint256 amount,
        uint256 minEthOutput
    ) external nonReentrant {
        Token storage tokenCurve = bondingCurve[token];
        require(tokenCurve.tokenMint != address(0), "Token not found");
        require(!tokenCurve.complete, "Token trading completed");
        require(!tokenCurve.migrated, "Token migrated");
        require(amount > 0, "Amount must be > 0");

        uint256 ethOutput = calculateEthOutput(tokenCurve, amount);
        
        // Ensure we don't drain all ETH
        if (tokenCurve.realEthReserves < ethOutput) {
            ethOutput = tokenCurve.realEthReserves;
        }
        
        require(ethOutput >= minEthOutput, "Below minimum ETH output");

        // Calculate fees
        uint256 platformFeeAmount = (ethOutput * platformTradeFee) / 10000;
        uint256 creatorFeeAmount = (ethOutput * creatorFee) / 10000;
        uint256 sellerAmount = ethOutput - platformFeeAmount - creatorFeeAmount;

        // Transfer token from seller
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Transfer ETH and fees
        payable(platformFeeRecipient).transfer(platformFeeAmount);
        payable(tokenCurve.creator).transfer(creatorFeeAmount);
        payable(msg.sender).transfer(sellerAmount);

        // Update reserves
        tokenCurve.realTokenReserves += amount;
        tokenCurve.virtualTokenReserves += amount;
        tokenCurve.virtualEthReserves -= ethOutput;
        tokenCurve.realEthReserves -= ethOutput;
        tokenCurve.totalVolume += ethOutput;

        // Update global stats
        totalVolumeETH += ethOutput;
        totalFeesCollected += platformFeeAmount;
        creatorStats[tokenCurve.creator].totalVolume += ethOutput;
        creatorStats[tokenCurve.creator].feesEarned += creatorFeeAmount;

        emit Trade(
            token, 
            ethOutput, 
            amount, 
            false, 
            msg.sender, 
            block.timestamp, 
            tokenCurve.virtualEthReserves, 
            tokenCurve.virtualTokenReserves
        );
    }

    function calculateEthCost(Token memory token, uint256 tokenAmount) public pure returns (uint256) {
        uint256 virtualTokenReserves = token.virtualTokenReserves;
        uint256 newTokenReserves = virtualTokenReserves - tokenAmount;
        uint256 totalLiquidity = token.virtualEthReserves * token.virtualTokenReserves;
        uint256 newEthReserves = totalLiquidity / newTokenReserves;
        return newEthReserves - token.virtualEthReserves;
    }

    function calculateEthOutput(Token memory token, uint256 tokenAmount) public pure returns (uint256) {
        uint256 virtualTokenReserves = token.virtualTokenReserves;
        uint256 newTokenReserves = virtualTokenReserves + tokenAmount;
        uint256 totalLiquidity = token.virtualEthReserves * token.virtualTokenReserves;
        uint256 newEthReserves = totalLiquidity / newTokenReserves;
        return token.virtualEthReserves - newEthReserves;
    }

    // Admin functions
    function setPlatformFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid address");
        platformFeeRecipient = newRecipient;
    }

    function setPlatformFees(uint256 newCreateFee, uint256 newTradeFee) external onlyOwner {
        require(newTradeFee <= 1000, "Trade fee too high"); // Max 10%
        platformCreateFee = newCreateFee;
        platformTradeFee = newTradeFee;
    }

    function setCreatorFee(uint256 newCreatorFee) external onlyOwner {
        require(newCreatorFee <= 500, "Creator fee too high"); // Max 5%
        creatorFee = newCreatorFee;
    }

    function setBondingCurveParams(
        uint256 newInitialVirtualTokenReserves,
        uint256 newInitialVirtualEthReserves,
        uint256 newTokenTotalSupply,
        uint256 newMcapLimit
    ) external onlyOwner {
        require(newInitialVirtualTokenReserves > 0, "Invalid token reserves");
        require(newInitialVirtualEthReserves > 0, "Invalid ETH reserves");
        require(newTokenTotalSupply > 0, "Invalid total supply");
        require(newMcapLimit > 0, "Invalid mcap limit");

        initialVirtualTokenReserves = newInitialVirtualTokenReserves;
        initialVirtualEthReserves = newInitialVirtualEthReserves;
        tokenTotalSupply = newTokenTotalSupply;
        mcapLimit = newMcapLimit;
    }

    function setAuthorizedOperator(address operator, bool authorized) external onlyOwner {
        authorizedOperators[operator] = authorized;
    }

    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function withdrawPlatformFees() external onlyAuthorized {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        
        payable(platformFeeRecipient).transfer(balance);
        emit FeesWithdrawn(platformFeeRecipient, balance, block.timestamp);
    }

    // View functions
    function getTokenInfo(address token) external view returns (Token memory) {
        return bondingCurve[token];
    }

    function getCreatorStats(address creator) external view returns (CreatorStats memory) {
        return creatorStats[creator];
    }

    function getPlatformStats() external view returns (
        uint256 _totalTokensCreated,
        uint256 _totalVolumeETH,
        uint256 _totalFeesCollected,
        uint256 _platformCreateFee,
        uint256 _platformTradeFee,
        uint256 _creatorFee
    ) {
        return (
            totalTokensCreated,
            totalVolumeETH,
            totalFeesCollected,
            platformCreateFee,
            platformTradeFee,
            creatorFee
        );
    }

    function getCreateFee() external view returns (uint256) {
        return platformCreateFee;
    }
}