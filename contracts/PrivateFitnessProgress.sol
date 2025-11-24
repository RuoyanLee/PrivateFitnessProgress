// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * PrivateFitnessProgress — personal encrypted fitness tracking on Zama FHEVM
 *
 * Users submit encrypted results; the contract stores them and compares to user-defined goals
 * without revealing plaintexts onchain. The contract exposes encrypted handles (bytes32) that
 * frontends can decrypt via the Relayer SDK (userDecrypt/publicDecrypt) if access is granted.
 *
 * Design notes:
 * - Each user has arbitrary metrics identified by bytes32 metricId (e.g., keccak256("pushups"), etc.).
 * - For each metric: encrypted goal, last result, best result (per orientation), last "hit goal" flag,
 *   and last absolute gap to the goal are stored.
 * - Orientation is public (higherIsBetter) to decide comparisons (>= or <=).
 * - Access control uses FHE.allow / FHE.allowThis; owners can grant access or make values public.
 * - Avoids FHE ops in view/pure; getters return only handles.
 */

import { FHE, ebool, euint32, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateFitnessProgress is ZamaEthereumConfig {
    struct Metric {
        bool    configured;         // goal has been set at least once
        bool    higherIsBetter;     // orientation: true => higher is better; false => lower is better
        uint32  submissions;        // number of submitted results
        uint64  lastTs;             // last submission timestamp

        // Encrypted state (handles)
        euint32 goal;               // user goal
        euint32 lastResult;         // last submitted result
        euint32 best;               // best result so far according to orientation
        euint32 lastGapAbs;         // |lastResult - goal|
        ebool   lastHit;            // whether lastResult met the goal (>= or <= depending on orientation)
    }

    // user => metricId => Metric
    mapping(address => mapping(bytes32 => Metric)) private metrics;

    /* ─────────────── Events ─────────────── */
    event GoalSet(address indexed user, bytes32 indexed metricId, bool higherIsBetter);
    event ResultSubmitted(address indexed user, bytes32 indexed metricId, bytes32 hitHandle, bytes32 gapAbsHandle);
    event AccessGranted(address indexed user, bytes32 indexed metricId, address indexed to);
    event MetricMadePublic(address indexed user, bytes32 indexed metricId);

    /* ─────────────── Admin (per-user) ─────────────── */

    /// @notice Set or update your encrypted goal for a metric and define orientation.
    /// @param metricId Arbitrary identifier for the metric (e.g., keccak256("weight_kg"))
    /// @param encGoal Encrypted goal value provided as external handle
    /// @param attestation Coprocessor attestation for the external value
    /// @param higherIsBetter Orientation flag: true if larger values are better (>= goal), false if smaller (<= goal)
    function setGoal(
        bytes32 metricId,
        externalEuint32 encGoal,
        bytes calldata attestation,
        bool higherIsBetter
    ) external {
        euint32 g = FHE.fromExternal(encGoal, attestation);

        Metric storage M = metrics[msg.sender][metricId];
        M.configured = true;
        M.higherIsBetter = higherIsBetter;
        M.goal = g;

        // Persist ACL: contract and owner must keep access
        FHE.allowThis(M.goal);
        FHE.allow(M.goal, msg.sender);

        emit GoalSet(msg.sender, metricId, higherIsBetter);
    }

    /// @notice Submit an encrypted result for a metric; stores last result, updates best, and computes goal hit & absolute gap.
    /// @return hitHandle bytes32 handle to ebool indicating if goal is met for this submission
    /// @return gapAbsHandle bytes32 handle to euint32 with |result - goal|
    function submitResult(
        bytes32 metricId,
        externalEuint32 encResult,
        bytes calldata attestation
    ) external returns (bytes32 hitHandle, bytes32 gapAbsHandle) {
        Metric storage M = metrics[msg.sender][metricId];
        require(M.configured, "goal not set");

        // Import external encrypted input
        euint32 r = FHE.fromExternal(encResult, attestation);

        // Compute comparisons against goal
        ebool r_ge_g = FHE.ge(r, M.goal);
        ebool r_le_g = FHE.le(r, M.goal);

        // hit = (higherIsBetter ? r >= g : r <= g)
        M.lastHit = M.higherIsBetter ? r_ge_g : r_le_g;

        // absGap = |r - g| using select
        euint32 diffPos = FHE.sub(r, M.goal); // if r >= g
        euint32 diffNeg = FHE.sub(M.goal, r); // if r < g
        M.lastGapAbs = FHE.select(r_ge_g, diffPos, diffNeg);

        // Update last result
        M.lastResult = r;

        // Update best according to orientation
        if (M.submissions == 0) {
            M.best = r; // initialize best with first result
        } else {
            ebool better = M.higherIsBetter ? FHE.gt(r, M.best) : FHE.lt(r, M.best);
            M.best = FHE.select(better, r, M.best);
        }

        // Book-keeping
        unchecked { M.submissions += 1; }
        M.lastTs = uint64(block.timestamp);

        // ACL: keep contract access and grant user access to all updated ciphertexts
        FHE.allowThis(M.lastResult);
        FHE.allowThis(M.best);
        FHE.allowThis(M.lastGapAbs);
        FHE.allowThis(M.lastHit);

        FHE.allow(M.lastResult, msg.sender);
        FHE.allow(M.best, msg.sender);
        FHE.allow(M.lastGapAbs, msg.sender);
        FHE.allow(M.lastHit, msg.sender);

        // Expose handles in event / return values for immediate frontend use
        hitHandle = FHE.toBytes32(M.lastHit);
        gapAbsHandle = FHE.toBytes32(M.lastGapAbs);
        emit ResultSubmitted(msg.sender, metricId, hitHandle, gapAbsHandle);
    }

    /// @notice Grant another address access to all encrypted fields for a metric.
    function grantAccess(bytes32 metricId, address to) external {
        require(to != address(0), "bad addr");
        Metric storage M = metrics[msg.sender][metricId];
        require(M.configured, "goal not set");

        FHE.allow(M.goal, to);
        if (M.submissions > 0) {
            FHE.allow(M.lastResult, to);
            FHE.allow(M.best, to);
            FHE.allow(M.lastGapAbs, to);
            FHE.allow(M.lastHit, to);
        }
        emit AccessGranted(msg.sender, metricId, to);
    }

    /// @notice Make all encrypted fields for a metric publicly decryptable.
    function makeMetricPublic(bytes32 metricId) external {
        Metric storage M = metrics[msg.sender][metricId];
        require(M.configured, "goal not set");

        FHE.makePubliclyDecryptable(M.goal);
        if (M.submissions > 0) {
            FHE.makePubliclyDecryptable(M.lastResult);
            FHE.makePubliclyDecryptable(M.best);
            FHE.makePubliclyDecryptable(M.lastGapAbs);
            FHE.makePubliclyDecryptable(M.lastHit);
        }
        emit MetricMadePublic(msg.sender, metricId);
    }

    /* ─────────────── Getters (no FHE ops) ─────────────── */

    function goalHandle(address user, bytes32 metricId) external view returns (bytes32) {
        Metric storage M = metrics[user][metricId];
        require(M.configured, "goal not set");
        return FHE.toBytes32(M.goal);
    }

    function lastResultHandle(address user, bytes32 metricId) external view returns (bytes32) {
        Metric storage M = metrics[user][metricId];
        require(M.submissions > 0, "no results");
        return FHE.toBytes32(M.lastResult);
    }

    function bestHandle(address user, bytes32 metricId) external view returns (bytes32) {
        Metric storage M = metrics[user][metricId];
        require(M.submissions > 0, "no results");
        return FHE.toBytes32(M.best);
    }

    function lastGapAbsHandle(address user, bytes32 metricId) external view returns (bytes32) {
        Metric storage M = metrics[user][metricId];
        require(M.submissions > 0, "no results");
        return FHE.toBytes32(M.lastGapAbs);
    }

    function lastHitHandle(address user, bytes32 metricId) external view returns (bytes32) {
        Metric storage M = metrics[user][metricId];
        require(M.submissions > 0, "no results");
        return FHE.toBytes32(M.lastHit);
    }

    /* ─────────────── Public metadata (plaintext) ─────────────── */

    function isHigherBetter(address user, bytes32 metricId) external view returns (bool) {
        return metrics[user][metricId].higherIsBetter;
    }

    function submissions(address user, bytes32 metricId) external view returns (uint32) {
        return metrics[user][metricId].submissions;
    }

    function lastTimestamp(address user, bytes32 metricId) external view returns (uint64) {
        return metrics[user][metricId].lastTs;
    }

    function isConfigured(address user, bytes32 metricId) external view returns (bool) {
        return metrics[user][metricId].configured;
    }

    function version() external pure returns (string memory) {
        return "PrivateFitnessProgress/1.0.0";
    }
}
