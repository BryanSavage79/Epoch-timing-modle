// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract IndexerStaking {
    struct Stake {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => Stake) public stakes;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public isSlashed;

    uint256 public totalStaked;
    uint256 public rewardRate; // e.g., 10% annual reward

    constructor(uint256 _rewardRate) {
        rewardRate = _rewardRate;
    }

    function stake(uint256 amount) public {
        require(amount > 0, "Amount must be greater than zero");
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].timestamp = block.timestamp;
        totalStaked += amount;
        // Transfer the staked amount to the contract (requires ERC20 implementation)
    }

    function unStake(uint256 amount) public {
        require(stakes[msg.sender].amount >= amount, "Not enough staked");
        stakes[msg.sender].amount -= amount;
        totalStaked -= amount;
        // Transfer the unstaked amount back to the user (requires ERC20 implementation)
    }

    function calculateReward(address staker) public view returns (uint256) {
        Stake memory stakeInfo = stakes[staker];
        uint256 timeStaked = block.timestamp - stakeInfo.timestamp;
        return (stakeInfo.amount * rewardRate * timeStaked) / (365 days * 100);
    }

    function submitProof(bytes32 proof) public {
        // Implement proof submission logic
    }

    function slash(address staker) public {
        require(!isSlashed[staker], "Already slashed");
        isSlashed[staker] = true;
        stakes[staker].amount = 0; // Slashing the stake
    }

    function claimReward() public {
        uint256 reward = calculateReward(msg.sender);
        rewards[msg.sender] += reward;
        // Transfer the reward to the user (requires ERC20 implementation)
    }
}