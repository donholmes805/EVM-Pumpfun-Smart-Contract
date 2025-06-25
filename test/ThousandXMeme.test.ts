import {
    time,
    loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

describe("1000X.Meme Platform", function () {
    let thousandXMeme: any;
    let factory: any;
    let testToken: any;
    let owner: any;
    let creator: any;
    let trader1: any;
    let trader2: any;
    let feeRecipient: any;

    const config = {
        name: "TestMeme",
        symbol: "TMEME",
        platformCreateFee: hre.ethers.parseEther("0.001"), // 0.001 ETH
        platformTradeFee: 100n, // 1%
        creatorFee: 50n, // 0.5%
        initialSupply: hre.ethers.parseUnits("1000000000", 18), // 1B tokens
    };

    async function deployFixture() {
        [owner, creator, trader1, trader2, feeRecipient] = await hre.ethers.getSigners();

        // Deploy main contract
        thousandXMeme = await hre.ethers.deployContract("ThousandXMeme", [
            feeRecipient.address,
            config.platformCreateFee,
            config.platformTradeFee,
            config.creatorFee
        ]);

        // Deploy factory
        factory = await hre.ethers.deployContract("ThousandXMemeFactory");
        
        await thousandXMeme.waitForDeployment();
        await factory.waitForDeployment();

        // Connect factory to main contract
        await factory.setThousandXMemeContract(await thousandXMeme.getAddress());

        return { thousandXMeme, factory, owner, creator, trader1, trader2, feeRecipient };
    }

    describe("Deployment", function () {
        it("Should deploy contracts correctly", async function () {
            const { thousandXMeme, factory } = await loadFixture(deployFixture);
            
            expect(await thousandXMeme.getAddress()).to.be.properAddress;
            expect(await factory.getAddress()).to.be.properAddress;
            
            const stats = await thousandXMeme.getPlatformStats();
            expect(stats._platformCreateFee).to.equal(config.platformCreateFee);
            expect(stats._platformTradeFee).to.equal(config.platformTradeFee);
            expect(stats._creatorFee).to.equal(config.creatorFee);
        });
    });

    describe("Token Creation", function () {
        it("Should create token through factory", async function () {
            const { factory } = await loadFixture(deployFixture);
            
            const createFee = await thousandXMeme.getCreateFee();
            
            await expect(
                factory.connect(creator).deployToken(
                    config.name,
                    config.symbol,
                    { value: createFee }
                )
            ).to.emit(factory, "TokenDeployed");

            const deployedTokens = await factory.getDeployedTokens();
            expect(deployedTokens.length).to.equal(1);
            expect(deployedTokens[0].creator).to.equal(creator.address);
            expect(deployedTokens[0].tokenName).to.equal(config.name);
            expect(deployedTokens[0].tokenSymbol).to.equal(config.symbol);

            testToken = deployedTokens[0].tokenAddress;
        });

        it("Should fail with insufficient fee", async function () {
            const { factory } = await loadFixture(deployFixture);
            
            await expect(
                factory.connect(creator).deployToken(
                    config.name,
                    config.symbol,
                    { value: hre.ethers.parseEther("0.0001") } // Too low
                )
            ).to.be.revertedWith("Insufficient fee");
        });
    });

    describe("Trading", function () {
        beforeEach(async function () {
            const { factory } = await loadFixture(deployFixture);
            
            const createFee = await thousandXMeme.getCreateFee();
            await factory.connect(creator).deployToken(
                config.name,
                config.symbol,
                { value: createFee }
            );

            const deployedTokens = await factory.getDeployedTokens();
            testToken = deployedTokens[0].tokenAddress;
        });

        it("Should allow buying tokens", async function () {
            const buyAmount = hre.ethers.parseUnits("1000000", 18); // 1M tokens
            const ethAmount = hre.ethers.parseEther("0.1");
            
            const tokenContract = await hre.ethers.getContractAt("IERC20", testToken);
            const initialBalance = await tokenContract.balanceOf(trader1.address);
            
            await expect(
                thousandXMeme.connect(trader1).buy(
                    testToken,
                    buyAmount,
                    ethAmount,
                    { value: ethAmount }
                )
            ).to.emit(thousandXMeme, "Trade");

            const finalBalance = await tokenContract.balanceOf(trader1.address);
            expect(finalBalance).to.be.gt(initialBalance);
        });

        it("Should allow selling tokens", async function () {
            // First buy some tokens
            const buyAmount = hre.ethers.parseUnits("1000000", 18);
            const ethAmount = hre.ethers.parseEther("0.1");
            
            await thousandXMeme.connect(trader1).buy(
                testToken,
                buyAmount,
                ethAmount,
                { value: ethAmount }
            );

            const tokenContract = await hre.ethers.getContractAt("IERC20", testToken);
            const balance = await tokenContract.balanceOf(trader1.address);
            
            // Approve selling
            await tokenContract.connect(trader1).approve(
                await thousandXMeme.getAddress(),
                balance
            );

            const initialEthBalance = await hre.ethers.provider.getBalance(trader1.address);
            
            await expect(
                thousandXMeme.connect(trader1).sell(
                    testToken,
                    balance,
                    0 // Min ETH output
                )
            ).to.emit(thousandXMeme, "Trade");

            const finalEthBalance = await hre.ethers.provider.getBalance(trader1.address);
            // Should have more ETH (minus gas costs)
        });

        it("Should distribute fees correctly", async function () {
            const buyAmount = hre.ethers.parseUnits("1000000", 18);
            const ethAmount = hre.ethers.parseEther("0.1");
            
            const initialFeeRecipientBalance = await hre.ethers.provider.getBalance(feeRecipient.address);
            const initialCreatorBalance = await hre.ethers.provider.getBalance(creator.address);
            
            await thousandXMeme.connect(trader1).buy(
                testToken,
                buyAmount,
                ethAmount,
                { value: ethAmount }
            );

            const finalFeeRecipientBalance = await hre.ethers.provider.getBalance(feeRecipient.address);
            const finalCreatorBalance = await hre.ethers.provider.getBalance(creator.address);
            
            // Both should have received fees
            expect(finalFeeRecipientBalance).to.be.gt(initialFeeRecipientBalance);
            expect(finalCreatorBalance).to.be.gt(initialCreatorBalance);
        });
    });

    describe("Admin Functions", function () {
        it("Should allow owner to update fees", async function () {
            const newCreateFee = hre.ethers.parseEther("0.002");
            const newTradeFee = 200n; // 2%
            
            await thousandXMeme.connect(owner).setPlatformFees(newCreateFee, newTradeFee);
            
            const stats = await thousandXMeme.getPlatformStats();
            expect(stats._platformCreateFee).to.equal(newCreateFee);
            expect(stats._platformTradeFee).to.equal(newTradeFee);
        });

        it("Should prevent non-owner from updating fees", async function () {
            await expect(
                thousandXMeme.connect(trader1).setPlatformFees(
                    hre.ethers.parseEther("0.002"),
                    200n
                )
            ).to.be.revertedWithCustomError(thousandXMeme, "OwnableUnauthorizedAccount");
        });

        it("Should allow emergency withdrawal", async function () {
            // Send some ETH to contract
            await owner.sendTransaction({
                to: await thousandXMeme.getAddress(),
                value: hre.ethers.parseEther("1.0")
            });

            const initialBalance = await hre.ethers.provider.getBalance(owner.address);
            await thousandXMeme.connect(owner).emergencyWithdraw();
            const finalBalance = await hre.ethers.provider.getBalance(owner.address);
            
            expect(finalBalance).to.be.gt(initialBalance);
        });
    });

    describe("Platform Stats", function () {
        it("Should track platform statistics", async function () {
            const { factory } = await loadFixture(deployFixture);
            
            // Create a token
            const createFee = await thousandXMeme.getCreateFee();
            await factory.connect(creator).deployToken(
                config.name,
                config.symbol,
                { value: createFee }
            );

            const stats = await thousandXMeme.getPlatformStats();
            expect(stats._totalTokensCreated).to.equal(1);
        });

        it("Should track creator statistics", async function () {
            const { factory } = await loadFixture(deployFixture);
            
            const createFee = await thousandXMeme.getCreateFee();
            await factory.connect(creator).deployToken(
                config.name,
                config.symbol,
                { value: createFee }
            );

            const creatorStats = await thousandXMeme.getCreatorStats(creator.address);
            expect(creatorStats.tokensCreated).to.equal(1);
        });
    });
});