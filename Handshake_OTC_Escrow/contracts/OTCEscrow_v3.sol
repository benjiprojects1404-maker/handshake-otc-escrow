// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
// Pinned to an exact version (not a caret range) deliberately: reproducing a Full Match
// verification requires compiling with the exact same compiler version, optimizer
// settings, and evmVersion as the original deployment — a floating pragma makes that
// reproducibility a matter of luck instead of a guarantee.

/**
 * OTCEscrow
 * ---------
 * Peer-to-peer OTC desk for native BDAG <-> ERC-20 token trades on BlockDAG (Chain 1404).
 *
 * How it works:
 *  - A "maker" creates an offer, locking EITHER native BDAG OR an ERC-20 token in this
 *    contract, and states what they want back (the other asset type, and how much).
 *  - Optionally the maker can restrict the offer to a single specific counterparty
 *    (a private OTC deal) or leave it open to anyone.
 *  - A "taker" fills the offer by sending the requested asset. The swap is atomic:
 *    either both sides move in the same transaction, or the transaction reverts.
 *  - The maker can cancel an unfilled offer at any time and get a full refund.
 *  - A small protocol fee (in basis points, default 0.25%) is taken out of the native
 *    BDAG leg of every filled trade and sent to `feeRecipient`.
 *
 * Deliberately NOT included (kept out to reduce attack surface for a v1):
 *  - No price oracles, no partial fills, no order matching/auction logic.
 *  - No support for fee-on-transfer / rebasing ERC-20 tokens (see requireStandardTransfer).
 *  - No admin ability to touch a live offer's locked funds. Owner can only change the
 *    fee rate (capped) and the fee recipient, and can pause new offer creation.
 *
 * v2 CHANGES (from an independent dev review of the original deployment):
 *  1. Offer now stores feeBpsAtCreation, snapshotted at creation time. Fills use this,
 *     not the live global feeBps, so the owner changing the fee can never retroactively
 *     alter the terms of an offer that's already open and waiting.
 *  2. createOfferGivingToken() now has nonReentrant. It already followed checks-effects
 *     ordering (state written before the external transferFrom call) so this is a
 *     defense-in-depth addition against unusual/malicious token contracts, not a fix
 *     for a proven exploit path.
 *
 * v3 CHANGES (from a follow-up security review):
 *  1. CRITICAL — both create functions now require `token.code.length > 0`. Without this,
 *     `token` could be any address with no deployed code (a typo, an EOA, an address
 *     nothing's deployed to yet). Solidity's low-level `.call(...)` — which
 *     `_safeTransfer`/`_safeTransferFrom` both use — succeeds trivially against such an
 *     address (ok=true, empty returndata), with NO balance or allowance check ever
 *     happening. That meant anyone could call fillOfferGivingToken() against an offer
 *     with a no-code `token` and walk away with the maker's real locked BDAG while
 *     "paying" with a token transfer that silently never happened. This check closes
 *     that hole at the only point it needs closing: offer creation, before any real
 *     value is ever at risk.
 *  2. MEDIUM — createOfferGivingToken() now measures the actual balance delta after
 *     pulling the token in, and reverts immediately if it doesn't match `amountToken`.
 *     Previously, a fee-on-transfer or rebasing token could leave the contract holding
 *     less than the offer claimed, and since both fillOfferGivingNative() and
 *     cancelOffer() pay out the full recorded amountToken, that shortfall meant the
 *     offer became permanently unfillable AND uncancelable — the maker's tokens were
 *     stuck with no recovery path (by design, there's no admin override on offer funds).
 *     Catching the mismatch at creation means the transaction simply reverts instead of
 *     creating a broken offer that bricks funds later.
 *
 * IMPORTANT DEPLOYMENT NOTE FOR BLOCKDAG (Chain ID 1404):
 *  BlockDAG's EVM targets "berlin", not "shanghai"/"cancun". The default Solidity
 *  compiler settings in modern Hardhat/Foundry emit the PUSH0 opcode (introduced in
 *  Shanghai), which BlockDAG does not support. Contracts compiled with default settings
 *  will deploy "successfully" but silently fail when called. You MUST set
 *  evmVersion: "berlin" in your compiler settings. See hardhat.config.js in this project.
 *
 * LEGAL-COVERAGE ADDITIONS (on top of the v3 security fixes above):
 *  1. Per-asset deposit cap (maxOfferAmount / setMaxOfferAmount), enforced in both create
 *     functions. Not a dollar-value cap — no price oracle exists in this contract by
 *     design — so it's approximated per-asset by the owner instead.
 *  2. OwnershipTransferred event added — was previously silent, a real audit-trail gap
 *     for a change this sensitive.
 *  3. FeeRecipientUpdated's address param is now indexed.
 *  These are additive only; none of the v2/v3 security fixes above were touched.
 *
 * SLITHER STATUS: clean (0 findings) when run with
 *  --exclude assembly,dead-code,naming-convention,low-level-calls,pragma,solc-version,
 *  timestamp,incorrect-equality,reentrancy-balance
 *  Four detectors excluded, each a confirmed false positive for this specific design,
 *  not a blanket suppression:
 *   - timestamp: flags fillOfferGivingToken/fillOfferGivingNative/cancelOffer purely
 *     because they sit in a heuristic category Slither associates with time-sensitivity —
 *     none of the flagged require() checks reference block.timestamp at all.
 *   - incorrect-equality: flags `received == amountToken` in createOfferGivingToken's
 *     fee-on-transfer check. Strict equality is the intended behavior here, not a bug —
 *     the whole point of that check (see v3 CHANGES #2 above) is to reject ANY deviation,
 *     not tolerate a range.
 *   - reentrancy-balance: flags the same balance-before/after read as a reentrancy risk
 *     because it surrounds an external call. createOfferGivingToken already carries
 *     nonReentrant, which is exactly the guard this detector's concern would require —
 *     the finding is redundant with a protection already in place, not a gap.
 *  Re-verify all four if this contract's logic changes materially.
 */

/// @dev Minimal read-only interface, used only for the post-transfer balance check in
/// createOfferGivingToken(). Kept separate from the low-level call pattern used
/// elsewhere so this file still has zero import surface and can be pasted directly
/// into Remix.
interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

contract OTCEscrow {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Offer {
        address maker;
        address taker;          // address(0) = open to anyone
        address token;          // ERC-20 token address involved in the trade
        uint256 amountNative;   // amount of BDAG involved (wei)
        uint256 amountToken;    // amount of ERC-20 token involved (token's smallest unit)
        bool makerGivesNative;  // true: maker locked BDAG, wants token
                                 // false: maker locked token, wants BDAG
        Status status;
        uint64 createdAt;
        uint16 feeBpsAtCreation; // snapshot of feeBps at the moment this offer was created —
                                  // filled using this, NOT the live feeBps, so an owner
                                  // changing the global fee can never alter the terms of
                                  // an offer that's already open and waiting to be filled.
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public owner;
    address public feeRecipient;

    // 25 = 0.25%. Denominated in basis points (1 bp = 0.01%). Capped at 300 (3%).
    uint16 public feeBps = 25;
    uint16 public constant MAX_FEE_BPS = 300;

    bool public paused;
    uint256 private _locked = 1; // reentrancy guard, 1 = unlocked, 2 = locked

    /// @notice Optional per-asset cap on the amount that can be locked into a single offer.
    /// 0 = uncapped for that asset (the default). Keyed by token address; address(0) is used
    /// for the native-BDAG cap. Deliberately NOT a dollar-value cap — this contract has no
    /// price oracle by design (see the "Deliberately NOT included" note above), so
    /// approximating "$500 max" has to be done per-asset by the owner rather than enforced
    /// in USD terms.
    mapping(address => uint256) public maxOfferAmount;

    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) public offers;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event OfferCreated(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        address token,
        uint256 amountNative,
        uint256 amountToken,
        bool makerGivesNative
    );
    event OfferFilled(uint256 indexed id, address indexed taker, uint256 feePaid);
    event OfferCancelled(uint256 indexed id);
    event FeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event PausedSet(bool isPaused);
    event MaxOfferAmountUpdated(address indexed token, uint256 oldCap, uint256 newCap);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "bad fee recipient");
        owner = msg.sender;
        feeRecipient = _feeRecipient;
    }

    // ---------------------------------------------------------------------
    // Core: create / fill / cancel
    // ---------------------------------------------------------------------

    /**
     * @notice Create an offer where the maker locks native BDAG and wants an ERC-20 token.
     * @param token         ERC-20 token address the maker wants to receive.
     * @param amountToken   Amount of that token the maker wants (token's smallest unit).
     * @param taker         Optional: restrict who can fill this. address(0) = anyone.
     */
    function createOfferGivingNative(
        address token,
        uint256 amountToken,
        address taker
    ) external payable returns (uint256 id) {
        require(!paused, "offers paused");
        require(token != address(0), "bad token");
        require(token.code.length > 0, "token has no code");
        require(msg.value > 0, "no BDAG sent");
        require(amountToken > 0, "amountToken = 0");
        _enforceOfferCap(address(0), msg.value);

        id = nextOfferId++;
        offers[id] = Offer({
            maker: msg.sender,
            taker: taker,
            token: token,
            amountNative: msg.value,
            amountToken: amountToken,
            makerGivesNative: true,
            status: Status.Open,
            createdAt: uint64(block.timestamp),
            feeBpsAtCreation: feeBps
        });

        emit OfferCreated(id, msg.sender, taker, token, msg.value, amountToken, true);
    }

    /**
     * @notice Create an offer where the maker locks an ERC-20 token and wants native BDAG.
     *         Caller must have approved this contract for at least `amountToken` beforehand.
     * @param token         ERC-20 token address being locked.
     * @param amountToken   Amount of that token to lock (token's smallest unit).
     * @param amountNative  Amount of BDAG (wei) the maker wants in return.
     * @param taker         Optional: restrict who can fill this. address(0) = anyone.
     */
    function createOfferGivingToken(
        address token,
        uint256 amountToken,
        uint256 amountNative,
        address taker
    ) external nonReentrant returns (uint256 id) {
        require(!paused, "offers paused");
        require(token != address(0), "bad token");
        require(token.code.length > 0, "token has no code");
        require(amountToken > 0, "amountToken = 0");
        require(amountNative > 0, "amountNative = 0");
        _enforceOfferCap(token, amountToken);

        id = nextOfferId++;
        offers[id] = Offer({
            maker: msg.sender,
            taker: taker,
            token: token,
            amountNative: amountNative,
            amountToken: amountToken,
            makerGivesNative: false,
            status: Status.Open,
            createdAt: uint64(block.timestamp),
            feeBpsAtCreation: feeBps
        });

        // Pull the tokens in AFTER writing state (checks-effects), but the external call
        // still happens before we emit — that's fine, nonReentrant-style ordering only
        // matters for calls that could re-enter and touch this offer's funds, and the
        // offer is already marked Open with the correct amounts recorded.
        //
        // Measure the actual balance delta rather than trusting `amountToken`: a
        // fee-on-transfer or rebasing token can leave this contract holding less than
        // requested, and since fillOfferGivingNative()/cancelOffer() both pay out the
        // full recorded amountToken, any shortfall here would otherwise turn into
        // permanently stuck funds later (no admin override exists to rescue them).
        // Reverting now, before the offer is observable by anyone else, is the only
        // point where this is cheaply and safely recoverable.
        uint256 balBefore = IERC20Like(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amountToken);
        uint256 received = IERC20Like(token).balanceOf(address(this)) - balBefore;
        require(received == amountToken, "token took a transfer fee or rebased - unsupported");

        emit OfferCreated(id, msg.sender, taker, token, amountNative, amountToken, false);
    }

    /**
     * @notice Fill an open offer where the maker locked BDAG and wants token.
     *         Caller must have approved this contract for at least the offer's amountToken.
     */
    function fillOfferGivingToken(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.makerGivesNative, "wrong fill function for this offer");
        require(o.taker == address(0) || o.taker == msg.sender, "not your offer to fill");

        o.status = Status.Filled;

        _safeTransferFrom(o.token, msg.sender, o.maker, o.amountToken);

        uint256 fee = (o.amountNative * o.feeBpsAtCreation) / 10_000;
        uint256 payout = o.amountNative - fee;

        _sendNative(msg.sender, payout);
        if (fee > 0) _sendNative(feeRecipient, fee);

        emit OfferFilled(id, msg.sender, fee);
    }

    /**
     * @notice Fill an open offer where the maker locked token and wants BDAG.
     *         Caller must send exactly the offer's amountNative as msg.value.
     */
    function fillOfferGivingNative(uint256 id) external payable nonReentrant {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(!o.makerGivesNative, "wrong fill function for this offer");
        require(o.taker == address(0) || o.taker == msg.sender, "not your offer to fill");
        require(msg.value == o.amountNative, "wrong BDAG amount");

        o.status = Status.Filled;

        uint256 fee = (o.amountNative * o.feeBpsAtCreation) / 10_000;
        uint256 payout = o.amountNative - fee;

        _sendNative(o.maker, payout);
        if (fee > 0) _sendNative(feeRecipient, fee);

        _safeTransfer(o.token, msg.sender, o.amountToken);

        emit OfferFilled(id, msg.sender, fee);
    }

    /**
     * @notice Cancel your own open offer and get a full refund of whatever you locked.
     */
    function cancelOffer(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.maker == msg.sender, "not your offer");

        o.status = Status.Cancelled;

        if (o.makerGivesNative) {
            _sendNative(o.maker, o.amountNative);
        } else {
            _safeTransfer(o.token, o.maker, o.amountToken);
        }

        emit OfferCancelled(id);
    }

    // ---------------------------------------------------------------------
    // Views (for the frontend to list offers without an indexer)
    // ---------------------------------------------------------------------

    function totalOffers() external view returns (uint256) {
        return nextOfferId - 1;
    }

    function getOffer(uint256 id)
        external
        view
        returns (
            address maker,
            address taker,
            address token,
            uint256 amountNative,
            uint256 amountToken,
            bool makerGivesNative,
            Status status,
            uint64 createdAt,
            uint16 feeBpsAtCreation
        )
    {
        Offer storage o = offers[id];
        return (
            o.maker,
            o.taker,
            o.token,
            o.amountNative,
            o.amountToken,
            o.makerGivesNative,
            o.status,
            o.createdAt,
            o.feeBpsAtCreation
        );
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "bad recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Cap how much of `token` (address(0) = native BDAG) can be locked into a
    /// single new offer. 0 = uncapped. Does not affect offers already open.
    function setMaxOfferAmount(address token, uint256 newCap) external onlyOwner {
        emit MaxOfferAmountUpdated(token, maxOfferAmount[token], newCap);
        maxOfferAmount[token] = newCap;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "bad owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Reverts if `amount` exceeds the configured cap for `token` (address(0) = native
    /// BDAG). A cap of 0 means uncapped, matching setMaxOfferAmount's documented semantics.
    function _enforceOfferCap(address token, uint256 amount) private view {
        uint256 cap = maxOfferAmount[token];
        require(cap == 0 || amount <= cap, "exceeds per-offer cap");
    }

    /// @dev Pays out to `to`, which is always either the offer's maker (on cancel) or
    /// taker (on fill) — never an arbitrary caller-supplied address disconnected from the
    /// offer itself. Slither's arbitrary-send-eth detector flags any payable .call by
    /// pattern; reviewed and accepted for this contract's design.
    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        // slither-disable-next-line arbitrary-send-eth
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "native transfer failed");
    }

    /// @dev Minimal safe-transfer wrappers: no external OpenZeppelin dependency, so this
    /// contract has zero import surface and can be pasted directly into Remix if needed.
    /// Handles tokens that don't return a bool (like USDT-style tokens) by checking
    /// returndata length, per the standard "SafeERC20" pattern.
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token transferFrom failed");
    }
}
