const { expect } = require("chai");

describe("EpochManager", function () {
    it("Should deploy EpochManager", async function () {
        const EpochManager = await ethers.getContractFactory("EpochManager");
        const epochManager = await EpochManager.deploy();
        await epochManager.deployed();
        expect(epochManager.address).to.be.properAddress;
    });
});

describe("DisputeGame", function () {
    it("Should deploy DisputeGame", async function () {
        const DisputeGame = await ethers.getContractFactory("DisputeGame");
        const disputeGame = await DisputeGame.deploy();
        await disputeGame.deployed();
        expect(disputeGame.address).to.be.properAddress;
    });
});
