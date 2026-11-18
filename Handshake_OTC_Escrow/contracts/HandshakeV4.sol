// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * Handshake OTC v4: peer-to-peer BDAG <-> ERC-20 trades on BlockDAG (chain 1404) that never hold funds.
 * ----------------------------------------------------------------------------------------------------
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

contract HandshakeV4 {
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
    address public feeRecipient;
    uint16 public feeBps = 25;
    uint16 public constant MAX_FEE_BPS = 300;
    bool public paused;
    uint256 private _locked = 1;

    /// Per-offer cap per asset (address(0) = BDAG). 0 = no cap.
    mapping(address => uint256) public maxOfferAmount;

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
        uint64 expiresAt
    );
    event OfferFilled(uint256 indexed id, address indexed taker, uint256 feePaid);
    event OfferCancelled(uint256 indexed id);
    event FeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event PausedSet(bool isPaused);
    event MaxOfferAmountUpdated(address indexed token, uint256 oldCap, uint256 newCap);
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
        require(_feeRecipient != address(0), "bad fee recipient");
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
     */
    function createOffer(
        address token,
        uint256 amountToken,
        uint256 amountNative,
        bool makerGivesNative,
        address taker,
        uint64 expiresAt
    ) external nonReentrant returns (uint256 id) {
        require(!paused, "paused");
        require(token != address(0) && token.code.length > 0, "token has no code");
        require(token != WBDAG, "use BDAG, not WBDAG, as the token");
        require(amountToken > 0 && amountNative > 0, "zero amount");
        require(expiresAt == 0 || expiresAt > block.timestamp, "already expired");
        require(taker != msg.sender, "can't trade with yourself");
        _enforceCap(address(0), amountNative);
        _enforceCap(token, amountToken);

        // The maker's side must be there and approved right now (it can still move later; fill re-checks).
        (address giveAsset, uint256 giveAmount) = makerGivesNative ? (WBDAG, amountNative) : (token, amountToken);
        require(IERC20Like(giveAsset).balanceOf(msg.sender) >= giveAmount, "maker balance too low");
        require(IERC20Like(giveAsset).allowance(msg.sender, address(this)) >= giveAmount, "approve first");

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
        emit OfferCreated(id, msg.sender, taker, token, amountNative, amountToken, makerGivesNative, expiresAt);
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
        require(newRecipient != address(0), "bad recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// Cap per new offer for `token` (address(0) = BDAG). 0 = no cap. Doesn't affect open offers.
    function setMaxOfferAmount(address token, uint256 newCap) external onlyOwner {
        emit MaxOfferAmountUpdated(token, maxOfferAmount[token], newCap);
        maxOfferAmount[token] = newCap;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "bad owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _enforceCap(address asset, uint256 amount) private view {
        uint256 cap = maxOfferAmount[asset];
        require(cap == 0 || amount <= cap, "exceeds per-offer cap");
    }

    /// Moves `amount` of `token` from `from` to `to` and requires `to` to receive exactly that much.
    function _pullExact(address token, address from, address to, uint256 amount) private {
        uint256 before = IERC20Like(token).balanceOf(to);
        _safeTransferFrom(token, from, to, amount);
        require(IERC20Like(token).balanceOf(to) - before == amount, "token took a transfer fee or rebased - unsupported");
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
