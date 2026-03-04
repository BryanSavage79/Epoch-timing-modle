// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utilities/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EpochManager is Pausable, Ownable {
    struct Epoch {
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    mapping(uint256 => Epoch) public epochs;
    uint256 public currentEpochID;

    event EpochCreated(uint256 indexed epochID, uint256 startTime, uint256 endTime);
    event EpochActivated(uint256 indexed epochID);
    event EpochDeactivated(uint256 indexed epochID);

    function createEpoch(uint256 _duration) external onlyOwner whenNotPaused {
        currentEpochID++;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + _duration;

        epochs[currentEpochID] = Epoch({
            startTime: startTime,
            endTime: endTime,
            active: true
        });

        emit EpochCreated(currentEpochID, startTime, endTime);
    }

    function activateEpoch(uint256 _epochID) external onlyOwner whenPaused {
        require(epochs[_epochID].active == false, "Epoch is already active.");
        epochs[_epochID].active = true;
        emit EpochActivated(_epochID);
        _unpause();
    }

    function deactivateEpoch(uint256 _epochID) external onlyOwner {
        require(epochs[_epochID].active == true, "Epoch is already inactive.");
        epochs[_epochID].active = false;
        emit EpochDeactivated(_epochID);
        _pause();
    }

    function isActive(uint256 _epochID) external view returns (bool) {
        return epochs[_epochID].active;
    }

    function currentEpoch() external view returns (Epoch memory) {
        return epochs[currentEpochID];
    }
}