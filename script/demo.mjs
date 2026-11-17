#!/usr/bin/env node
// StablePay demo runner — full escrow flow on Aevum testnet, end to end.
//
// What it does (3 complete payments, all on-chain):
//   1. Happy path: create order -> seller marks delivered -> buyer confirms.
//   2. Cancel path: create order -> buyer cancels -> full refund.
//   3. Dispute path: create order -> seller delivers -> buyer disputes ->
//      arbiter releases to seller.
// Every step prints its tx hash + explorer link, and the script verifies the
// resulting on-chain state after each step.
//
// The buyer is the burn wallet (keystore, testnet only). The seller and the
// arbiter are fresh ephemeral wallets generated for this run and funded with
// a little tQDAY for gas — they hold no other funds.
//
// Usage:
//   node script/demo.mjs            (reads deployments/aevum-testnet.json)
//   ESCROW=0x... node script/demo.mjs   (override contract address)
//   KEYSTORE=~/.wallets/burn/keystore.json PASSWORD_FILE=~/.wallets/burn/.password
//
// The keystore password is read from a file and never printed or logged.
import { ethers } from "ethers";
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";

const RPC = "https://rpc-test.qday.info";
const EXPLORER = "https://explorer-test.qday.info";
const TUSD8 = "0x456569838f1d43009A91ebA4263147Afd7233483";
const CHAIN_ID = 44005;

const ESCROW_ABI = [
  "function createOrder(address seller, address arbiter, uint256 amount, uint256 deliveryDeadline) returns (uint256)",
  "function markDelivered(uint256 orderId)",
  "function confirmDelivery(uint256 orderId)",
  "function cancelOrder(uint256 orderId)",
  "function raiseDispute(uint256 orderId)",
  "function resolveDispute(uint256 orderId, bool releaseToSeller)",
  "function getOrder(uint256 orderId) view returns (tuple(address buyer, address seller, address arbiter, uint256 amount, uint256 deliveryDeadline, uint256 deliveredAt, uint8 state))",
  "function orderCount() view returns (uint256)",
];
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
];
const STATE = ["FUNDED", "DELIVERED", "COMPLETED", "REFUNDED", "DISPUTED"];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const link = (hash) => `${EXPLORER}/tx/${hash}`;
const fmt = (v) => ethers.formatUnits(v, 6);

function escrowAddress() {
  if (process.env.ESCROW) return process.env.ESCROW;
  const p = "deployments/aevum-testnet.json";
  if (existsSync(p)) return JSON.parse(readFileSync(p, "utf8")).escrow;
  throw new Error("No escrow address: set ESCROW env or deploy first (forge script script/Deploy.s.sol).");
}

async function loadBuyer(provider) {
  const ks = (process.env.KEYSTORE || "~/.wallets/burn/keystore.json").replace("~", homedir());
  const pf = (process.env.PASSWORD_FILE || "~/.wallets/burn/.password").replace("~", homedir());
  const json = readFileSync(ks, "utf8");
  const password = readFileSync(pf, "utf8").trim();
  const wallet = await ethers.Wallet.fromEncryptedJson(json, password);
  return wallet.connect(provider);
}

async function send(label, txPromise) {
  const tx = await txPromise;
  console.log(`  ${label}: ${link(tx.hash)}`);
  const rc = await tx.wait();
  if (rc.status !== 1) throw new Error(`${label} reverted: ${tx.hash}`);
  return rc;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
  const escrowAddr = escrowAddress();
  console.log(`Network: Aevum testnet (44005) — ${RPC}`);
  console.log(`Escrow:  ${EXPLORER}/address/${escrowAddr}`);
  console.log(`tUSD8:   ${EXPLORER}/address/${TUSD8}`);

  const buyer = await loadBuyer(provider);
  const escrow = new ethers.Contract(escrowAddr, ESCROW_ABI, buyer);
  const token = new ethers.Contract(TUSD8, ERC20_ABI, buyer);
  console.log(`Buyer:   ${buyer.address}`);
  console.log(`  tQDAY: ${ethers.formatEther(await provider.getBalance(buyer.address))}`);
  console.log(`  tUSD8: ${fmt(await token.balanceOf(buyer.address))}`);

  // Ephemeral seller + arbiter, funded with gas by the buyer.
  const seller = ethers.Wallet.createRandom().connect(provider);
  const arbiter = ethers.Wallet.createRandom().connect(provider);
  console.log(`Seller (ephemeral):  ${seller.address}`);
  console.log(`Arbiter (ephemeral): ${arbiter.address}`);
  for (const w of [seller, arbiter]) {
    await send(`fund gas -> ${w.address.slice(0, 10)}…`, buyer.sendTransaction({ to: w.address, value: ethers.parseEther("0.01") }));
  }

  // One approval covers all three demo orders.
  // Amount per order (default 5 tUSD8) — lower it if tUSD8 is scarce:
  //   DEMO_AMOUNT=1 node script/demo.mjs
  const perOrder = BigInt(process.env.DEMO_AMOUNT || "5") * 10n ** 6n;
  const total = 3n * perOrder;
  const allowance = await token.allowance(buyer.address, escrowAddr);
  if (allowance < total) {
    await send(`approve ${fmt(total)} tUSD8`, token.approve(escrowAddr, total));
  }

  const deadline = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
  const results = [];

  // ---- Payment 1: happy path -------------------------------------------
  console.log("\n== Payment 1: happy path (per-order tUSD8) ==");
  const count0 = await escrow.orderCount();
  await send("createOrder #1", escrow.createOrder(seller.address, arbiter.address, perOrder, deadline));
  const id1 = count0;
  await send("markDelivered #1", escrow.connect(seller).markDelivered(id1));
  await send("confirmDelivery #1", escrow.confirmDelivery(id1));
  const o1 = await escrow.getOrder(id1);
  console.log(`  order #${id1} state: ${STATE[o1.state]} | seller tUSD8: ${fmt(await token.balanceOf(seller.address))}`);
  if (o1.state !== 2n) throw new Error("payment 1 did not complete");
  results.push({ id: Number(id1), path: "happy", state: STATE[o1.state] });

  // ---- Payment 2: cancel / refund --------------------------------------
  console.log("\n== Payment 2: cancel before delivery (per-order tUSD8) ==");
  const count1 = await escrow.orderCount();
  await send("createOrder #2", escrow.createOrder(seller.address, arbiter.address, perOrder, deadline));
  const id2 = count1;
  const buyerBefore = await token.balanceOf(buyer.address);
  await send("cancelOrder #2", escrow.cancelOrder(id2));
  const o2 = await escrow.getOrder(id2);
  const buyerAfter = await token.balanceOf(buyer.address);
  console.log(`  order #${id2} state: ${STATE[o2.state]} | buyer refunded: ${fmt(buyerAfter - buyerBefore)} tUSD8`);
  if (o2.state !== 3n) throw new Error("payment 2 did not refund");
  results.push({ id: Number(id2), path: "cancel", state: STATE[o2.state] });

  // ---- Payment 3: dispute resolved to seller ----------------------------
  console.log("\n== Payment 3: dispute -> arbiter releases to seller (per-order tUSD8) ==");
  const count2 = await escrow.orderCount();
  await send("createOrder #3", escrow.createOrder(seller.address, arbiter.address, perOrder, deadline));
  const id3 = count2;
  await send("markDelivered #3", escrow.connect(seller).markDelivered(id3));
  await send("raiseDispute #3", escrow.raiseDispute(id3));
  await send("resolveDispute #3 (release)", escrow.connect(arbiter).resolveDispute(id3, true));
  const o3 = await escrow.getOrder(id3);
  console.log(`  order #${id3} state: ${STATE[o3.state]} | seller tUSD8: ${fmt(await token.balanceOf(seller.address))}`);
  if (o3.state !== 2n) throw new Error("payment 3 did not complete");
  results.push({ id: Number(id3), path: "dispute", state: STATE[o3.state] });

  console.log("\n== Done: 3/3 payments settled on-chain ==");
  console.log(JSON.stringify({ escrow: escrowAddr, results }, null, 2));
  await sleep(500);
}

main().catch((e) => {
  console.error("DEMO FAILED:", e.message);
  process.exit(1);
});
