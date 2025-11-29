# PrivateFitnessProgress — Encrypted Fitness Goals on Zama FHEVM

> **PrivateFitnessProgress** is a Zama FHEVM-powered protocol for **personal, encrypted fitness tracking**.
> Users set **encrypted goals** and submit **encrypted results**; the contract updates “best”, “last result”, “hit goal?” and “gap to goal” entirely under FHE.
> Frontends decrypt only via the Zama Relayer SDK — the blockchain never sees plaintext performance data.

---

## ✨ Highlights

* 🧍‍♀️ **Per-user, per-metric tracking**
  Any address can define arbitrary metrics (`bytes32 metricId`) like `pushups`, `weight_kg`, `5k_time`.

* 🔐 **All results & goals encrypted**
  `goal`, `lastResult`, `best`, `lastGapAbs` and `lastHit` are stored as FHE types (`euint32`, `ebool`), never as plaintext.

* ↕️ **Orientation-aware logic**
  Each metric defines whether **“higher is better”** (e.g. pushups) or **“lower is better”** (e.g. weight, time).

* 📏 **Goal hit & gap computed safely**
  Contract computes “goal hit?” and the absolute gap `|result − goal|` homomorphically using `FHE.select`, without branching on plaintext.

* 🎛 **Access control built-in**
  Users can keep metrics private, grant selected viewers, or make a metric publicly decryptable.

* 🖥️ **Console-friendly frontend**
  Single-page UI with an orange “BTC-style” background, ethers v6, and Zama Relayer SDK 0.3.x (via CDN), plus a handy decrypt panel.

---

## 🧱 Smart Contract Overview

File: `contracts/PrivateFitnessProgress.sol`

The contract inherits from Zama’s FHEVM config and uses only official libraries:

```solidity
import { FHE, ebool, euint32, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
```

### Data model

Each user can define many metrics. For each `(user, metricId)` the contract stores:

```solidity
struct Metric {
    bool    configured;      // goal set at least once
    bool    higherIsBetter;  // true => higher is better, false => lower is better
    uint32  submissions;     // number of submitted results
    uint64  lastTs;          // last submission timestamp

    // Encrypted state
    euint32 goal;            // user goal
    euint32 lastResult;      // last result
    euint32 best;            // best result so far (orientation-aware)
    euint32 lastGapAbs;      // |lastResult - goal|
    ebool   lastHit;         // whether lastResult met goal (>= or <=)
}

mapping(address => mapping(bytes32 => Metric)) private metrics;
```

* `metricId` is an arbitrary `bytes32` (frontend uses `keccak256(toUtf8Bytes("pushups"))`, etc.).
* Only `configured`, `higherIsBetter`, `submissions`, and `lastTs` are stored as plaintext.
* All performance values and comparisons live as encrypted integers / booleans.

---

## 🧮 Progress Logic

### 1. Setting a goal

```solidity
function setGoal(
    bytes32 metricId,
    externalEuint32 encGoal,
    bytes calldata attestation,
    bool higherIsBetter
) external
```

* Imports the encrypted goal from the FHE gateway:

  ```solidity
  euint32 g = FHE.fromExternal(encGoal, attestation);
  ```

* Records orientation:

  * `higherIsBetter = true` → goal considered **reached if `result >= goal`**
  * `higherIsBetter = false` → goal considered **reached if `result <= goal`**

* Stores and keeps ACLs:

  ```solidity
  M.configured = true;
  M.higherIsBetter = higherIsBetter;
  M.goal = g;

  FHE.allowThis(M.goal);
  FHE.allow(M.goal, msg.sender);
  ```

### 2. Submitting a result

```solidity
function submitResult(
    bytes32 metricId,
    externalEuint32 encResult,
    bytes calldata attestation
) external returns (bytes32 hitHandle, bytes32 gapAbsHandle)
```

Steps (all inside FHE):

1. Import encrypted result:

   ```solidity
   euint32 r = FHE.fromExternal(encResult, attestation);
   ```

2. Compare to goal (encrypted):

   ```solidity
   ebool r_ge_g = FHE.ge(r, M.goal);
   ebool r_le_g = FHE.le(r, M.goal);
   ```

3. Compute if goal is hit:

   ```solidity
   // hit = higherIsBetter ? r >= goal : r <= goal
   M.lastHit = M.higherIsBetter ? r_ge_g : r_le_g;
   ```

4. Compute absolute gap |result − goal| without branching on plaintext:

   ```solidity
   euint32 diffPos = FHE.sub(r, M.goal); // r >= goal
   euint32 diffNeg = FHE.sub(M.goal, r); // r < goal
   M.lastGapAbs = FHE.select(r_ge_g, diffPos, diffNeg);
   ```

5. Update last result & best:

   ```solidity
   M.lastResult = r;

   if (M.submissions == 0) {
       M.best = r;
   } else {
       ebool better = M.higherIsBetter ? FHE.gt(r, M.best) : FHE.lt(r, M.best);
       M.best = FHE.select(better, r, M.best);
   }

   unchecked { M.submissions += 1; }
   M.lastTs = uint64(block.timestamp);
   ```

6. ACL and return handles:

   ```solidity
   FHE.allowThis(M.lastResult);
   FHE.allowThis(M.best);
   FHE.allowThis(M.lastGapAbs);
   FHE.allowThis(M.lastHit);

   FHE.allow(M.lastResult, msg.sender);
   FHE.allow(M.best, msg.sender);
   FHE.allow(M.lastGapAbs, msg.sender);
   FHE.allow(M.lastHit, msg.sender);

   hitHandle    = FHE.toBytes32(M.lastHit);
   gapAbsHandle = FHE.toBytes32(M.lastGapAbs);
   ```

These handles can be passed directly to the frontend for decryption via Relayer SDK.

---

## 🔐 Access Control & Privacy

### Per-metric controls

* `grantAccess(metricId, to)`
  Grants an address read access to **all encrypted fields** of that metric:

  * `goal`, `lastResult`, `best`, `lastGapAbs`, `lastHit`.

* `makeMetricPublic(metricId)`
  Marks these ciphertexts as **publicly decryptable**, so any client can call `publicDecrypt` on their handles.

### Getters (handles only)

All getter functions return **opaque `bytes32` handles**, never plaintext:

* `goalHandle(user, metricId)`
* `lastResultHandle(user, metricId)`
* `bestHandle(user, metricId)`
* `lastGapAbsHandle(user, metricId)`
* `lastHitHandle(user, metricId)`

These are meant to be consumed by UI and decrypted with the Relayer SDK.

### Public metadata

For UX and analytics, some data is exposed as plaintext:

* `isHigherBetter(user, metricId) → bool`
* `submissions(user, metricId) → uint32`
* `lastTimestamp(user, metricId) → uint64`
* `isConfigured(user, metricId) → bool`

---

## 🖥️ Frontend Overview (`frontend/index.html`)

The UI is a single HTML file styled in a **warm orange “BTC console”** theme.

Technologies:

* **ethers v6** (`BrowserProvider`, `Contract`, `keccak256`, `toUtf8Bytes`)
* **Zama Relayer SDK** 0.3.x (via CDN as `ZAMA_SDK`):

  * `initSDK`
  * `createInstance`
  * `SepoliaConfig`
  * `generateKeypair`
  * `publicDecrypt`
  * `userDecrypt`

### CONFIG

At the top of the script:

```js
const CONFIG = {
  NETWORK_NAME: "Sepolia",
  CHAIN_ID_HEX: "0xaa36a7", // 11155111
  RELAYER_URL: "https://relayer.testnet.zama.cloud",
  CONTRACT_ADDRESS: "0xc1bF4ab57f70F68fD86a17A029972d2Ac30B9186" // replace after deploy
};
```

Update `CONTRACT_ADDRESS` after deploying your contract.

---

## 🧭 UI Sections & Flow

### Header

* Shows **Network** and **Contract** badges.
* `Connect Wallet`:

  * connects MetaMask / compatible wallet;
  * switches chain to Sepolia if needed;
  * initializes Relayer SDK instance;
  * attaches ethers `Contract`.

---

### 1. Set Goal (encrypted)

Card: **Set Goal (encrypted)**

Fields:

* `Metric ID` — free-form string (e.g. `"pushups"`) hashed to `bytes32`:

  ```js
  const metricId = keccak256(toUtf8Bytes(metricStr));
  ```

* `Goal value (uint32)` — your numeric goal.

* `Orientation` — dropdown:

  * **Higher is better (≥ goal)**
  * **Lower is better (≤ goal)**

Button:

* **Encrypt & setGoal**:

  * calls `encryptUint32(goalValue)` via Relayer:

    * `createEncryptedInput(contractAddress, userAddress)`
    * `add32` / `addUint32`
    * `encrypt()` → `{ handle, attestation }`
  * sends `setGoal(metricId, handle, att, higherIsBetter)` tx;
  * shows Tx hash and status.

---

### 2. Submit Result (encrypted)

Card: **Submit Result (encrypted)**

Fields:

* `Metric ID` — same string as goal.
* `Result value (uint32)` — your latest performance.

Button:

* **Encrypt & submitResult**:

  * encrypts the result as `externalEuint32` via Relayer;
  * calls `submitResult(metricId, handle, attestation)`;
  * after confirm, reads:

    * `lastHitHandle(user, metricId)`
    * `lastGapAbsHandle(user, metricId)`
  * displays them in **hit** / **gapAbs** pills for quick copy.

---

### 3. Get Handles

Card: **Get Handles**

Fields:

* `User address (owner of metric)` — defaults to your own address if empty.
* `Metric ID` — string ID (same hashing as above).

Buttons:

* `goalHandle`
* `lastResultHandle`
* `bestHandle`
* `lastGapAbsHandle`
* `lastHitHandle`

Each button:

* calls the corresponding view function on the contract;
* prints the handle in the respective `<pre>` block;
* also copies it into the **Decrypt → handle input** field for convenience.

---

### 4. Decrypt (any handle)

Card: **Decrypt**

Fields:

* `Paste handle (bytes32)` — any handle you have rights to decrypt.

Buttons:

* **publicDecrypt**:

  * uses `relayer.publicDecrypt([{ handle, contractAddress }])`;
  * works if the ciphertext was made public (`makeMetricPublic`).

* **userDecrypt (EIP-712)**:

  * generates a keypair (`ZAMA_SDK.generateKeypair`);
  * builds an EIP-712 payload with `createEIP712`;
  * wallet signs via `signTypedData`;
  * calls `userDecrypt(...)` with handle & signature;
  * supports private, per-user decryption.

Output:

* **Value**:

  * booleans (0/1) rendered as `true ✅` / `false ❌`.
  * numbers displayed as plain integers.

---

### 5. Access & Public Controls

Card: **Access & Public Controls**

Fields:

* `Metric ID` — string metric ID (hashed to `bytes32`).
* `Grant to address` — EVM address.

Buttons:

* **grantAccess**

  * calls `grantAccess(metricId, address)` on the contract;
  * gives that address read access to all encrypted fields for this metric.

* **makeMetricPublic**

  * calls `makeMetricPublic(metricId)` on the contract;
  * after this, anyone can decrypt handles via `publicDecrypt`.

---

## 🚶‍♀️ Typical User Journeys

### As a user tracking progress

1. **Connect wallet**.
2. Go to **Set Goal (encrypted)**:

   * choose a metric label (e.g. `"pushups"`),
   * set goal value,
   * choose orientation (higher or lower is better),
   * click **Encrypt & setGoal**.
3. Whenever you have a new result:

   * go to **Submit Result (encrypted)**,
   * enter metric ID and result,
   * click **Encrypt & submitResult**,
   * optionally copy `hit` / `gapAbs` handles to decrypt them in the **Decrypt** card.

### As a coach/friend (viewer)

1. Ask the user to **grantAccess** for a particular metric to your address.
2. Use **Get Handles** with:

   * `User address` = owner’s address,
   * `Metric ID` = metric label.
3. Copy desired handle into **Decrypt** and use:

   * `publicDecrypt` (if the metric is public), or
   * `userDecrypt (EIP-712)` (if you have private ACL via Relayer).

---

## 🏗️ Suggested Repository Structure

```text
.
├── contracts/
│   └── PrivateFitnessProgress.sol   # Core FHEVM contract
├── frontend/
│   └── index.html                   # Private Fitness Progress UI
├── scripts/                         # (optional) deploy & helper scripts
│   └── deploy.ts / deploy.js
├── README.md                        # This file
└── package.json / foundry.toml ...  # Tooling (Hardhat / Foundry, etc.)
```

---

## 📄 License

The contract is MIT-licensed:

```solidity
// SPDX-License-Identifier: MIT
```

You are free to fork, modify, and reuse **PrivateFitnessProgress** in your own Zama FHEVM projects under the terms of the MIT license.
