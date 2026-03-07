# Formal Verification Specification

This document provides a formal verification specification for the Epoch Timing Model smart contracts. It translates the system's state machine, invariants, and security properties into annotations compatible with [Certora Prover](https://docs.certora.com/) and [Scribble](https://docs.scribble.codes/), and outlines auditor review steps.

---

## Table of Contents

1. [Scope and Contracts](#scope-and-contracts)
2. [Invariant Reference](#invariant-reference)
3. [S1–S4: EpochManager State Invariants](#s1s4-epochmanager-state-invariants)
4. [SH1–SH3: RootHistory Consistency Invariants](#sh1sh3-roothistory-consistency-invariants)
5. [T1–T3: Temporal Properties](#t1t3-temporal-properties)
6. [E1–E2: Economic and Dispute Properties](#e1e2-economic-and-dispute-properties)
7. [Annotated Solidity Examples (Scribble)](#annotated-solidity-examples-scribble)
8. [Certora Specification File](#certora-specification-file)
9. [Expected Behaviors and Auditor Review Steps](#expected-behaviors-and-auditor-review-steps)
10. [Security Theorems](#security-theorems)

---

## Scope and Contracts

| Contract | File | Purpose |
|---|---|---|
| `EpochManager` | `contracts/EpochManager.sol` | Creates and updates time epochs; source of truth for epoch count and state |
| `RootHistory` | `contracts/RootHistory.sol` | Stores and finalizes epoch Merkle roots; enforces root monotonicity |
| `IndexerStaking` | `contracts/IndexerStaking.sol` | Manages indexer stake, rewards, and slashing |
| `DisputeGame` | `contracts/DisputeGame.sol` | Handles challenge bonds and single-resolution dispute lifecycle |
| `ProofVerifier` | `contracts/ProofVerifier.sol` | Submits and verifies proofs, tracks prover reputation |

---

## Invariant Reference

| ID | Contract | Category | Summary |
|---|---|---|---|
| S1 | EpochManager | State | `epochCount` is strictly monotonically increasing |
| S2 | EpochManager | State | Every epoch satisfies `startTime < endTime` |
| S3 | EpochManager | State | Epoch status transitions only from `Active` to `Inactive` |
| S4 | EpochManager | State | Every stored epoch ID is less than `epochCount` |
| SH1 | RootHistory | Historical | A finalized root can never be overwritten |
| SH2 | RootHistory | Historical | `currentEpoch` is monotonically non-decreasing |
| SH3 | RootHistory | Historical | Every accepted epoch root has a corresponding non-zero root hash |
| T1 | IndexerStaking | Temporal | A staker's balance never drops below zero |
| T2 | IndexerStaking | Temporal | A slashed address cannot be slashed a second time |
| T3 | IndexerStaking | Temporal | `totalStaked` equals the sum of all individual stake amounts |
| E1 | DisputeGame | Economic | A dispute can only be resolved once |
| E2 | DisputeGame | Economic | Bond is transferred exclusively to either challenger or defender on resolution |

---

## S1–S4: EpochManager State Invariants

### S1 — Monotonically Increasing Epoch Count

**Informal:** After every successful call to `createEpoch`, `epochCount` is exactly one greater than before. `epochCount` can never decrease.

**Formal (LTL):**
```
G(epochCount' >= epochCount)
```

**Certora rule (see [full spec below](#certora-specification-file)):**
```cvl
rule epochCountNeverDecreases(method f) {
    uint256 before = epochCount();
    calldataarg args;
    f(e, args);
    assert epochCount() >= before;
}
```

---

### S2 — Start Time Strictly Before End Time

**Informal:** For every epoch `i` where `i < epochCount`, the stored `startTime` is strictly less than `endTime`.

**Formal:**
```
∀ i ∈ [0, epochCount) : epochs[i].startTime < epochs[i].endTime
```

**Certora invariant:**
```cvl
invariant validEpochTimeRange(uint256 epochId)
    epochId < epochCount() =>
        epochs(epochId).startTime < epochs(epochId).endTime;
```

---

### S3 — Epoch Status Monotonicity (Active → Inactive Only)

**Informal:** An epoch's `status` field can only transition from `Active (0)` to `Inactive (1)`. The reverse transition is forbidden.

**Formal (state machine):**
```
Active → Inactive   (permitted)
Inactive → Active   (forbidden)
```

**Certora rule:**
```cvl
rule epochStatusOnlyDeactivates(uint256 epochId) {
    require epochs(epochId).status == 1; // Inactive
    calldataarg args;
    updateEpoch(e, epochId, args);
    assert epochs(epochId).status == 1;
}
```

---

### S4 — Epoch IDs Are Bounded by epochCount

**Informal:** Any valid epoch ID that was returned from `createEpoch` or accepted by `updateEpoch` / `getEpochDescriptor` satisfies `epochId < epochCount`.

**Formal:**
```
∀ f ∈ {updateEpoch, getEpochDescriptor} : f(epochId, …) succeeds ⟹ epochId < epochCount
```

**Certora rule:**
```cvl
rule epochIdBounded(uint256 epochId) {
    getEpochDescriptor(e, epochId);
    assert epochId < epochCount();
}
```

---

## SH1–SH3: RootHistory Consistency Invariants

> **⚠️ Implementation Gaps — Auditor Action Required**
>
> Two critical issues in the current `RootHistory.sol` implementation affect these invariants and must be resolved before the spec can be considered fully verified:
>
> 1. **`finalized` flag has no setter.** The `EpochRoot.finalized` field is always `false` because no function sets it to `true`. Invariant **SH1** is therefore vacuously satisfied but the intended finalization protection is **not active**. A `finalizeRoot(uint256 epoch)` function must be added (see Theorem 2).
>
> 2. **`mirroredEpoch` is never updated.** The `receiveRoot` function checks `epoch > mirroredEpoch` but never updates `mirroredEpoch` after a successful call. This means the guard is only ever checked against its initial value of `0`, permitting overwrites of any previously stored root for epochs greater than 0. Invariant **SH1** depends on this being fixed.

### SH1 — Finalized Roots Are Immutable

**Informal:** Once `epochRoots[epoch].finalized` is set to `true`, neither the `root` hash nor the `finalized` flag may change.

**Formal:**
```
∀ epoch : epochRoots[epoch].finalized = true ⟹
    □(epochRoots[epoch].root = prev_root ∧ epochRoots[epoch].finalized = true)
```

**Certora invariant:**
```cvl
invariant finalizedRootIsImmutable(uint256 epoch)
    old(epochRoots(epoch).finalized) == true =>
        epochRoots(epoch).root == old(epochRoots(epoch).root) &&
        epochRoots(epoch).finalized == true;
```

---

### SH2 — Monotonically Non-Decreasing currentEpoch

**Informal:** `currentEpoch` never decreases. Every call to `receiveRoot` either keeps `currentEpoch` the same or advances it.

**Formal:**
```
G(currentEpoch' >= currentEpoch)
```

**Certora rule:**
```cvl
rule currentEpochNeverDecreases(method f) {
    uint256 before = currentEpoch();
    calldataarg args;
    f(e, args);
    assert currentEpoch() >= before;
}
```

---

### SH3 — Non-Zero Root for Every Accepted Epoch

**Informal:** After a successful `receiveRoot` call for epoch `e`, `epochRoots[e].root` is non-zero.

**Formal:**
```
receiveRoot(root, epoch, proof) succeeds ⟹ epochRoots[epoch].root ≠ bytes32(0)
```

**Certora rule:**
```cvl
rule nonZeroRootAfterReceive(bytes32 root, uint256 epoch, bytes32 proof) {
    receiveRoot(e, root, epoch, proof);
    assert epochRoots(epoch).root != to_bytes32(0);
}
```

---

## T1–T3: Temporal Properties

### T1 — Staker Balance Non-Negativity

**Informal:** A staker's individual stake and the global `totalStaked` counter can never go below zero. Solidity's unchecked arithmetic is avoided; the `unStake` function enforces `stakes[msg.sender].amount >= amount` before subtracting.

**Formal:**
```
∀ addr : stakes[addr].amount ≥ 0  ∧  totalStaked ≥ 0
```

**Scribble annotation:**
```solidity
/// #invariant {:msg "Staker balance non-negative"} stakes[msg.sender].amount >= 0;
function unStake(uint256 amount) public { … }
```

**Certora invariant:**
```cvl
invariant stakerBalanceNonNegative(address staker)
    stakes(staker).amount >= 0;
```

---

### T2 — Slashing Exclusivity (No Double-Slash)

**Informal:** Once `isSlashed[addr]` is set to `true`, no further call to `slash(addr)` can succeed. Slashing is a one-time, irreversible event per address.

**Formal:**
```
isSlashed[addr] = true ⟹ □(slash(addr) reverts)
```

**Scribble annotation:**
```solidity
/// #if_succeeds {:msg "Cannot slash twice"} !old(isSlashed[staker]);
function slash(address staker) public { … }
```

**Certora rule:**
```cvl
rule noDoubleSlash(address staker) {
    require isSlashed(staker) == true;
    slash(e, staker);
    assert false; // must revert
}
```

---

### T3 — Global Stake Accounting Consistency

**Informal:** `totalStaked` at all times equals the sum of every individual `stakes[addr].amount` across all addresses.

**Formal:**
```
totalStaked = Σ_{addr} stakes[addr].amount
```

> **Note:** Certora's ghost variables are used to track the running sum across all addresses.

**Certora ghost + invariant:**
```cvl
ghost mathint sumOfStakes {
    init_state axiom sumOfStakes == 0;
}

hook Sstore stakes[KEY address a].amount uint256 newVal (uint256 oldVal) STORAGE {
    sumOfStakes = sumOfStakes + newVal - oldVal;
}

invariant totalStakedMatchesSum()
    to_mathint(totalStaked()) == sumOfStakes;
```

---

## E1–E2: Economic and Dispute Properties

### E1 — Single Finalization of Disputes

**Informal:** Once `disputes[id].resolved` is set to `true`, any subsequent call to `resolveDispute(id, …)` must revert. Every dispute can be resolved at most once.

**Formal:**
```
disputes[id].resolved = true ⟹ □(resolveDispute(id, _) reverts)
```

**Scribble annotation:**
```solidity
/// #if_succeeds {:msg "Dispute resolved at most once"} !old(disputes[disputeId].resolved);
function resolveDispute(uint disputeId, bool verdict) public { … }
```

**Certora rule:**
```cvl
rule singleDisputeResolution(uint disputeId) {
    require disputes(disputeId).resolved == true;
    resolveDispute(e, disputeId, _);
    assert false; // must revert
}
```

---

### E2 — Bond Transfer Exclusivity

**Informal:** On resolution of a dispute, the full bond amount is transferred to exactly one party: the challenger if `verdict == true`, the defender if `verdict == false`. The bond is never split, lost, or sent to a third party.

**Formal:**
```
resolveDispute(id, verdict) succeeds ⟹
    (verdict = true  ⟹ challenger receives disputes[id].bond) ∧
    (verdict = false ⟹ defender  receives disputes[id].bond)
```

**Certora rule:**
```cvl
rule bondTransferExclusive(uint disputeId, bool verdict) {
    address challenger = disputes(disputeId).challenger;
    address defender   = disputes(disputeId).defender;
    uint    bond       = disputes(disputeId).bond;

    uint challengerBefore = nativeBalances[challenger];
    uint defenderBefore   = nativeBalances[defender];

    resolveDispute(e, disputeId, verdict);

    if (verdict) {
        assert nativeBalances[challenger] == challengerBefore + bond;
        assert nativeBalances[defender]   == defenderBefore;
    } else {
        assert nativeBalances[defender]   == defenderBefore + bond;
        assert nativeBalances[challenger] == challengerBefore;
    }
}
```

---

## Annotated Solidity Examples (Scribble)

The snippets below show each contract annotated with [Scribble](https://docs.scribble.codes/) `/// #invariant` and `/// #if_succeeds` tags. Running `scribble --instrument` against these files generates a harness that can be tested with Mythril, Echidna, or other fuzzers.

### EpochManager — Annotated

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

/// #invariant {:msg "S1: epochCount is monotonically non-decreasing"}
///     epochCount >= old(epochCount);
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

    /// #if_succeeds {:msg "S2: startTime < endTime for new epoch"}
    ///     epochs[old(epochCount)].startTime < epochs[old(epochCount)].endTime;
    /// #if_succeeds {:msg "S1: epochCount increments by exactly 1"}
    ///     epochCount == old(epochCount) + 1;
    function createEpoch(uint256 startTime, uint256 endTime) external onlyOwner {
        require(startTime < endTime, "Start time must be before end time");
        epochs[epochCount] = EpochDescriptor(startTime, endTime, EpochStatus.Active);
        emit EpochCreated(epochCount, startTime, endTime);
        epochCount++;
    }

    /// #if_succeeds {:msg "S3: Inactive epoch cannot become Active"}
    ///     old(epochs[epochId].status) == EpochStatus.Inactive
    ///         ==> epochs[epochId].status == EpochStatus.Inactive;
    function updateEpoch(uint256 epochId, EpochStatus status) external onlyOwner {
        require(epochId < epochCount, "Epoch does not exist");
        epochs[epochId].status = status;
        emit EpochUpdated(epochId, status);
    }

    function getEpochDescriptor(uint256 epochId)
        external view returns (EpochDescriptor memory)
    {
        require(epochId < epochCount, "Epoch does not exist");
        return epochs[epochId];
    }
}
```

### RootHistory — Annotated

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// #invariant {:msg "SH2: currentEpoch is monotonically non-decreasing"}
///     currentEpoch >= old(currentEpoch);
contract RootHistory {
    struct EpochRoot {
        bytes32 root;
        bool finalized;
    }

    mapping(uint256 => EpochRoot) private epochRoots;
    uint256 public currentEpoch;
    uint256 private mirroredEpoch;

    event RootReceived(uint256 epoch, bytes32 root);

    /// #if_succeeds {:msg "SH3: root stored is non-zero"}
    ///     epochRoots[epoch].root != bytes32(0);
    /// #if_succeeds {:msg "SH1: previously-finalized root unchanged"}
    ///     old(epochRoots[epoch].finalized) == true
    ///         ==> epochRoots[epoch].root == old(epochRoots[epoch].root);
    function receiveRoot(bytes32 root, uint256 epoch, bytes32 historyProof) public {
        require(verifyRootProof(root, historyProof), "Invalid proof");
        require(epoch > mirroredEpoch, "Epoch must be greater than mirroredEpoch");
        epochRoots[epoch] = EpochRoot({root: root, finalized: false});
        currentEpoch = epoch;
        emit RootReceived(epoch, root);
    }

    function verifyRootProof(bytes32 root, bytes32 historyProof)
        internal view returns (bool)
    {
        return true; // placeholder — replace with Merkle proof verification
    }

    function getEpochRoot(uint256 epoch)
        public view returns (bytes32 root, bool finalized)
    {
        EpochRoot memory epochRoot = epochRoots[epoch];
        return (epochRoot.root, epochRoot.finalized);
    }

    function getCurrentEpoch() public view returns (uint256) {
        return currentEpoch;
    }
}
```

### IndexerStaking — Annotated

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// #invariant {:msg "T1: totalStaked is non-negative"} totalStaked >= 0;
contract IndexerStaking {
    struct Stake {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => Stake) public stakes;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public isSlashed;

    uint256 public totalStaked;
    uint256 public rewardRate;

    constructor(uint256 _rewardRate) {
        rewardRate = _rewardRate;
    }

    /// #if_succeeds {:msg "T1: individual stake non-negative after unStake"}
    ///     stakes[msg.sender].amount >= 0;
    function unStake(uint256 amount) public {
        require(stakes[msg.sender].amount >= amount, "Not enough staked");
        stakes[msg.sender].amount -= amount;
        totalStaked -= amount;
    }

    /// #if_succeeds {:msg "T2: address was not already slashed"}
    ///     !old(isSlashed[staker]);
    /// #if_succeeds {:msg "T2: slashed address has zero stake"}
    ///     stakes[staker].amount == 0;
    function slash(address staker) public {
        require(!isSlashed[staker], "Already slashed");
        isSlashed[staker] = true;
        stakes[staker].amount = 0;
    }
}
```

### DisputeGame — Annotated

```solidity
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
        disputes[disputeCount] = Dispute(
            msg.sender, defender, msg.value,
            defenseWindow, block.timestamp + defenseWindow, false
        );
        emit DisputeCreated(disputeCount, msg.sender, defender, msg.value);
    }

    /// #if_succeeds {:msg "E1: dispute resolved at most once"}
    ///     !old(disputes[disputeId].resolved);
    /// #if_succeeds {:msg "E1: dispute is marked resolved after this call"}
    ///     disputes[disputeId].resolved == true;
    function resolveDispute(uint disputeId, bool verdict) public {
        Dispute storage dispute = disputes[disputeId];
        require(
            msg.sender == dispute.challenger || msg.sender == dispute.defender,
            "Not authorized"
        );
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
```

---

## Certora Specification File

The following is a self-contained Certora Verification Language (CVL) spec file covering all invariants above. Save it as `certora/EpochSystem.spec` and run with:

```bash
certoraRun contracts/EpochManager.sol contracts/RootHistory.sol \
           contracts/IndexerStaking.sol contracts/DisputeGame.sol \
  --verify EpochManager:certora/EpochSystem.spec \
  --msg "EpochSystem full invariant check"
```

```cvl
// certora/EpochSystem.spec
// Certora CVL specification for the Epoch Timing Model
// Covers S1–S4, SH1–SH3, T1–T3, E1–E2

using EpochManager    as epochManager
using RootHistory     as rootHistory
using IndexerStaking  as indexerStaking
using DisputeGame     as disputeGame

methods {
    // EpochManager
    epochManager.epochCount()                                   returns (uint256) envfree
    epochManager.epochs(uint256)                                returns (uint256, uint256, uint8) envfree
    epochManager.createEpoch(uint256, uint256)                  
    epochManager.updateEpoch(uint256, uint8)                    

    // RootHistory
    rootHistory.currentEpoch()                                  returns (uint256) envfree
    rootHistory.getEpochRoot(uint256)                           returns (bytes32, bool) envfree
    rootHistory.receiveRoot(bytes32, uint256, bytes32)          

    // IndexerStaking
    indexerStaking.totalStaked()                                returns (uint256) envfree
    indexerStaking.stakes(address)                              returns (uint256, uint256) envfree
    indexerStaking.isSlashed(address)                           returns (bool) envfree
    indexerStaking.slash(address)                               
    indexerStaking.unStake(uint256)                             

    // DisputeGame
    disputeGame.disputes(uint256)                               returns (address, address, uint256, uint256, uint256, bool) envfree
    disputeGame.resolveDispute(uint256, bool)                   
}

// ─── Ghost variable: running sum of all individual stakes ───────────────────

ghost mathint sumOfStakes {
    init_state axiom sumOfStakes == 0;
}

hook Sstore indexerStaking.stakes[KEY address a].amount
        uint256 newVal (uint256 oldVal) STORAGE {
    sumOfStakes = sumOfStakes + newVal - oldVal;
}

// ─── S1: epochCount never decreases ─────────────────────────────────────────

rule S1_epochCountNeverDecreases(method f) {
    uint256 before = epochManager.epochCount();
    env e; calldataarg args;
    f(e, args);
    assert epochManager.epochCount() >= before,
        "S1: epochCount decreased";
}

// ─── S2: every epoch has startTime < endTime ─────────────────────────────────

invariant S2_validEpochTimeRange(uint256 epochId)
    epochId < epochManager.epochCount() =>
        epochManager.epochs(epochId)._0 < epochManager.epochs(epochId)._1
    filtered { f -> f.selector == sig:createEpoch(uint256,uint256).selector
                 || f.selector == sig:updateEpoch(uint256,uint8).selector }
    { preserved createEpoch(uint256 s, uint256 e_) with (env ev) {
        require s < e_;
      }
    }

// ─── S3: epoch status is monotone (Active → Inactive only) ──────────────────

rule S3_epochStatusOnlyDeactivates(uint256 epochId) {
    require epochManager.epochs(epochId)._2 == 1; // 1 = Inactive
    env e; calldataarg args;
    epochManager.updateEpoch(e, epochId, args);
    assert epochManager.epochs(epochId)._2 == 1,
        "S3: Inactive epoch was re-activated";
}

// ─── S4: getEpochDescriptor only succeeds for valid IDs ─────────────────────

rule S4_epochIdBounded(uint256 epochId) {
    env e;
    epochManager.getEpochDescriptor(e, epochId);
    assert epochId < epochManager.epochCount(),
        "S4: epoch ID out of bounds";
}

// ─── SH1: finalized root is immutable ───────────────────────────────────────

rule SH1_finalizedRootImmutable(uint256 epoch) {
    bytes32 rootBefore; bool finalizedBefore;
    rootBefore, finalizedBefore = rootHistory.getEpochRoot(epoch);
    require finalizedBefore == true;

    env e; calldataarg args;
    rootHistory.receiveRoot(e, args); // only state-changing function

    bytes32 rootAfter; bool finalizedAfter;
    rootAfter, finalizedAfter = rootHistory.getEpochRoot(epoch);
    assert rootAfter == rootBefore,
        "SH1: finalized root was overwritten";
    assert finalizedAfter == true,
        "SH1: finalized flag was cleared";
}

// ─── SH2: currentEpoch never decreases ───────────────────────────────────────

rule SH2_currentEpochNeverDecreases(method f) {
    uint256 before = rootHistory.currentEpoch();
    env e; calldataarg args;
    f(e, args);
    assert rootHistory.currentEpoch() >= before,
        "SH2: currentEpoch decreased";
}

// ─── SH3: receiveRoot stores a non-zero root ─────────────────────────────────

rule SH3_nonZeroRootAfterReceive(bytes32 root, uint256 epoch, bytes32 proof) {
    env e;
    rootHistory.receiveRoot(e, root, epoch, proof);
    bytes32 storedRoot; bool finalized;
    storedRoot, finalized = rootHistory.getEpochRoot(epoch);
    assert storedRoot != to_bytes32(0),
        "SH3: zero root stored";
}

// ─── T1: staker balance non-negative ─────────────────────────────────────────

invariant T1_stakerBalanceNonNegative(address staker)
    indexerStaking.stakes(staker)._0 >= 0;

// ─── T2: no double-slash ─────────────────────────────────────────────────────

rule T2_noDoubleSlash(address staker) {
    require indexerStaking.isSlashed(staker) == true;
    env e;
    indexerStaking.slash@withrevert(e, staker);
    assert lastReverted,
        "T2: slash succeeded on already-slashed address";
}

// ─── T3: totalStaked matches sum of individual stakes ────────────────────────

invariant T3_totalStakedConsistency()
    to_mathint(indexerStaking.totalStaked()) == sumOfStakes;

// ─── E1: single dispute resolution ───────────────────────────────────────────

rule E1_singleDisputeResolution(uint256 disputeId) {
    require disputeGame.disputes(disputeId)._5 == true; // resolved
    env e;
    disputeGame.resolveDispute@withrevert(e, disputeId, _);
    assert lastReverted,
        "E1: dispute resolved a second time";
}

// ─── E2: bond transfer exclusivity ───────────────────────────────────────────

rule E2_bondTransferExclusivity(uint256 disputeId, bool verdict) {
    address challenger = disputeGame.disputes(disputeId)._0;
    address defender   = disputeGame.disputes(disputeId)._1;
    uint256 bond       = disputeGame.disputes(disputeId)._2;

    require challenger != defender;
    require !disputeGame.disputes(disputeId)._5; // not yet resolved

    mathint challengerBefore = nativeBalances[challenger];
    mathint defenderBefore   = nativeBalances[defender];

    env e;
    disputeGame.resolveDispute(e, disputeId, verdict);

    if (verdict) {
        assert to_mathint(nativeBalances[challenger]) == challengerBefore + bond,
            "E2: challenger did not receive bond";
        assert nativeBalances[defender] == defenderBefore,
            "E2: defender balance changed unexpectedly";
    } else {
        assert to_mathint(nativeBalances[defender]) == defenderBefore + bond,
            "E2: defender did not receive bond";
        assert nativeBalances[challenger] == challengerBefore,
            "E2: challenger balance changed unexpectedly";
    }
}
```

---

## Expected Behaviors and Auditor Review Steps

### Expected Behaviors

| Scenario | Expected Outcome |
|---|---|
| `createEpoch(s, e)` with `s >= e` | Reverts with "Start time must be before end time" |
| `createEpoch(s, e)` with valid args | `epochs[epochCount-1]` stores the new epoch; `epochCount` increases by 1 |
| `updateEpoch(id, Inactive)` | Status flips; event emitted; no other fields change |
| `updateEpoch(id, Active)` on Inactive epoch | Currently succeeds — auditors should verify whether re-activation is an intended design choice or a defect |
| `receiveRoot` with an epoch ≤ `mirroredEpoch` | Reverts — epoch must advance |
| `receiveRoot` with a valid epoch | Root stored; `currentEpoch` updated; event emitted |
| `slash(addr)` on already-slashed address | Reverts with "Already slashed" |
| `unStake` amount > staked | Reverts with "Not enough staked" |
| `resolveDispute` on resolved dispute | Reverts with "Dispute has already been resolved" |
| `resolveDispute` by non-participant | Reverts with "Not authorized" |

### Auditor Review Steps

1. **Monotonicity checks (S1, SH2)**
   - Run `S1_epochCountNeverDecreases` and `SH2_currentEpochNeverDecreases` against all external/public functions.
   - Confirm no storage write can decrement these counters.

2. **Time-range validity (S2)**
   - For every `EpochDescriptor` in storage, assert `startTime < endTime`.
   - Check that no `updateEpoch` path can overwrite timing fields.

3. **Status machine (S3)**
   - Enumerate all callers of `updateEpoch`.
   - Confirm `onlyOwner` is sufficient access control, or evaluate whether the status transition should be further gated by time.

4. **Root finalization (SH1) — ⚠️ Critical Gap**
   - Trace all write paths to `epochRoots`.
   - **Critical:** `finalized` is never set to `true` in `RootHistory.sol`. The `finalized` flag has no setter, making SH1 vacuously true but the finalization feature incomplete. A `finalizeRoot` function must be implemented before this invariant provides any real protection.
   - **Critical:** `mirroredEpoch` is never updated after a successful `receiveRoot`. This means any epoch greater than 0 can have its root overwritten repeatedly, breaking root history retention.

5. **Slashing exclusivity (T2)**
   - Verify that `isSlashed` is checked before every `slash` call.
   - Confirm the flag is never cleared by any other function.

6. **Stake accounting (T3)**
   - Trace all writes to `stakes[addr].amount` and `totalStaked`.
   - Confirm both are updated atomically in `stake` and `unStake`.
   - Note: the `stake` function increments `totalStaked` but relies on an off-chain ERC-20 transfer; auditors should verify this does not allow `totalStaked` to diverge from actual token holdings.

7. **Single finalization (E1)**
   - Confirm `disputes[id].resolved` is checked before every side-effect in `resolveDispute`.
   - Check for reentrancy: `dispute.resolved = true` is set **before** the `transfer` calls, satisfying checks-effects-interactions. Verify this order is preserved in any future refactor.

8. **Reentrancy review**
   - `DisputeGame.resolveDispute` uses `transfer` (fixed 2300 gas). Auditors should verify no future upgrade switches to `call{value: …}` without adding a reentrancy guard.
   - `IndexerStaking` stake/unstake functions have no ETH transfers but call external ERC-20 contracts; a reentrancy guard (`nonReentrant`) should be considered.

9. **Access control**
   - `EpochManager.createEpoch` and `updateEpoch` are `onlyOwner`; verify the owner key is managed securely (multisig recommended).
   - `ProofVerifier.verifyProof` is `onlyOwner`; same recommendation applies.
   - `DisputeGame.resolveDispute` allows either party to resolve — auditors should assess whether this is safe given there is no oracle or arbitration layer currently.

10. **Timing edge cases**
    - `DisputeGame.createDispute` sets `resolutionTime = block.timestamp + defenseWindow`. Miners can manipulate `block.timestamp` by up to ~15 seconds; ensure `defenseWindow` values are long enough to make this irrelevant.
    - **⚠️ Bug:** `RootHistory.receiveRoot` checks `epoch > mirroredEpoch` but never updates `mirroredEpoch`. This allows any epoch ID > 0 to have its stored root overwritten on any subsequent `receiveRoot` call with the same epoch ID. The fix is to update `mirroredEpoch = epoch` at the end of `receiveRoot`, or to revert if `epochRoots[epoch].root != bytes32(0)` (i.e., a root is already stored for that epoch).

---

## Security Theorems

### Theorem 1 — Epoch Progress Guarantee
If `createEpoch` is called with valid arguments, the system always makes forward progress: `epochCount` strictly increases and the new epoch is immediately accessible.

### Theorem 2 — Finalization Safety (Conditional)
Under the assumption that a `finalizeRoot` function is added that sets `epochRoots[epoch].finalized = true`, invariant **SH1** ensures that no subsequent `receiveRoot` call can overwrite that epoch's root. The protocol achieves finality safety for all epochs for which finalization has been triggered.

### Theorem 3 — Slashing Irreversibility
For any address `addr`, once `slash(addr)` executes successfully, the predicate `isSlashed[addr] == true` holds in all future states and `stakes[addr].amount == 0` holds immediately after. No function in `IndexerStaking` can restore the stake of a slashed address.

### Theorem 4 — Economic Soundness of Dispute Resolution
For every dispute `id` with bond `b`, the sum of ETH held by the challenger and defender changes by exactly `0` net (ETH is conserved): one party gains `b` and the other neither gains nor loses relative to their pre-resolution balance. No ETH is burned or sent to a third party.

### Theorem 5 — Reentrancy Safety (Current Implementation)
In `DisputeGame.resolveDispute`, the state mutation (`dispute.resolved = true`) is performed before any external call (`transfer`). This follows the checks-effects-interactions pattern and prevents reentrancy attacks from re-entering `resolveDispute` with the same `disputeId`.

---

*Last updated: 2026-03-05*
*Specification version: 1.0.0*
*Compatible with: Certora Prover ≥ 4.x, Scribble ≥ 0.6.x*