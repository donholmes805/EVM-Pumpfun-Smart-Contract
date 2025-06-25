import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    
    console.log("Deploying 1000X.Meme contracts with account:", deployer.address);
    console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

    // Configuration
    const config = {
        platformFeeRecipient: deployer.address, // Change this to your fee recipient address
        platformCreateFee: ethers.parseEther("0.001"), // 0.001 ETH to create a token
        platformTradeFee: 100n, // 1% trading fee (100 basis points)
        creatorFee: 50n, // 0.5% creator fee (50 basis points)
    };

    console.log("\n=== Deployment Configuration ===");
    console.log("Platform Fee Recipient:", config.platformFeeRecipient);
    console.log("Create Fee:", ethers.formatEther(config.platformCreateFee), "ETH");
    console.log("Platform Trade Fee:", Number(config.platformTradeFee) / 100, "%");
    console.log("Creator Fee:", Number(config.creatorFee) / 100, "%");

    // Deploy main 1000X.Meme contract
    console.log("\n=== Deploying ThousandXMeme Contract ===");
    const ThousandXMeme = await ethers.getContractFactory("ThousandXMeme");
    const thousandXMeme = await ThousandXMeme.deploy(
        config.platformFeeRecipient,
        config.platformCreateFee,
        config.platformTradeFee,
        config.creatorFee
    );
    
    await thousandXMeme.waitForDeployment();
    const thousandXMemeAddress = await thousandXMeme.getAddress();
    console.log("✅ ThousandXMeme deployed to:", thousandXMemeAddress);

    // Deploy factory contract
    console.log("\n=== Deploying ThousandXMemeFactory Contract ===");
    const ThousandXMemeFactory = await ethers.getContractFactory("ThousandXMemeFactory");
    const factory = await ThousandXMemeFactory.deploy();
    
    await factory.waitForDeployment();
    const factoryAddress = await factory.getAddress();
    console.log("✅ ThousandXMemeFactory deployed to:", factoryAddress);

    // Connect factory to main contract
    console.log("\n=== Connecting Factory to Main Contract ===");
    await factory.setThousandXMemeContract(thousandXMemeAddress);
    console.log("✅ Factory connected to main contract");

    // Verify deployment
    console.log("\n=== Verifying Deployment ===");
    const stats = await thousandXMeme.getPlatformStats();
    console.log("Platform Create Fee:", ethers.formatEther(stats._platformCreateFee), "ETH");
    console.log("Platform Trade Fee:", Number(stats._platformTradeFee) / 100, "%");
    console.log("Creator Fee:", Number(stats._creatorFee) / 100, "%");
    console.log("Total Tokens Created:", stats._totalTokensCreated.toString());

    console.log("\n=== Deployment Summary ===");
    console.log("🚀 1000X.Meme Platform Successfully Deployed!");
    console.log("📋 Contract Addresses:");
    console.log("   • Main Contract (ThousandXMeme):", thousandXMemeAddress);
    console.log("   • Factory Contract:", factoryAddress);
    console.log("   • Fee Recipient:", config.platformFeeRecipient);
    
    console.log("\n📊 Revenue Configuration:");
    console.log("   • Token Creation Fee:", ethers.formatEther(config.platformCreateFee), "ETH per token");
    console.log("   • Platform Trading Fee:", Number(config.platformTradeFee) / 100, "% of each trade");
    console.log("   • Creator Reward Fee:", Number(config.creatorFee) / 100, "% of each trade");
    
    console.log("\n🔧 Next Steps:");
    console.log("1. Update platformFeeRecipient to your desired wallet address");
    console.log("2. Consider verifying contracts on Etherscan");
    console.log("3. Test token creation and trading on testnet first");
    console.log("4. Build your frontend to interact with these contracts");

    // Save deployment info
    const deploymentInfo = {
        network: await ethers.provider.getNetwork(),
        contracts: {
            ThousandXMeme: thousandXMemeAddress,
            ThousandXMemeFactory: factoryAddress,
        },
        config: {
            platformFeeRecipient: config.platformFeeRecipient,
            platformCreateFee: config.platformCreateFee.toString(),
            platformTradeFee: config.platformTradeFee.toString(),
            creatorFee: config.creatorFee.toString(),
        },
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
    };

    console.log("\n💾 Deployment Info:", JSON.stringify(deploymentInfo, null, 2));
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });