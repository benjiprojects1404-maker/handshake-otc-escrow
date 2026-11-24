// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * Handshake OTC v4.1: peer-to-peer BDAG <-> ERC-20 trades on BlockDAG (chain 1404) that never hold funds.
 * ------------------------------------------------------------------------------------------------------
 *
 * What changed from v4 (HandshakeV4.sol): the fixes made to Chord OTC v2.1 (same non-custodial design) after
 * its Olympix pre-audit scan and Proovant's report.
 *  - Committed amounts (Olympix 5.1.1, Proovant CHORD-01). committed[maker][asset] is the total promised by a
 *    maker's Open offers on that asset (WBDAG when the maker gives BDAG). A new offer needs balance and
 *    approval for that total plus the new amount; fill and cancel release it. An approval given for a new offer
 *    can no longer bring an older offer that lost its backing back to life at its old price. An expired offer
 *    stays committed until its maker cancels it.
 *  - Maker's maximum fee (Olympix 5.2.1). createOffer takes a last argument maxFeeBps and reverts with
 *    "fee above your max" if the fee is higher when it's mined. OfferCreated gains a final feeBps field.
 *  - Taker's own offers stay backed (Proovant CHORD-02). When the taker pays with a token, the fill reverts if
 *    it would leave the taker's own Open offers on that token short of balance or approval.
 *  - Exact token moves are checked at both ends: the payer's balance must drop, and the receiver's rise, by
 *    exactly the amount (pre-audit F-01).
 *  - The fee recipient can't be this contract (F-05); setPaused's parameter is newPaused (F-21/F-22).
 *  - Two-step ownership: transferOwnership names a pending owner, who must call acceptOwnership().
 *  - Caps (Olympix 5.2.2, docs only): maxOfferAmount limits both legs of an offer, the BDAG leg
 *    (address(0)) and the token leg, whichever side the maker gives.
 *
 * What changed from v3 (OTCEscrow_v3.sol)
 *  v3 was an escrow: the maker's BDAG or tokens sat in the contract until the offer was filled or cancelled.
 *  v4 records only the TERMS of an offer. The maker's asset stays in the maker's own wallet, covered by an
 *  ordinary ERC-20 approval, until a taker fills. A fill moves both sides wallet to wallet in one transaction:
 *  if either side is short, the whole transaction reverts and nothing moves.
 *
 *  The contract therefore never keeps a balance between transactions. Inside a fill it can touch funds for a
 *  moment (unwrapping the maker's WBDAG so the taker receives real BDAG, or forwarding the taker's BDAG to the
 *  maker), but every unit is passed on before the transaction ends.
 *
 * How it works
 *  - Maker sells a token for BDAG:  approve the token, call createOffer(token, amountToken, amountNative,
 *    makerGivesNative = false, ...). A taker fills with fill(id) sending exactly amountNative.
 *  - Maker sells BDAG for a token:  native BDAG can't be approved, so the maker holds it as WBDAG (Reef's
 *    wrapped BDAG, 1:1) and approves that. createOffer(..., makerGivesNative = true, ...). A taker fills with
 *    fill(id), having approved the token; the contract pulls the maker's WBDAG, unwraps it and pays the taker
 *    real BDAG.
 *  - Cancel: cancelOffer(id). Nothing to refund, because nothing was deposited. Revoking the approval also
 *    stops an offer from being filled.
 *  - Fee: feeBps (0.25% by default, max 3%) of the BDAG leg, fixed per offer when it's created
 *    (feeBpsAtCreation), so an owner change can never alter an offer that's already open.
 *
 * Kept from v3
 *  - Token must have code (blocks the "no-code token" fake-payment hole fixed in v3).
 *  - Fee-on-transfer and rebasing tokens are refused: the RECEIVER's balance is measured and must go up by
 *    exactly amountToken.
 *  - Per-asset per-offer caps (address(0) = BDAG), pause, fee recipient, owner hand-over with an event.
 *  - The owner can never touch anyone's funds (there are none in the contract, and no function moves any).
 *
 * New
 *  - Optional expiry per offer (0 = no expiry).
 *  - Pause stops new offers AND fills (safe: makers keep their funds). Cancelling always works.
 *  - Creating an offer checks the maker has the balance and approval right now, so the list isn't spammed
 *    with offers that could never fill. offerReady(id) lets the site grey out offers that went stale later.
 *
 * BlockDAG note: compile for EVM "berlin" (no PUSH0).
 */

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IWBDAG {
    function withdraw(uint256 amount) external;
}

contract HandshakeV4_1 {
    // ---------------------------------------------------------------------------------------------
    // Types and storage
    // ---------------------------------------------------------------------------------------------

    enum Status { None, Open, Filled, Cancelled }

    struct Offer {
        address maker;
        address taker;           // address(0) = anyone
        address token;           // the ERC-20 side of the trade
        uint256 amountNative;    // BDAG side (wei)
        uint256 amountToken;     // token side (token's smallest unit)
        bool makerGivesNative;   // true: maker gives BDAG (as approved WBDAG) and wants token
        Status status;
        uint64 createdAt;
        uint64 expiresAt;        // 0 = no expiry
        uint16 feeBpsAtCreation;
    }

    address public immutable WBDAG;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    uint16 public feeBps = 25;
    uint16 public constant MAX_FEE_BPS = 300;
    bool public paused;
    uint256 private _locked = 1;

    /// Per-offer cap per asset (address(0) = BDAG). 0 = no cap.
    mapping(address => uint256) public maxOfferAmount;

    /// Total promised by a maker's Open offers per asset given (WBDAG when the maker gives BDAG).
    mapping(address => mapping(address => uint256)) public committed;

    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) public offers;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event OfferCreated(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        address token,
        uint256 amountNative,
        uint256 amountToken,
        bool makerGivesNative,
        uint64 expiresAt,
        uint16 feeBps
    );
    event OfferFilled(uint256 indexed id, address indexed taker, uint256 feePaid);
    event OfferCancelled(uint256 indexed id);
    event FeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event PausedSet(bool isPaused);
    event MaxOfferAmountUpdated(address indexed token, uint256 oldCap, uint256 newCap);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------------------------------
    // Modifiers and constructor
    // ---------------------------------------------------------------------------------------------

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

    constructor(address wbdag, address _feeRecipient) {
        require(wbdag != address(0) && wbdag.code.length > 0, "bad WBDAG");
        require(_feeRecipient != address(0) && _feeRecipient != address(this), "bad fee recipient");
        WBDAG = wbdag;
        owner = msg.sender;
        feeRecipient = _feeRecipient;
    }

    /// Only WBDAG can send BDAG here, and only while unwrapping inside a fill.
    receive() external payable {
        require(msg.sender == WBDAG, "no direct BDAG");
    }

    // ---------------------------------------------------------------------------------------------
    // Create / fill / cancel
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Post an offer. Nothing is deposited: the maker's side stays in their wallet.
     * @param token            The ERC-20 being traded against BDAG.
     * @param amountToken      Token amount (smallest unit).
     * @param amountNative     BDAG amount (wei).
     * @param makerGivesNative true = maker gives BDAG (must hold and approve WBDAG); false = maker gives token.
     * @param taker            address(0) for anyone, or the one address allowed to fill.
     * @param expiresAt        Unix time after which the offer can't be filled; 0 = no expiry.
     * @param maxFeeBps        The most fee (basis points) the maker accepts; reverts if the fee is higher.
     */
    function createOffer(
        address token,
        uint256 amountToken,
        uint256 amountNative,
        bool makerGivesNative,
        address taker,
        uint64 expiresAt,
        uint16 maxFeeBps
    ) external nonReentrant returns (uint256 id) {
        require(!paused, "paused");
        require(feeBps <= maxFeeBps, "fee above your max");
        require(token != address(0) && token.code.length > 0, "token has no code");
        require(token != WBDAG, "use BDAG, not WBDAG, as the token");
        require(amountToken > 0 && amountNative > 0, "zero amount");
        require(expiresAt == 0 || expiresAt > block.timestamp, "already expired");
        require(taker != msg.sender, "can't trade with yourself");
        _enforceCap(address(0), amountNative);
        _enforceCap(token, amountToken);

        // The maker's balance and approval must cover all their Open offers on this asset plus this one
        // (they can still move later; fill re-checks by moving the exact amounts).
        (address giveAsset, uint256 giveAmount) = makerGivesNative ? (WBDAG, amountNative) : (token, amountToken);
        _commit(giveAsset, giveAmount);

        id = nextOfferId++;
        offers[id] = Offer({
            maker: msg.sender,
            taker: taker,
            token: token,
            amountNative: amountNative,
            amountToken: amountToken,
            makerGivesNative: makerGivesNative,
            status: Status.Open,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            feeBpsAtCreation: feeBps
        });
        emit OfferCreated(id, msg.sender, taker, token, amountNative, amountToken, makerGivesNative, expiresAt, feeBps);
    }

    /**
     * @notice Fill an open offer. Both sides move wallet to wallet in this transaction, or nothing moves.
     *         Maker gives BDAG:  approve the token first; send no BDAG.
     *         Maker gives token: send exactly amountNative as msg.value.
     */
    function fill(uint256 id) external payable nonReentrant {
        require(!paused, "paused");
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.expiresAt == 0 || block.timestamp <= o.expiresAt, "expired");
        require(o.taker == address(0) || o.taker == msg.sender, "not your offer to fill");
        require(msg.sender != o.maker, "can't fill your own offer");

        o.status = Status.Filled;
        _release(o);
        uint256 fee = (o.amountNative * o.feeBpsAtCreation) / 10_000;
        uint256 payout = o.amountNative - fee;

        if (o.makerGivesNative) {
            require(msg.value == 0, "no BDAG needed for this offer");
            // Taker's token -> maker (measured at the maker, so fee-on-transfer tokens are refused).
            _pullExact(o.token, msg.sender, o.maker, o.amountToken);
            // Maker's WBDAG -> here -> unwrapped -> taker (and fee) as real BDAG, all in this transaction.
            _safeTransferFrom(WBDAG, o.maker, address(this), o.amountNative);
            IWBDAG(WBDAG).withdraw(o.amountNative);
            _sendNative(msg.sender, payout);
            _sendNative(feeRecipient, fee);
            // The taker paid with the token: their own Open offers on it must still be backed (CHORD-02).
            _checkTakerStillBacked(o.token);
        } else {
            require(msg.value == o.amountNative, "wrong BDAG amount");
            // Taker's BDAG is forwarded straight on: maker gets the payout, fee recipient the fee.
            _sendNative(o.maker, payout);
            _sendNative(feeRecipient, fee);
            // Maker's token -> taker (measured at the taker).
            _pullExact(o.token, o.maker, msg.sender, o.amountToken);
        }
        emit OfferFilled(id, msg.sender, fee);
    }

    /// @notice Cancel your own open offer. Nothing to refund: your funds never left your wallet.
    function cancelOffer(uint256 id) external {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.maker == msg.sender, "not your offer");
        o.status = Status.Cancelled;
        _release(o);
        emit OfferCancelled(id);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function totalOffers() external view returns (uint256) {
        return nextOfferId - 1;
    }

    function getOffer(uint256 id) external view returns (Offer memory) {
        return offers[id];
    }

    /// @notice True if the offer could be filled right now as far as the maker's side goes
    ///         (open, not expired, not paused, and the maker still has the balance and approval).
    function offerReady(uint256 id) external view returns (bool) {
        Offer storage o = offers[id];
        if (paused || o.status != Status.Open) return false;
        if (o.expiresAt != 0 && block.timestamp > o.expiresAt) return false;
        (address a, uint256 amt) = o.makerGivesNative ? (WBDAG, o.amountNative) : (o.token, o.amountToken);
        return IERC20Like(a).balanceOf(o.maker) >= amt && IERC20Like(a).allowance(o.maker, address(this)) >= amt;
    }

    // ---------------------------------------------------------------------------------------------
    // Admin (no function here can move anyone's funds)
    // ---------------------------------------------------------------------------------------------

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0) && newRecipient != address(this), "bad recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit PausedSet(newPaused);
    }

    /// Cap per new offer for `token` (address(0) = BDAG). 0 = no cap. Applies to both legs of an offer (the
    /// asset given and the asset wanted). Doesn't affect open offers.
    function setMaxOfferAmount(address token, uint256 newCap) external onlyOwner {
        emit MaxOfferAmountUpdated(token, maxOfferAmount[token], newCap);
        maxOfferAmount[token] = newCap;
    }

    /// Two-step ownership transfer: the new owner must call acceptOwnership().
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "bad owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev The maker's balance and approval must cover every Open offer of theirs on `asset` plus this one.
    function _commit(address asset, uint256 amount) private {
        uint256 total = committed[msg.sender][asset] + amount;
        require(IERC20Like(asset).balanceOf(msg.sender) >= total, "maker balance too low for all your open offers");
        require(IERC20Like(asset).allowance(msg.sender, address(this)) >= total, "approve enough for all your open offers");
        committed[msg.sender][asset] = total;
    }

    /// @dev Called once per offer, when it leaves Open (filled or cancelled).
    function _release(Offer storage o) private {
        (address asset, uint256 amt) = o.makerGivesNative ? (WBDAG, o.amountNative) : (o.token, o.amountToken);
        committed[o.maker][asset] -= amt;
    }

    /// @dev After a fill paid in `paid`, the taker's own Open offers on it must still be fully backed. One
    ///      approval backs both, so without this a fill could quietly spend the allowance (or balance) behind the
    ///      taker's own offer and leave it stale (Proovant CHORD-02).
    function _checkTakerStillBacked(address paid) private view {
        uint256 mine = committed[msg.sender][paid];
        if (mine == 0) return;
        require(IERC20Like(paid).balanceOf(msg.sender) >= mine, "fill would leave your own open offers short of balance");
        require(IERC20Like(paid).allowance(msg.sender, address(this)) >= mine, "approve this fill on top of your own open offers");
    }

    function _enforceCap(address asset, uint256 amount) private view {
        uint256 cap = maxOfferAmount[asset];
        require(cap == 0 || amount <= cap, "exceeds per-offer cap");
    }

    /// Moves `amount` of `token` from `from` to `to`; `from` must lose, and `to` gain, exactly that much.
    function _pullExact(address token, address from, address to, uint256 amount) private {
        uint256 fromBefore = IERC20Like(token).balanceOf(from);
        uint256 toBefore = IERC20Like(token).balanceOf(to);
        _safeTransferFrom(token, from, to, amount);
        uint256 fromAfter = IERC20Like(token).balanceOf(from);
        require(
            fromBefore >= fromAfter && fromBefore - fromAfter == amount
                && IERC20Like(token).balanceOf(to) - toBefore == amount,
            "token took a transfer fee or rebased - unsupported"
        );
    }

    /// Pays the maker, the taker or the fee recipient of the offer being filled; never a caller-chosen address.
    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        // slither-disable-next-line arbitrary-send-eth
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "BDAG transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token transferFrom failed");
    }
}
