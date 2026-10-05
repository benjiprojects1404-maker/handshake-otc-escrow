# Handshake — OTC Escrow on BlockDAG

Peer-to-peer OTC trades between native BDAG and any ERC-20 on BlockDAG (chain ID 1404). A maker locks BDAG or a
token in an open offer; a counterparty fills it and both sides settle in one atomic transaction, or nothing moves.
The maker can cancel an unfilled offer at any time and gets their asset straight back.

**Custody, plainly:** while an offer is open, the maker's asset is held by the smart contract, not by us or any
other person. The contract's rules decide where it goes: to the taker on fill, back to the maker on cancel.

**Status: beta.** Unaudited, experimental software on an early-stage chain. Start with small amounts.

- Website: https://handshakeotc.fyi
- Explorer: https://explorer.blockdag.engineering (the live contract's verified source is on explorer.bdagexplorer.com, linked from the site, until it can be verified on blockdag.engineering)

## Deployed contracts

| What | Address | Notes |
|---|---|---|
| **OTCEscrow (live)** | `0xD907701A2D96f7D0E7596b02737C9F36446cf5CA` | `contracts/OTCEscrow_v3.sol`. Verified on explorer.bdagexplorer.com |
| OTCEscrow (original) | `0x3A8716b7260D2F808250d37F4534Ebe22b6C4b8a` | `contracts/OTCEscrow_v3_original.sol`. **Paused**, never had an offer, holds nothing |
| Owner: 2-of-2 multisig (Trezor + Ledger) | `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc` | Since 1 Oct 2026 (block 22975549). Same multisig that owns Nodal and holds Reef's `feeToSetter` |
| Fee recipient | `0x26bDba7b184df8b88965Bed46AEd6ea0E60fF940` | |

Both sources compile to exactly the deployed runtime code with **Solidity 0.8.24, optimizer on / 200 runs, EVM
`berlin`** (BlockDAG's EVM targets Berlin; newer EVM versions compile but then fail on-chain). The contract has no
external imports and no immutables.

## Contract rules

- **Fee:** 0.25% (`feeBps = 25`), taken from the BDAG side of a filled trade, hard-capped in the contract at 3%.
- **Pause:** `setPaused(true)` stops *new* offers only. Existing offers can still be filled or cancelled.
- **Beta limits:** `setMaxOfferAmount(token, cap)` limits how much a maker can lock in one offer. Use the zero
  address for BDAG. `0` means no limit. Any token without its own cap is unlimited.
  Currently set: **100 BDAG** and **1,000,000 NOCAP** per offer.
- **Owner-only:** `setFeeBps`, `setFeeRecipient`, `setPaused`, `setMaxOfferAmount`, `transferOwnership`
  (single-step, so double-check the address). The owner is the multisig, so each of these needs both hardware
  wallets: submit → confirm → execute, the same flow as Nodal (see the Nodal README's "Admin actions" section,
  with `0xD907701A2D96f7D0E7596b02737C9F36446cf5CA` as the target). The multisig doesn't revert if the inner call
  fails, so always check the proposal shows `executed: true`.

## Website

`Handshake_OTC_Escrow/index.html` is a single static page (ethers v6 from cdnjs), deployed with Cloudflare Pages.
Pushes to `main` redeploy it. The old `otcescrow.pages.dev` address forwards to https://handshakeotc.fyi.

Before sending anything, the page checks the contract's pause state and the per-offer limit, the user's balance, and
that the token address is a real contract, so users get a clear message instead of a failed transaction.

## Reporting a vulnerability

Please report security issues privately to **security@handshakeotc.fyi**, not in public issues, so they can be fixed
(or new offers paused) first.

## Disclaimer

Experimental software. Not audited. Not financial advice.
