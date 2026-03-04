// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract RootHistory {
    struct EpochRoot {
        bytes32 root;
        bool finalized;
    }

    mapping(uint256 => EpochRoot) private epochRoots;
    uint256 public currentEpoch;
    uint256 private mirroredEpoch;

    event RootReceived(uint256 epoch, bytes32 root);

    function receiveRoot(bytes32 root, uint256 epoch, bytes32 historyProof) public {
        require(verifyRootProof(root, historyProof), "Invalid proof");
        require(epoch > mirroredEpoch, "Epoch must be greater than mirroredEpoch");

        epochRoots[epoch] = EpochRoot({root: root, finalized: false});
        currentEpoch = epoch;

        emit RootReceived(epoch, root);
    }

    function verifyRootProof(bytes32 root, bytes32 historyProof) internal view returns (bool) {
        // Implement proof verification logic here.
        return true;
    }

    function getEpochRoot(uint256 epoch) public view returns (bytes32 root, bool finalized) {
        EpochRoot memory epochRoot = epochRoots[epoch];
        return (epochRoot.root, epochRoot.finalized);
    }

    function getCurrentEpoch() public view returns (uint256) {
        return currentEpoch;
    }
}