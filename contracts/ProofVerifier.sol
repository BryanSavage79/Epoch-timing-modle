// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract ProofVerifier is Ownable {
    enum ProofStatus { Pending, Valid, Invalid }

    struct ProofRecord {
        bytes32 proofHash;
        address prover;
        uint256 timestamp;
        ProofStatus status;
        string proofType;
    }

    mapping(bytes32 => ProofRecord) public proofs;
    mapping(address => uint256) public proverVerifications;

    event ProofSubmitted(bytes32 indexed proofHash, address indexed prover, string proofType);
    event ProofVerified(bytes32 indexed proofHash, ProofStatus status);

    function submitProof(bytes calldata proofData, string calldata proofType) external {
        bytes32 proofHash = keccak256(proofData);
        require(proofs[proofHash].prover == address(0), "Proof already exists");
        proofs[proofHash] = ProofRecord(
            proofHash,
            msg.sender,
            block.timestamp,
            ProofStatus.Pending,
            proofType
        );
        emit ProofSubmitted(proofHash, msg.sender, proofType);
    }

    function verifyProof(bytes32 proofHash, bool isValid) external onlyOwner {
        ProofRecord storage proof = proofs[proofHash];
        require(proof.prover != address(0), "Proof does not exist");
        require(proof.status == ProofStatus.Pending, "Proof already verified");
        proof.status = isValid ? ProofStatus.Valid : ProofStatus.Invalid;
        if (isValid) {
            proverVerifications[proof.prover]++;
        }
        emit ProofVerified(proofHash, proof.status);
    }

    function verifyProofSignature(
        bytes32 proofHash,
        bytes calldata signature,
        address expectedSigner
    ) external view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(proofHash));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);
        address recoveredSigner = ecrecover(ethSignedMessageHash, v, r, s);
        return recoveredSigner == expectedSigner;
    }

    function splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "Invalid signature length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    function getProof(bytes32 proofHash) external view returns (ProofRecord memory) {
        require(proofs[proofHash].prover != address(0), "Proof does not exist");
        return proofs[proofHash];
    }

    function getProverVerificationCount(address prover) external view returns (uint256) {
        return proverVerifications[prover];
    }
}