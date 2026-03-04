// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract DisputeGame {
    struct Challenge {
        address challenger;
        bytes32 epochRoot;
        uint256 bond;
        bool resolved;
    }

    mapping(bytes32 => Challenge) public challenges;
    uint256 public totalBond;

    event ChallengeCreated(bytes32 indexed epochRoot, address indexed challenger, uint256 bond);
    event ChallengeResolved(bytes32 indexed epochRoot, bool success);

    function createChallenge(bytes32 _epochRoot) external payable {
        require(msg.value > 0, "Bond must be greater than zero.");

        Challenge storage challenge = challenges[_epochRoot];
        require(challenge.challenger == address(0), "Challenge already exists.");

        challenge.challenger = msg.sender;
        challenge.epochRoot = _epochRoot;
        challenge.bond = msg.value;
        challenge.resolved = false;

        totalBond += msg.value;
        emit ChallengeCreated(_epochRoot, msg.sender, msg.value);
    }

    function resolveChallenge(bytes32 _epochRoot, bool _success) external {
        Challenge storage challenge = challenges[_epochRoot];
        require(challenge.challenger != address(0), "No challenge exists.");
        require(!challenge.resolved, "Challenge is already resolved.");

        challenge.resolved = true;
        if (_success) {
            // Logic for successful resolution 
            // You can return the bond or implement further logic
            payable(challenge.challenger).transfer(challenge.bond);
        } else {
            // Logic for unsuccessful resolution 
            // Bond is forfeited; implement your logic here
        }
        emit ChallengeResolved(_epochRoot, _success);
    }
}