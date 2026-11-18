# Handshake v4: review notes

`HandshakeV4.sol` replaces the v3 escrow with offers that **never hold funds**. Not deployed yet.

## What changes for users

| | v3 (live) | v4 |
|---|---|---|
| Making an offer | Deposit BDAG or tokens into the contract | Approve your token (or WBDAG); nothing leaves your wallet |
| Selling BDAG | Send BDAG with the offer | Hold it as WBDAG (Reef's wrapped BDAG, 1:1) and approve that |
| Taker receives | BDAG or tokens from the contract | The same, straight from the maker's wallet; BDAG arrives as real BDAG (the contract unwraps WBDAG inside the fill) |
| Cancelling | Contract refunds your deposit | Just marks the offer cancelled (nothing to refund). Revoking the approval also stops fills |
| If the maker moves their funds | n/a (funds were locked) | The fill fails and nothing moves; the site greys the offer out with `offerReady(id)` |
| Expiry | None | Optional per offer |
| Pause | Stops new offers | Stops new offers **and fills** (safe now: makers keep their funds). Cancelling always works |

Fee (0.25% of the BDAG leg, max 3%, fixed per offer at creation), per-offer caps, fee recipient and owner
hand-over all work as in v3. No function lets the owner move anyone's funds.

## Checks kept from v3

- The token must have code (closes the "no-code token" fake-payment hole fixed in v3).
- Fee-on-transfer and rebasing tokens are refused: the receiver's balance must rise by exactly the amount.
- Safe transfers that handle tokens returning nothing (USDT style). Reentrancy guard on create and fill.

## New checks

- Creating an offer requires the maker's balance and approval to be there now (stops spam offers).
- WBDAG can't be used as "the token" (BDAG is always the native side).
- Can't make an offer to yourself or fill your own offer.
- The contract refuses direct BDAG; only WBDAG can send it BDAG, while unwrapping during a fill.

## Tests

`test/foundry/HandshakeV4.t.sol`: 21 unit and fuzz tests plus an invariant test.

- Both trade directions, checking every balance and that the contract holds **nothing** afterwards.
- Maker moves or revokes funds after posting: the fill fails, and the taker keeps everything.
- Expiry, private taker, fill once only, the maker can't fill their own offer, wrong BDAG amount.
- Fee-on-transfer token in both directions, fee fixed at creation, zero fee, caps, pause, admin limits.
- A maker contract that refuses BDAG (the fill fails cleanly) and a token that tries to re-enter (blocked).
- Fuzz: any amounts and fee from 0 to 3%, in both directions; value is conserved and nothing is held.
- **Invariant:** across random create/fill/cancel/move-away sequences (1,000 runs × 200 calls at CI depth), the
  contract never holds BDAG, WBDAG or tokens.

Also checked: compiled for EVM berlin with **no PUSH0**; deployed on a local berlin chain (chain ID 1404, legacy
transactions) and ran both trade directions with real transactions. Fees were correct and the contract ended at zero.

## Deploying (later)

1. Constructor: `HandshakeV4(WBDAG, feeRecipient)` with WBDAG `0x62ba5c4F067989a7f6644488C875bEa69Bfa1FBA` and the
   current fee recipient `0x26bDba7b184df8b88965Bed46AEd6ea0E60fF940`. Compile: solc 0.8.24, optimizer 200, berlin.
2. Hand ownership to the 2-of-3 multisig `0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc`; set the same per-offer caps.
3. Pause **new offers** on v3 (`setPaused(true)` from the multisig). Existing v3 offers can still be filled or
   cancelled, as before.
4. Site: put the v4 address in `CONTRACT_ADDRESS` (index.html) and `ESCROW` (embed/index.html), then merge the
   site PR. The main page then makes v4 offers (with a one-click "wrap BDAG" step for BDAG sellers and approvals
   instead of deposits, and greys out offers whose maker has moved their funds); `/v3/` keeps working for older
   offers.
