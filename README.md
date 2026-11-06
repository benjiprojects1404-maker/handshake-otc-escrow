# Handshake — OTC Escrow on BlockDAG

Peer-to-peer OTC trades between native BDAG and any ERC-20 on BlockDAG (chain ID 1404). A maker locks BDAG or a
token in an open offer; a counterparty fills it and both sides settle in one atomic transaction, or nothing moves.
The maker can cancel an unfilled offer at any time and gets their asset straight back.

**Custody, plainly:** while an offer is open, the maker's asset is held by the smart contract, not by us or any
other person. The contract's rules decide where it goes: to the taker on fill, back to the maker on cancel.

**Status: beta.** Unaudited, experimental software on an early-stage chain. Start with small amounts.

- Website: https://handshakeotc.fyi
- Explorer: https://explorer.east.bdag-us.org (the live contract's verified source is on explorer.bdagexplorer.com, linked from the site, until it can be verified on blockdag.engineering)

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

## Fuzz and invariant tests (Foundry)

Stateful fuzzing for the deployed escrow, `Handshake_OTC_Escrow/contracts/OTCEscrow_v3.sol`, in `test/foundry/`.
Same setup as Chord OTC's `foundry-tests` branch.

```bash
git submodule update --init      # forge-std v1.17.0
forge test                       # 256 runs x 100 calls per invariant, 1,000 runs per fuzz test
FOUNDRY_PROFILE=ci forge test    # 1,000 runs x 200 calls per invariant
```

A handler drives random sequences of creates, fills and cancels from four wallets plus a wallet contract that can refuse
BDAG, across three tokens (plain, one that returns nothing on transfer, one that can switch on a transfer tax), while it
also changes the fee, pauses, sets per-offer caps and blocks transfers. Checked after every sequence:

| | Invariant |
|---|---|
| I1 | The escrow's BDAG balance equals the BDAG locked by open offers |
| I2 | The escrow's balance of each token equals the tokens locked by open offers |
| I3 | Every offer's status matches the handler's record, and a filled or cancelled offer can never be filled or cancelled again |
| I4 | The fee recipient receives exactly `amountNative * feeBpsAtCreation / 10,000` per fill, never the live fee |
| I5 | Each offer keeps the fee that applied when it was created |
| I6 | Offer ids never skip or repeat |

Plus single-property fuzz tests: exact split on fill, fee changes don't touch open offers, exact refunds and maker-only
cancel, the per-offer cap, taxed tokens refused at creation, and private offers fillable only by their named taker.

Each test was checked by breaking the contract on purpose (filling with the live fee instead of the snapshot; a cancel
that leaves the offer open) and confirming the tests then fail.
