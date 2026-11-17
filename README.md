# StablePay — escrowed tUSD8 payments on Aevum testnet

> Aevum Builder Challenge #1 (DoraHacks) · Solo entry by Fngyuan
> ([@sawi57003-ops](https://github.com/sawi57003-ops))

**One flow, done end-to-end:** a buyer locks **tUSD8** in escrow, the seller marks
the order delivered, and the funds move **only when the buyer confirms delivery**
(or an arbiter resolves a dispute, or the deadline expires and the buyer is
refunded). No one can move the money except through the rules below — the buyer
never pays before delivery is confirmed, and the seller is protected by an
auto-release once the buyer stays silent past the confirmation window.

## Why escrow (and not a pay-link or a split router)

Of the three obvious stablecoin flows, escrow is the one where the smart contract
adds real trust instead of just moving tokens:

| Flow | What the contract adds | Verdict |
|---|---|---|
| Invoice / pay-link | Almost nothing — a plain `transfer` does the same job | Too thin |
| Split-payment router | Splits one payment between recipients | Useful, but no trust problem solved |
| **Escrowed payment** | **Trust**: money moves only on delivery confirmation, dispute, or deadline — with a full on-chain audit trail | **Built** |

It also maps directly onto the challenge's judging criteria: safety controls
(spend cap, deadlines, least-privilege roles, revocation-free design), real
utility (anyone selling goods/services for stablecoins needs this), and
Aevum-native integration (tUSD8 + EVM-identical Solidity on chain 44005).

## How it works

```
buyer --approve--> escrow --createOrder(seller, arbiter, amount, deadline)-->
  FUNDED --seller: markDelivered()--> DELIVERED
    --buyer: confirmDelivery()--> COMPLETED (seller paid)
    --buyer: raiseDispute()--> DISPUTED --arbiter: resolveDispute()-->
         COMPLETED (seller paid) or REFUNDED (buyer refunded)
    --seller, after 3-day silence: claimRelease()--> COMPLETED
  FUNDED --buyer: cancelOrder()--> REFUNDED
  FUNDED --deadline passed, buyer: claimRefund()--> REFUNDED
```

Rules enforced on-chain (see `src/StablePayEscrow.sol`):

- **One order, one escrow:** funds are pulled with `safeTransferFrom` at creation
  and can only leave through a state transition.
- **Spend cap:** no order above 100,000 tUSD8 (`MAX_ORDER_AMOUNT`).
- **Deadlines:** delivery deadline must be ≥ 1 hour in the future; the buyer can
  reclaim funds after it passes without delivery.
- **Confirmation window:** 3 days after delivery is marked. If the buyer neither
  confirms nor disputes, the seller may claim the release.
- **Disputes:** only the buyer can raise one, only inside the window, only when an
  arbiter was set. Only the arbiter can resolve it.
- **Least privilege:** no owner, no admin, no upgradeability — every function
  checks `msg.sender` against exactly one role. All state changes are
  `nonReentrant` and emit events (full audit trail on the explorer).

## Contracts (Aevum testnet, chain 44005)

| Item | Value |
|---|---|
| Network | QDay Aevum Testnet, chain ID 44005 |
| RPC | https://rpc-test.qday.info |
| Explorer | https://explorer-test.qday.info |
| tUSD8 | `0x456569838f1d43009A91ebA4263147Afd7233483` (6 decimals) |
| StablePayEscrow | *(filled in at deploy — see `deployments/aevum-testnet.json`)* |

Get testnet tokens: tQDAY from https://faucet.qday.info (5 per day; the faucet
covers gas for the first claim), tUSD8 from the same faucet's tUSD8 tab
(1 tUSD8 per claim, relayed). Both are testnet-only and worthless.

## Live demo

- **Web UI:** `app/index.html` — static page, connect MetaMask (Aevum testnet),
  create orders, confirm / dispute / resolve from the order list. Serve locally:
  `python3 -m http.server -d app 8080`, or build the Docker image:
  `docker build -t stablepay . && docker run -p 8080:80 stablepay`.
- **CLI demo:** `node script/demo.mjs` — runs three complete payments on-chain
  (happy path, cancel/refund, dispute → arbiter release) and prints every tx
  hash + explorer link. Uses the burn wallet keystore (testnet only).
- **Demo video:** *(link added after recording)*

## Run it yourself

```bash
# 1. Install deps
forge install            # pulls forge-std + OpenZeppelin
npm install              # ethers v6 for the demo script

# 2. Test (14 tests, no network needed)
forge test

# 3. Deploy to Aevum testnet (needs tQDAY for gas in the keystore wallet)
forge script script/Deploy.s.sol --rpc-url https://rpc-test.qday.info \
  --broadcast --keystore ~/.wallets/burn/keystore.json \
  --password-file ~/.wallets/burn/.password
# Writes deployments/aevum-testnet.json + app/config.js

# 4. Verify source on the explorer
forge verify-contract --chain-id 44005 --verifier blockscout \
  --verifier-url https://explorer-test.qday.info/api \
  <ESCROW_ADDRESS> src/StablePayEscrow.sol:StablePayEscrow

# 5. Run the full flow on-chain
node script/demo.mjs
```

## End-to-end runs on testnet

*(filled in after the demo run — contract address, order ids, tx hashes, explorer links)*

| # | Path | Order | Tx hashes |
|---|---|---|---|
| 1 | Happy path: create → deliver → confirm | — | — |
| 2 | Cancel before delivery → refund | — | — |
| 3 | Dispute → arbiter releases to seller | — | — |

## Project layout

```
src/StablePayEscrow.sol   escrow contract (the whole flow)
test/StablePayEscrow.t.sol  14 Foundry tests (happy path, refunds, disputes, access control)
script/Deploy.s.sol       Foundry deploy script (writes deployments/ + app/config.js)
script/demo.mjs           Node CLI: 3 complete payments on-chain, prints tx hashes
app/index.html            static demo UI (MetaMask, no build step)
app/config.js             network + contract addresses (generated at deploy)
Dockerfile                serves app/ with nginx
```

## Notes

- All code in this repo was written for this challenge (16 Nov – 11 Dec 2026).
  Patterns and know-how from earlier work were reused; no file was copied from
  another submission.
- Testnet only. tQDAY and tUSD8 have no monetary value and must never be sent to
  mainnet addresses.
