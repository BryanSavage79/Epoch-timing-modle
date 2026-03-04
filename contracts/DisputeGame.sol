// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract DisputeGame {
    struct Dispute {
        address challenger;
        address defender;
        uint bond;
        uint defenseWindow;
        uint resolutionTime;
        bool resolved;
    }

    mapping(uint => Dispute) public disputes;
    uint public disputeCount;

    event DisputeCreated(uint disputeId, address challenger, address defender, uint bond);
    event DisputeResolved(uint disputeId, bool verdict);

    function createDispute(address defender, uint defenseWindow) public payable {
        require(msg.value > 0, "Bond must be greater than 0");

        disputeCount++;
        disputes[disputeCount] = Dispute(msg.sender, defender, msg.value, defenseWindow, block.timestamp + defenseWindow, false);

        emit DisputeCreated(disputeCount, msg.sender, defender, msg.value);
    }

    function resolveDispute(uint disputeId, bool verdict) public {
        Dispute storage dispute = disputes[disputeId];
        require(msg.sender == dispute.challenger || msg.sender == dispute.defender, "Not authorized");
        require(!dispute.resolved, "Dispute has already been resolved");

        dispute.resolved = true;
        if (verdict) {
            payable(dispute.challenger).transfer(dispute.bond);
        } else {
            payable(dispute.defender).transfer(dispute.bond);
        }

        emit DisputeResolved(disputeId, verdict);
    }

    function isInDefenseWindow(uint disputeId) public view returns (bool) {
        return block.timestamp < disputes[disputeId].resolutionTime;
    }
}