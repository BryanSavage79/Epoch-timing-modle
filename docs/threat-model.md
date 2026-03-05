# Full Threat Model: Epoch Timing Model — Proposer Censorship and Resilience

*Date: 2026-03-05*  
*Status: Draft — Prepared for audit review and future formal verification*

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Scope and Trust Boundaries](#2-system-scope-and-trust-boundaries)
3. [Invariant and Defense Catalogue](#3-invariant-and-defense-catalogue)
4. [Attack Vector Enumeration](#4-attack-vector-enumeration)
   - 4.1 [Proposer and Sequencer Censorship](#41-proposer-and-sequencer-censorship)
   - 4.2 [Byzantine Validator / Proposer Behavior](#42-byzantine-validator--proposer-behavior)
   - 4.3 [Economic Attacks](#43-economic-attacks)
   - 4.4 [Cross-Chain Replay Attacks](#44-cross-chain-replay-attacks)
   - 4.5 [Liveness Attacks](#45-liveness-attacks)
   - 4.6 [Data Withholding Attacks](#46-data-withholding-attacks)
   - 4.7 [Timing and Clock Manipulation Attacks](#47-timing-and-clock-manipulation-attacks)
   - 4.8 [Smart Contract Logic Attacks](#48-smart-contract-logic-attacks)
   - 4.9 [Network-Level Attacks (Eclipse, Sybil)](#49-network-level-attacks-eclipse-sybil)
5. [Defense Mapping Matrix](#5-defense-mapping-matrix)
6. [Residual Risk Register](#6-residual-risk-register)
7. [External References](#7-external-references)
8. [Auditor Review Checklist](#8-auditor-review-checklist)

---

## 1. Executive Summary

The Epoch Timing Model is a distributed, on-chain coordination system comprising five smart contracts (`EpochManager`, `RootHistory`, `DisputeGame`, `ProofVerifier`, `IndexerStaking`) that collectively manage epoch lifecycle, root-history proofs, dispute resolution, and indexer economics. Because epochs govern time-sensitive operations across potentially multiple chains, the system is a high-value target for censorship, griefing, Byzantine manipulation, and economic exploitation.

This document formalises every realistic attack vector, maps each vector to the architectural and invariant-level defences already present in the codebase (S1–S4, T1–T3, E1–E2, pause, circuit-breaker), identifies residual risk, and provides a structured checklist for auditors preparing the codebase for formal verification.

---

## 2. System Scope and Trust Boundaries

### 2.1 Components in Scope

| Component | Role | Key State |
|---|---|---|
| `EpochManager` | Creates and activates/deactivates epochs | `epochCount`, `epochs[]` |
| `RootHistory` | Receives and stores epoch root hashes | `epochRoots[]`, `currentEpoch`, `mirroredEpoch` |
| `DisputeGame` | Manages bond-backed challenge/response | `disputes[]`, bond balances |
| `ProofVerifier` | Verifies indexer proof submissions | `proofs[]`, `proverVerifications[]` |
| `IndexerStaking` | Manages staking, rewards, and slashing | `stakes[]`, `totalStaked`, `isSlashed[]` |

### 2.2 Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│  L1 / Settlement Layer (fully trusted; replay-protected by EIP-155)│
│  ┌──────────────┐   ┌────────────────┐   ┌──────────────────┐  │
│  │ EpochManager │   │  RootHistory   │   │  DisputeGame     │  │
│  └──────┬───────┘   └───────┬────────┘   └────────┬─────────┘  │
│         │                   │                      │            │
│  ┌──────┴───────────────────┴──────────────────────┴─────────┐  │
│  │                   ProofVerifier                           │  │
│  └──────────────────────────┬────────────────────────────────┘  │
│                             │                                   │
│  ┌──────────────────────────┴────────────────────────────────┐  │
│  │                   IndexerStaking                          │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         ▲                      ▲                     ▲
         │                      │                     │
   Permissioned             Indexers /           Challengers /
   Owner / Admin            Proposers            Validators
   (untrusted role)       (untrusted role)      (untrusted role)
```

**Untrusted actors**:
- **Owner/Admin**: May be a multisig or EOA; malicious owner is a governance attack vector.
- **Indexers / Proposers**: Incentivised, but assumed potentially Byzantine.
- **Challengers**: Bond-constrained, but assumed potentially adversarial.
- **Network layer**: Block proposers and sequencers on both L1 and L2 are assumed to be capable of transaction censorship.

---

## 3. Invariant and Defense Catalogue

The following invariants and mechanisms are referenced throughout the attack-vector analysis. They are referenced by their short codes.

### 3.1 State Invariants (S1–S4)

| Code | Invariant | Enforcing Contract / Check |
|---|---|---|
| **S1** | Epoch IDs are strictly monotonically increasing: `epochCount` is only ever incremented, never decremented or overwritten. | `EpochManager.createEpoch` — `epochCount++` |
| **S2** | Every active epoch satisfies `startTime < endTime`. A zero-length or negative-length epoch can never be created. | `EpochManager.createEpoch` — `require(startTime < endTime)` |
| **S3** | Root submissions to `RootHistory` can only advance the epoch cursor: `epoch > mirroredEpoch`. Historical roots cannot be silently overwritten. | `RootHistory.receiveRoot` — `require(epoch > mirroredEpoch)` |
| **S4** | A slashed indexer's stake is zeroed and cannot be re-counted toward `totalStaked` or further reward calculations. The `isSlashed` flag is write-once (true). | `IndexerStaking.slash` |

### 3.2 Temporal Properties (T1–T3)

| Code | Property | Enforcing Contract / Check |
|---|---|---|
| **T1** | A dispute can only be resolved by the challenger or defender, and the resolution time (`block.timestamp + defenseWindow`) must be respected before finalisation. | `DisputeGame.resolveDispute`, `isInDefenseWindow` |
| **T2** | Epoch transitions are causally ordered: a new epoch can only reference a prior epoch that already exists in `EpochManager` (epochId < epochCount). | `EpochManager.updateEpoch` — `require(epochId < epochCount)` |
| **T3** | Proof records are timestamped at submission (`block.timestamp`) and cannot be back-dated or have their timestamp mutated. | `ProofVerifier.submitProof` — immutable `timestamp` field |

### 3.3 Economic Properties (E1–E2)

| Code | Property | Enforcing Contract / Check |
|---|---|---|
| **E1** | Every dispute must be backed by a non-zero ETH bond (`msg.value > 0`). This deters spam challenges and ensures challengers bear financial risk. | `DisputeGame.createDispute` — `require(msg.value > 0)` |
| **E2** | Staking rewards are time-weighted: `reward = amount × rate × timeStaked / (365 days × 100)`. Attackers cannot manufacture artificial rewards without holding stake over time. | `IndexerStaking.calculateReward` |

### 3.4 Operational Controls

| Code | Control | Description |
|---|---|---|
| **PAUSE** | Emergency pause | The `Ownable` pattern on `EpochManager` and `ProofVerifier` allows the owner to halt sensitive state-mutating operations during an active incident. A pause mechanism should be explicitly implemented (see §6 Residual Risk). |
| **CIRCUIT-BREAKER** | Automatic halting on anomaly | Rate-limiting or a maximum-epoch-advance-per-block guard to prevent epoch-flooding attacks. Currently absent; recommended for implementation (see §6). |
| **RBAC** | Role-Based Access Control | Owner-gated functions (`createEpoch`, `verifyProof`) restrict critical operations to a single privileged address. Multisig governance is recommended. |

---

## 4. Attack Vector Enumeration

### 4.1 Proposer and Sequencer Censorship

#### 4.1.1 Transaction Censorship — Challenge Suppression

**Description**: A malicious block proposer (on L1) or sequencer (on an L2 rollup) selectively drops or delays transactions that would create a dispute against a misbehaving indexer. If the challenger's `createDispute` transaction does not land before the challenge deadline, the indexer's invalid root goes unchallenged and reaches finality.

**Impact**: High — finalisation of incorrect epoch roots; economic loss for honest participants.

**Defences Mapped**:
- **T1**: Defense window is enforced on-chain; the window must be sufficiently long (≥ 7 days on Ethereum mainnet) to survive short-duration censorship.
- **E1**: Because posting a bond is required, the censorship cost is the attacker's opportunity cost vs. the challenger's bond size.

**Residual Risk**: A sequencer on an L2 can sustainably censor indefinitely. Mitigation requires a censorship-escape hatch (e.g., L1 force-inclusion) or an optimistic rollup delayed-inbox mechanism.

**Recommended Mitigation**:
- Integrate L1 force-inclusion inbox (see Arbitrum Delayed Inbox reference in §7).
- Set `defenseWindow` to at least 7 days to allow alternative transaction routing.
- Emit an on-chain `ChallengeDeadlineWarning` event N blocks before expiry to incentivise watchers.

---

#### 4.1.2 Epoch Root Censorship — Root Submission Blocking

**Description**: A proposer censors transactions that call `RootHistory.receiveRoot`. If a valid root cannot be submitted on time, dependent systems (e.g., optimistic proofs) stall and the epoch cursor (`currentEpoch`) falls behind.

**Impact**: Medium-High — delayed epoch progression; denial of service for downstream consumers.

**Defences Mapped**:
- **S3**: Even delayed roots maintain ordering integrity once submitted.
- **T2**: Monotonic epoch ID prevents gap attacks.

**Recommended Mitigation**:
- Allow multiple designated root submitters (multi-party submission).
- Implement a backup submission path via L1 if the primary route is L2-only.

---

### 4.2 Byzantine Validator / Proposer Behavior

#### 4.2.1 Invalid Epoch Root Submission

**Description**: A Byzantine indexer submits a fraudulent `bytes32 root` to `RootHistory.receiveRoot` with a forged or vacuous `historyProof`. The current `verifyRootProof` implementation always returns `true` (placeholder), meaning any root is accepted.

**Impact**: Critical — the entire dispute game rests on the assumption that roots are valid. A false root enables false proofs and unjust slashing or reward claims.

**Defences Mapped**:
- **S3**: Monotonic epoch cursor prevents replaying an old root.
- **DisputeGame**: Honest parties can challenge a false root using `createDispute`.

**Residual Risk**: `verifyRootProof` is a stub returning `true`. This is the highest-priority finding for the audit.

**Recommended Mitigation**:
- Implement cryptographic Merkle proof verification in `verifyRootProof`.
- Until implemented, gate `receiveRoot` behind a multi-sig or a committee quorum.

---

#### 4.2.2 Dispute Griefing — Premature or Duplicate Resolution

**Description**: Either party in a dispute calls `resolveDispute` before the defense window expires, or attempts to resolve a dispute multiple times to drain bond funds via reentrancy.

**Impact**: Medium — premature resolution denies the defending party time to respond; reentrancy could drain contract ETH balance.

**Defences Mapped**:
- **T1**: `isInDefenseWindow` is a public view; on-chain check in `resolveDispute` should enforce this.
- **S4 analogy**: `dispute.resolved = true` (write-once flag) prevents double resolution.

**Residual Risk**: `resolveDispute` does not currently check `isInDefenseWindow` before allowing resolution. A reentrancy guard (`nonReentrant`) is absent.

**Recommended Mitigation**:
- Add `require(!isInDefenseWindow(disputeId), "Defense window still open")` in `resolveDispute`.
- Apply OpenZeppelin `ReentrancyGuard` to `resolveDispute` and `createDispute`.

---

#### 4.2.3 Malicious Owner — Unilateral Epoch Manipulation

**Description**: If the `EpochManager` owner key is compromised or acts maliciously, the attacker can create epochs with arbitrary time ranges, or deactivate all epochs to halt the system.

**Impact**: High — arbitrary epoch state; full system halt.

**Defences Mapped**:
- **RBAC**: `onlyOwner` restricts epoch creation to a single key.

**Residual Risk**: Single-key ownership is a critical centralisation risk.

**Recommended Mitigation**:
- Migrate ownership to a multi-sig (e.g., Gnosis Safe with a 3-of-5 threshold).
- Add a time-lock (minimum 48-hour delay) on critical epoch management operations.

---

### 4.3 Economic Attacks

#### 4.3.1 Bond Dust Attack — Spam Dispute Flooding

**Description**: An attacker submits a large number of `createDispute` calls with a minimal bond (e.g., 1 wei). This floods the `disputes[]` mapping, increasing gas costs for honest parties searching for active disputes, and may stress the indexer's off-chain monitoring infrastructure.

**Impact**: Low-Medium — operational disruption; increased gas costs.

**Defences Mapped**:
- **E1**: `msg.value > 0` prevents zero-bond disputes, but 1 wei is effectively free at scale.

**Recommended Mitigation**:
- Enforce a minimum bond floor (e.g., `MIN_BOND = 0.01 ETH`) as a contract constant.
- Implement per-challenger dispute rate limiting (maximum N open disputes per address).

---

#### 4.3.2 Stake Inflation — Reward Rate Manipulation

**Description**: An attacker stakes a large amount immediately before `claimReward` is invoked, then unstakes immediately after, attempting to claim disproportionate rewards relative to their holding period.

**Impact**: Medium — economic imbalance; honest stakers receive diluted rewards.

**Defences Mapped**:
- **E2**: Time-weighted reward formula ensures rewards scale with `timeStaked`.

**Residual Risk**: The timestamp used is `stakes[msg.sender].timestamp`, which resets on every `stake` call. An attacker who already holds stake can add more stake and call `claimReward` immediately, earning reward only on the new stake duration but potentially manipulating the pooled `totalStaked` for others.

**Recommended Mitigation**:
- Use a checkpoint-based reward accrual model (e.g., snapshot rewards at each stake/unstake event).
- Enforce a minimum staking lockup period before rewards are claimable.

---

#### 4.3.3 Slashing Race Condition — Stake Escape Before Slash

**Description**: An indexer that detects an impending `slash` call front-runs it with an `unStake` transaction to withdraw funds before the slash takes effect.

**Impact**: High — slashing becomes economically ineffective; misbehaving indexers escape punishment.

**Defences Mapped**:
- **S4**: `isSlashed` flag set before stake zeroing in `slash`.

**Residual Risk**: `unStake` does not check `isSlashed`. An indexer can call `unStake` before `slash` lands.

**Recommended Mitigation**:
- Add `require(!isSlashed[msg.sender], "Cannot unstake: slashed")` in `unStake`.
- Implement an unstaking delay / unbonding period (e.g., 7 days) to prevent front-running escapes.

---

#### 4.3.4 Challenger Bond Theft via Verdict Manipulation

**Description**: In `DisputeGame.resolveDispute`, either the challenger or defender can call the function and set `verdict` to any value. A malicious caller can set `verdict = true` even if they are the defender, awarding the bond to the challenger (themselves if self-challenging) or vice versa.

**Impact**: High — theft of dispute bonds.

**Defences Mapped**:
- **E1**: Bond must be non-zero to enter the game.

**Residual Risk**: The verdict is controlled by whichever party calls `resolveDispute`. There is no neutral arbitration or oracle involved in the current implementation.

**Recommended Mitigation**:
- Route verdict decisions through `ProofVerifier` or an on-chain oracle/committee.
- Require the defending party to submit a counter-proof; absent a valid counter-proof within the window, default to challenger winning.

---

### 4.4 Cross-Chain Replay Attacks

#### 4.4.1 Root Replay Across Chains

**Description**: A `bytes32 root` submitted to `RootHistory` on chain A is replayed verbatim on chain B (a testnet, another L2, or a forked chain). If `historyProof` verification is weak or absent, the root is accepted on chain B, unlocking rewards or proof credits that were not legitimately earned.

**Impact**: Medium-High — double-spending of epoch roots across chains.

**Defences Mapped**:
- **S3**: Monotonic epoch constraint limits replay to only strictly newer epochs on each chain.

**Residual Risk**: The contract does not embed a `chainId` or domain separator in the root or proof, so a root from chain A is structurally identical to a root on chain B.

**Recommended Mitigation**:
- Include `block.chainid` in the root commitment hash: `commitment = keccak256(abi.encodePacked(root, block.chainid, epoch))`.
- Use EIP-712 typed structured data with a domain separator for all signed messages in `ProofVerifier`.

---

#### 4.4.2 Proof Signature Replay

**Description**: `ProofVerifier.verifyProofSignature` recovers a signer from an Ethereum signed message, but does not check a nonce, expiry, or chain ID. A valid proof signature produced on one chain or at one point in time can be replayed on another chain or re-submitted after the original proof is invalidated.

**Impact**: Medium — fraudulent proof credit accumulation.

**Defences Mapped**:
- **T3**: Proof timestamps are recorded, but there is no expiry enforcement.

**Recommended Mitigation**:
- Add `uint256 chainId`, `uint256 nonce`, and `uint256 expiry` fields to the signed message in `verifyProofSignature`.
- Adopt EIP-712 domain separation (`DOMAIN_SEPARATOR` including `chainId` and `verifyingContract`).

---

### 4.5 Liveness Attacks

#### 4.5.1 Owner Key Loss / Lockout

**Description**: If the private key controlling `EpochManager` or `ProofVerifier` (both `Ownable`) is lost, no new epochs can be created and no proofs can be verified. The system enters a permanent halt.

**Impact**: Critical — total system liveness failure.

**Defences Mapped**:
- **RBAC**: Owner is the sole gatekeeper.

**Recommended Mitigation**:
- Deploy ownership behind a multi-sig with social recovery.
- Implement `renounceOwnership` protection: prevent renouncing without a successor designated.
- Consider a DAO governance module for epoch management in a sufficiently decentralised deployment.

---

#### 4.5.2 Epoch Starvation — No Epoch Created

**Description**: If the owner never calls `createEpoch`, dependent contracts (`RootHistory`, `DisputeGame`) have no epoch context to operate against. Alternatively, the owner creates epochs with start times far in the future, starving the system of active epochs.

**Impact**: Medium — indefinite liveness delay.

**Defences Mapped**:
- **S2**: `startTime < endTime` prevents trivially invalid epochs.

**Recommended Mitigation**:
- Implement an auto-epoch-renewal mechanism triggered by any participant after a timeout.
- Emit `EpochStarvationAlert` if no epoch is active for more than N blocks.

---

#### 4.5.3 Defense Window Expiry Without Resolution

**Description**: An honest challenger submits a dispute but the defender never responds. After `resolutionTime` passes, the dispute remains unresolved (neither party calls `resolveDispute`), locking the bond indefinitely in the contract.

**Impact**: Medium — bond funds permanently locked; challenge mechanism fails to reach finality.

**Defences Mapped**:
- **T1**: Defense window is tracked on-chain.

**Residual Risk**: There is no automatic resolution or timeout-triggered verdict.

**Recommended Mitigation**:
- Add a `finaliseByTimeout(uint disputeId)` function that, after `resolutionTime` has passed, awards the bond to the challenger if the defender has not submitted a valid counter-proof.

---

### 4.6 Data Withholding Attacks

#### 4.6.1 Indexer Withholds Epoch Data Off-Chain

**Description**: An indexer submits a root to `RootHistory` but withholds the underlying data (transaction list, state diff) needed to verify or challenge the root. Since `verifyRootProof` does not enforce data availability, the root is accepted on-chain while challengers cannot construct a valid counter-proof.

**Impact**: High — unverifiable roots reach finality; data unavailability undermines the entire dispute game.

**Defences Mapped**:
- **DisputeGame**: Challengers can open a dispute, but without the underlying data, they cannot produce evidence.

**Residual Risk**: The current design has no on-chain data availability check or sampling mechanism.

**Recommended Mitigation**:
- Integrate a data availability committee (DAC) or a sampling-based scheme (e.g., Danksharding blob references, EIP-4844).
- Require indexers to post a content-addressed data commitment alongside the root; `receiveRoot` should verify the commitment resolves to accessible data before accepting.
- Consider a fisherman model where any party can flag unavailability and pause the epoch.

---

#### 4.6.2 Proof Withholding — Silent Indexer

**Description**: An indexer that controls proof submission withholds proofs from `ProofVerifier` during a specific epoch, preventing other participants from verifying the epoch's integrity. This can be used to delay finalisation deliberately.

**Impact**: Medium — epoch finalisation delay; downstream system stall.

**Recommended Mitigation**:
- Allow any permissioned prover (not solely the indexer) to submit proofs for a given epoch after a timeout.
- Implement `prover fallback`: if no proof arrives within N blocks, allow a committee to submit a default validity assertion.

---

### 4.7 Timing and Clock Manipulation Attacks

#### 4.7.1 Block Timestamp Manipulation

**Description**: Ethereum block proposers can adjust `block.timestamp` by up to ~900 seconds (15 minutes) within protocol rules. An attacker who controls block production can skew timestamps to:
- Prematurely expire a defense window (`T1`), resolving a dispute in their favour.
- Make an epoch appear to have started or ended earlier/later than reality.

**Impact**: Medium — incorrect temporal ordering; premature dispute resolution.

**Defences Mapped**:
- **T1, T2, T3**: All temporal checks rely on `block.timestamp`.

**Recommended Mitigation**:
- Use block numbers as the primary liveness timer (e.g., `defenseWindow` measured in blocks, not seconds) for greater manipulation resistance.
- Add a minimum and maximum `block.timestamp` sanity check relative to the previous block's timestamp.

---

#### 4.7.2 MEV / Front-Running on Epoch Transitions

**Description**: Searchers with MEV bots monitor the mempool for `createEpoch` or `receiveRoot` transactions and front-run them with conflicting state changes (e.g., posting a competing root at the same epoch ID via a different call path, or staking large amounts to collect epoch-transition rewards).

**Impact**: Low-Medium — economic extraction; ordering manipulation.

**Defences Mapped**:
- **S1, S3**: Monotonic IDs prevent duplicate epoch or root creation.
- **E2**: Time-weighted staking limits single-block stake manipulation.

**Recommended Mitigation**:
- Use a commit-reveal scheme for sensitive submissions.
- For root submissions, require a minimum number of confirmations before the root is considered "received."

---

### 4.8 Smart Contract Logic Attacks

#### 4.8.1 Reentrancy in DisputeGame Bond Disbursement

**Description**: `resolveDispute` calls `payable(address).transfer()` without a reentrancy guard. If the recipient is a malicious contract with a fallback function, it can re-enter `resolveDispute` before `dispute.resolved = true` is set, claiming the bond multiple times.

**Impact**: High — complete ETH drain of `DisputeGame`.

**Defences Mapped**:
- **S4 analogy**: `dispute.resolved = true` is set before `transfer`, which provides partial protection via checks-effects-interactions pattern (currently the resolved flag IS set before transfer — this is correct).

**Residual Risk**: The current code sets `dispute.resolved = true` before calling `transfer`, which follows the checks-effects-interactions pattern. However, explicit `ReentrancyGuard` should still be applied as defence-in-depth against future code changes.

**Recommended Mitigation**:
- Apply `ReentrancyGuard` from OpenZeppelin.
- Replace `transfer` with `call{value: ...}("")` with return value check (gas stipend of 2300 in `transfer` can cause failures with smart contract wallets).

---

#### 4.8.2 Integer Overflow / Underflow in Staking Arithmetic

**Description**: Solidity 0.8.x provides built-in overflow protection, but reward calculations using `amount * rewardRate * timeStaked` may overflow for extreme values before the division is applied.

**Impact**: Low (mitigated by Solidity 0.8.x) — potential revert on large values.

**Recommended Mitigation**:
- Document maximum expected `rewardRate` and `amount` values.
- Add input validation: `require(amount <= MAX_STAKE_AMOUNT)` and `require(rewardRate <= MAX_REWARD_RATE)`.

---

#### 4.8.3 Epoch ID Collision via epochCount Overflow

**Description**: If `epochCount` overflows `uint256`, it wraps to zero, potentially overwriting epoch 0's data. This is a theoretical concern only for `uint256` (would require 2^256 epochs).

**Impact**: Negligible — `uint256` space is astronomically large.

**Defences Mapped**:
- **S1**: Solidity 0.8.x reverts on overflow.

---

### 4.9 Network-Level Attacks (Eclipse, Sybil)

#### 4.9.1 Eclipse Attack on Indexer Node

**Description**: An attacker eclipses an honest indexer's network connections, feeding it a manipulated view of the blockchain. The indexer may submit roots or proofs based on a false chain state, which can be challenged and slashed.

**Impact**: Medium — honest indexer slashed due to manipulated view.

**Defences Mapped**:
- **DisputeGame**: An eclipsed indexer's false submission can be challenged.
- **S4**: Once slashed, the indexer cannot further harm the system.

**Recommended Mitigation**:
- Indexers should connect to multiple independent RPC endpoints (diverse client implementations).
- Use light-client proofs or trusted execution environments to verify chain state before root submission.

---

#### 4.9.2 Sybil Attack on Dispute Participation

**Description**: An attacker creates many addresses to participate in community-based dispute resolution, overwhelming honest votes in a decentralised voting resolution path.

**Impact**: Medium — governance capture in voting-based resolution.

**Defences Mapped**:
- **E1**: Bond requirements per dispute deter cheap sybil participation.

**Recommended Mitigation**:
- Weight dispute voting by staked tokens rather than address count.
- Require a minimum stake threshold for dispute participation.

---

## 5. Defense Mapping Matrix

The following matrix cross-references each attack vector with the defences that apply (✓ = defence applies, ⚠ = partial defence, ✗ = no current defence).

| Attack Vector | S1 | S2 | S3 | S4 | T1 | T2 | T3 | E1 | E2 | PAUSE | CIRCUIT-BREAKER |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 4.1.1 Challenge Suppression | | | | | ✓ | | | ✓ | | ✓ | |
| 4.1.2 Root Submission Blocking | | | ✓ | | | ✓ | | | | ✓ | ⚠ |
| 4.2.1 Invalid Root Submission | | | ✓ | | | | | | | | |
| 4.2.2 Dispute Griefing | | | | ✓ | ✓ | | | | | | |
| 4.2.3 Malicious Owner | | | | | | | | | | ✓ | |
| 4.3.1 Bond Dust / Spam | | | | | | | | ✓ | | | ⚠ |
| 4.3.2 Stake Inflation | | | | | | | | | ✓ | | |
| 4.3.3 Slash Escape | | | | ✓ | | | | | | | |
| 4.3.4 Verdict Manipulation | | | | | | | | ✓ | | | |
| 4.4.1 Root Replay (Cross-Chain) | | | ✓ | | | | | | | | |
| 4.4.2 Proof Signature Replay | | | | | | | ✓ | | | | |
| 4.5.1 Owner Key Loss | | | | | | | | | | ✓ | |
| 4.5.2 Epoch Starvation | | ✓ | | | | | | | | | |
| 4.5.3 Bond Lock (No Resolution) | | | | | ✓ | | | | | | |
| 4.6.1 Data Withholding (Root) | | | | | | | | | | | |
| 4.6.2 Proof Withholding | | | | | | | ✓ | | | | |
| 4.7.1 Timestamp Manipulation | | | | | ✓ | ✓ | ✓ | | | | |
| 4.7.2 MEV / Front-Running | ✓ | | ✓ | | | | | | ✓ | | |
| 4.8.1 Reentrancy in DisputeGame | | | | ✓ | | | | | | | |
| 4.8.2 Arithmetic Overflow | | | | | | | | | | | |
| 4.9.1 Eclipse Attack | | | | ✓ | | | | | | | |
| 4.9.2 Sybil in Voting | | | | | | | | ✓ | | | |

---

## 6. Residual Risk Register

The following items represent gaps where current defences are **absent or insufficient**. Each item is a recommended action for the next development sprint and audit cycle.

| ID | Risk | Severity | Recommended Action |
|---|---|---|---|
| RR-01 | `verifyRootProof` always returns `true` (stub) | **Critical** | Implement Merkle/ZK proof verification before mainnet deployment |
| RR-02 | `resolveDispute` allows resolution during defense window | **High** | Add `require(!isInDefenseWindow(disputeId))` to `resolveDispute` |
| RR-03 | No reentrancy guard on bond disbursement | **High** | Apply `ReentrancyGuard` to `DisputeGame` |
| RR-04 | `unStake` does not check `isSlashed` | **High** | Add `require(!isSlashed[msg.sender])` in `unStake` |
| RR-05 | Single-key ownership of `EpochManager` and `ProofVerifier` | **High** | Migrate to multi-sig with time-lock |
| RR-06 | No chain ID in root commitment or proof signature | **High** | Embed `block.chainid` in all cross-chain commitments; adopt EIP-712 |
| RR-07 | No minimum bond floor for disputes | **Medium** | Set `MIN_BOND` constant; enforce in `createDispute` |
| RR-08 | No unstaking delay (stake-escape before slash) | **Medium** | Implement 7-day unbonding period |
| RR-09 | No data availability commitment on root submission | **Medium** | Require a DA commitment alongside each root |
| RR-10 | No timeout-based auto-resolution for expired disputes | **Medium** | Implement `finaliseByTimeout` function |
| RR-11 | Block-timestamp used as sole liveness reference | **Medium** | Supplement with block-number-based windows |
| RR-12 | Explicit pause/circuit-breaker not implemented | **Medium** | Add OpenZeppelin `Pausable` to all state-mutating contracts |
| RR-13 | No formal verification of S1–S4, T1–T3, E1–E2 | **Low** | Engage Certora/Halmos for property-based verification (linked issue) |

---

## 7. External References

The following published research and documentation informed the threat model:

1. **Sequencer-Level Security — arXiv**  
   *"SoK: Security of Rollup Solutions for Ethereum"* — covers sequencer censorship, liveness failures, and cross-chain replay in optimistic and ZK rollups.  
   URL: [https://arxiv.org/abs/2210.16272](https://arxiv.org/abs/2210.16272)

2. **Arbitrum Docs: Sequencer and Censorship Resistance**  
   Describes the Arbitrum Delayed Inbox mechanism that provides a censorship escape hatch for users whose transactions are suppressed by the sequencer.  
   URL: [https://docs.arbitrum.io/how-arbitrum-works/sequencer](https://docs.arbitrum.io/how-arbitrum-works/sequencer)

3. **ChainSafe: Censorship Resistance on Ethereum**  
   Analysis of proposer-builder separation (PBS), OFAC compliance pressures, and mechanisms for maintaining censorship resistance at the base layer.  
   URL: [https://chainsafe.io/posts/analysis-of-ethereum-censorship-resistance](https://chainsafe.io/posts/analysis-of-ethereum-censorship-resistance)

4. **Ethereum EIP-155: Simple Replay Attack Protection**  
   Specification for chain-ID-based transaction replay protection; foundational for cross-chain security considerations.  
   URL: [https://eips.ethereum.org/EIPS/eip-155](https://eips.ethereum.org/EIPS/eip-155)

5. **Ethereum EIP-712: Typed Structured Data Hashing and Signing**  
   Specification for domain-separated signed messages; recommended for proof signature protection in `ProofVerifier`.  
   URL: [https://eips.ethereum.org/EIPS/eip-712](https://eips.ethereum.org/EIPS/eip-712)

6. **OpenZeppelin Security: Reentrancy Attacks**  
   Canonical description of reentrancy patterns and mitigation via `ReentrancyGuard` and checks-effects-interactions.  
   URL: [https://docs.openzeppelin.com/contracts/4.x/api/security#ReentrancyGuard](https://docs.openzeppelin.com/contracts/4.x/api/security#ReentrancyGuard)

7. **Trail of Bits: Slither — Ethereum Smart Contract Static Analysis**  
   Recommended automated analysis tool for identifying reentrancy, access control, and arithmetic vulnerabilities in the contracts in scope.  
   URL: [https://github.com/crytic/slither](https://github.com/crytic/slither)

8. **Immunefi: Ethereum Validator Censorship and MEV**  
   Detailed analysis of MEV-driven censorship, front-running, and sandwich attacks relevant to epoch transition and proof submission ordering.  
   URL: [https://immunefi.com/blog/mev-censorship-and-front-running](https://immunefi.com/blog/mev-censorship-and-front-running)

---

## 8. Auditor Review Checklist

The following checklist is structured for audit teams reviewing this system prior to formal verification or mainnet deployment. Each item maps to an attack vector or residual risk identified above.

### 8.1 Critical — Must Fix Before Deployment

- [ ] **[RR-01]** Confirm `verifyRootProof` in `RootHistory` performs actual cryptographic verification and is not a stub returning `true`.
- [ ] **[RR-02]** Confirm `DisputeGame.resolveDispute` reverts if called while `isInDefenseWindow(disputeId)` is `true`.
- [ ] **[RR-03]** Confirm `DisputeGame` is protected by a `ReentrancyGuard` on all fund-moving functions.
- [ ] **[RR-04]** Confirm `IndexerStaking.unStake` reverts for slashed addresses (`isSlashed[msg.sender] == true`).
- [ ] **[RR-05]** Confirm `EpochManager` and `ProofVerifier` ownership is held by a multi-sig with an enforced time-lock; single-EOA ownership is not acceptable.
- [ ] **[RR-06]** Confirm all signed messages and root commitments include `block.chainid` or an EIP-712 domain separator to prevent cross-chain replay.

### 8.2 High — Fix in Next Sprint

- [ ] **[RR-07]** Confirm `DisputeGame.createDispute` enforces a minimum bond (e.g., `MIN_BOND ≥ 0.01 ETH`).
- [ ] **[RR-08]** Confirm `IndexerStaking.unStake` enforces an unbonding delay (≥ 7 days) to prevent pre-slash stake withdrawal.
- [ ] **[RR-09]** Confirm `RootHistory.receiveRoot` requires a data availability commitment alongside the root hash.
- [ ] **[RR-10]** Confirm `DisputeGame` has a `finaliseByTimeout` function awarding bonds to challengers after `resolutionTime` without a counter-proof.
- [ ] **[4.1.1]** Confirm `defenseWindow` in `DisputeGame` is configurable and the default value is ≥ 604800 seconds (7 days) for mainnet.
- [ ] **[4.2.3]** Confirm all owner-gated operations are documented; confirm all governance procedures for owner key rotation are in place.

### 8.3 Medium — Recommended Before Audit Signoff

- [ ] **[RR-11]** Confirm that all liveness timers use block numbers as a fallback or primary reference in addition to `block.timestamp`.
- [ ] **[RR-12]** Confirm OpenZeppelin `Pausable` is integrated into `EpochManager`, `RootHistory`, `DisputeGame`, `ProofVerifier`, and `IndexerStaking`.
- [ ] **[4.3.2]** Confirm reward accrual uses a snapshot or checkpoint model; confirm no single-block stake-and-claim attack is possible.
- [ ] **[4.7.2]** Confirm epoch and root submission transactions are protected against observable front-running (commit-reveal or alternative ordering guarantees).
- [ ] **[4.9.2]** Confirm any community voting in dispute resolution is stake-weighted, not address-count-weighted.

### 8.4 Formal Verification Properties to Verify

- [ ] **[S1]** Prove that `epochCount` is strictly monotonically increasing across all reachable execution paths.
- [ ] **[S2]** Prove that no epoch with `startTime >= endTime` can exist in `epochs[]`.
- [ ] **[S3]** Prove that `currentEpoch` in `RootHistory` is monotonically non-decreasing after each `receiveRoot` call.
- [ ] **[S4]** Prove that once `isSlashed[address] = true`, `stakes[address].amount` remains zero and rewards remain zero.
- [ ] **[T1]** Prove that `resolveDispute` cannot transfer funds before `resolutionTime` has elapsed.
- [ ] **[T2]** Prove that no `updateEpoch` call can reference an epoch that does not exist (`epochId >= epochCount`).
- [ ] **[T3]** Prove that proof timestamps stored in `ProofVerifier` are immutable after initial submission.
- [ ] **[E1]** Prove that no dispute can exist in `disputes[]` with `bond == 0`.
- [ ] **[E2]** Prove that `calculateReward` returns zero for any staker with `stakeInfo.amount == 0` or `timeStaked == 0`.

### 8.5 Documentation and Process Checks

- [ ] All contracts have NatSpec documentation for every public/external function.
- [ ] A deployment runbook exists specifying constructor parameters, multi-sig addresses, and initial configuration.
- [ ] An incident response playbook exists covering: owner key compromise, invalid root detected, epoch starvation, contract pause procedure.
- [ ] Change management process documented for `rewardRate` updates and `defenseWindow` changes.
- [ ] Off-chain monitoring infrastructure deployed for: epoch activity, open disputes approaching expiry, slashing events, anomalous root submissions.

---

*This document is linked to:*
- *`docs/formal-verification.md`* — formal property specifications (S1–S4, T1–T3)
- *`docs/challenge-dispute-economics.md`* — dispute game economics detail
- *`docs/architecture.md`* — system component overview

*Date Created: 2026-03-05*  
*Author: @copilot (BryanSavage79/Epoch-timing-modle)*
