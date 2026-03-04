// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract EpochManager is Ownable {
    enum EpochStatus { Active, Inactive }
    struct EpochDescriptor {
        uint256 startTime;
        uint256 endTime;
        EpochStatus status;
    }

    mapping(uint256 => EpochDescriptor) public epochs;
    uint256 public epochCount;

    event EpochCreated(uint256 indexed epochId, uint256 startTime, uint256 endTime);
    event EpochUpdated(uint256 indexed epochId, EpochStatus status);

    function createEpoch(uint256 startTime, uint256 endTime) external onlyOwner {
        require(startTime < endTime, "Start time must be before end time");
        epochs[epochCount] = EpochDescriptor(startTime, endTime, EpochStatus.Active);
        emit EpochCreated(epochCount, startTime, endTime);
        epochCount++;
    }

    function updateEpoch(uint256 epochId, EpochStatus status) external onlyOwner {
        require(epochId < epochCount, "Epoch does not exist");
        epochs[epochId].status = status;
        emit EpochUpdated(epochId, status);
    }

    function getEpochDescriptor(uint256 epochId) external view returns (EpochDescriptor memory) {
        require(epochId < epochCount, "Epoch does not exist");
        return epochs[epochId];
    }
}