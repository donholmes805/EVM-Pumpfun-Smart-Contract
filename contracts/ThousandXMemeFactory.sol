// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Token.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IThousandXMeme {
    function createToken(
        address token,
        uint256 amount,
        string memory name,
        string memory symbol
    ) external payable;
    function getCreateFee() external view returns(uint256);
}

contract ThousandXMemeFactory is Ownable {
    uint256 public constant INITIAL_SUPPLY = 10**27; // 1 billion tokens
    uint256 public totalTokensDeployed;
    
    address public thousandXMemeContract;
    
    struct TokenInfo {
        address tokenAddress;
        address creator;
        string tokenName;
        string tokenSymbol;
        uint256 totalSupply;
        uint256 createdAt;
        bool isActive;
    }

    TokenInfo[] public deployedTokens;
    mapping(address => TokenInfo[]) public creatorTokens;
    mapping(address => bool) public isTokenDeployed;
    
    event TokenDeployed(
        address indexed tokenAddress,
        address indexed creator,
        string name,
        string symbol,
        uint256 timestamp
    );

    constructor() Ownable(msg.sender) {}

    function deployToken(
        string memory name,
        string memory symbol
    ) external payable {
        require(bytes(name).length > 0, "Name cannot be empty");
        require(bytes(symbol).length > 0, "Symbol cannot be empty");
        require(thousandXMemeContract != address(0), "1000X.Meme contract not set");
        
        uint256 createFee = IThousandXMeme(thousandXMemeContract).getCreateFee();
        require(msg.value >= createFee, "Insufficient fee");

        // Deploy new ERC20 token
        Token newToken = new Token(name, symbol, INITIAL_SUPPLY);
        address tokenAddress = address(newToken);
        
        // Approve the 1000X.Meme contract to spend tokens
        newToken.approve(thousandXMemeContract, INITIAL_SUPPLY);
        
        // Create token info
        TokenInfo memory tokenInfo = TokenInfo({
            tokenAddress: tokenAddress,
            creator: msg.sender,
            tokenName: name,
            tokenSymbol: symbol,
            totalSupply: INITIAL_SUPPLY,
            createdAt: block.timestamp,
            isActive: true
        });
        
        // Store token info
        deployedTokens.push(tokenInfo);
        creatorTokens[msg.sender].push(tokenInfo);
        isTokenDeployed[tokenAddress] = true;
        totalTokensDeployed++;
        
        // Create bonding curve in main contract
        IThousandXMeme(thousandXMemeContract).createToken{value: msg.value}(
            tokenAddress,
            INITIAL_SUPPLY,
            name,
            symbol
        );
        
        emit TokenDeployed(tokenAddress, msg.sender, name, symbol, block.timestamp);
    }

    function setThousandXMemeContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid contract address");
        thousandXMemeContract = newContract;
    }

    function getDeployedTokens() external view returns (TokenInfo[] memory) {
        return deployedTokens;
    }

    function getCreatorTokens(address creator) external view returns (TokenInfo[] memory) {
        return creatorTokens[creator];
    }

    function getTokenInfo(uint256 index) external view returns (TokenInfo memory) {
        require(index < deployedTokens.length, "Token index out of bounds");
        return deployedTokens[index];
    }

    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}