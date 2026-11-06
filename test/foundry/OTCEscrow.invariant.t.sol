// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {OTCEscrow} from "../../Handshake_OTC_Escrow/contracts/OTCEscrow_v3.sol";
import {HsToken, HsRejecter} from "./HandshakeTestTokens.sol";

/// Stateful fuzzing for the Handshake OTC escrow (OTCEscrow_v3, the deployed version).
/// A handler drives random sequences of create / fill / cancel / admin calls from several
/// makers and takers, including a wallet contract that refuses BDAG and tokens that block
/// transfers, charge a transfer tax or return nothing. Ghost state tracks what the escrow
/// should hold. Invariants checked after every sequence:
///  I1  native solvency: the escrow's BDAG balance == BDAG locked by open offers
///  I2  token solvency:  the escrow's balance of each token == tokens locked by open offers
///  I3  one-way status:  every offer's status matches the handler's record; Filled and
///      Cancelled offers never reopen or change
///  I4  fees: the fee recipient got exactly sum(amountNative * feeBpsAtCreation / 10_000)
///      over filled offers, never the live fee, and never more
///  I5  fee snapshot: each offer keeps the fee that applied when it was created
///  I6  ids: nextOfferId == offers created + 1
contract OTCEscrowHandler is Test {
    OTCEscrow public otc;
    HsToken[] public tokens;
    address[] public actors;
    HsRejecter public rejecter;
    address public constant FEE = address(0xFEE);

    // Ghost state.
    uint256 public lockedNative;
    mapping(address => uint256) public lockedTok;
    uint256 public feesExpected;
    uint256 public created;
    mapping(uint256 => OTCEscrow.Status) public ghostStatus;
    mapping(uint256 => uint16) public ghostFeeBps;
    mapping(bytes32 => uint256) public calls;
    bool public closedOfferActedOn; // set if a Filled/Cancelled offer could be filled or cancelled again

    constructor(OTCEscrow _otc) {
        otc = _otc;
        tokens.push(new HsToken("Plain", "PLN"));
        tokens.push(new HsToken("No-return", "NRT"));
        tokens[1].setReturnsNothing(true);
        tokens.push(new HsToken("Taxable", "TAX"));
        rejecter = new HsRejecter();
        for (uint160 i = 1; i <= 4; i++) actors.push(address(0xA000 + i));
        actors.push(address(rejecter));
        for (uint256 a = 0; a < actors.length; a++) {
            vm.deal(actors[a], 1e30);
            for (uint256 t = 0; t < tokens.length; t++) {
                tokens[t].mint(actors[a], 1e30);
                _as(actors[a], address(tokens[t]), 0, abi.encodeWithSignature("approve(address,uint256)", address(otc), type(uint256).max));
            }
        }
    }

    // ---- helpers ----
    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }
    function _token(uint256 s) internal view returns (HsToken) { return tokens[s % tokens.length]; }

    /// Calls `to` as `who`. The rejecter wallet goes through its own exec() so the call
    /// really comes from a contract that may refuse BDAG.
    function _as(address who, address to, uint256 value, bytes memory data) internal returns (bool ok, bytes memory ret) {
        if (who == address(rejecter)) {
            vm.deal(address(this), value);
            (ok, ret) = address(rejecter).call{value: value}(abi.encodeWithSignature("exec(address,uint256,bytes)", to, value, data));
            if (ok) ret = abi.decode(ret, (bytes));
        } else {
            vm.prank(who);
            (ok, ret) = to.call{value: value}(data);
        }
    }

    function _offer(uint256 id) internal view returns (address maker, address taker, address token, uint256 amtN, uint256 amtT, bool givesNative, OTCEscrow.Status st, uint16 bps) {
        (maker, taker, token, amtN, amtT, givesNative, st, , bps) = otc.getOffer(id);
    }

    function _pickOpen(uint256 seed) internal view returns (uint256 id, bool found) {
        uint256 n = otc.nextOfferId();
        if (n <= 1) return (0, false);
        id = bound(seed, 1, n - 1);
        (, , , , , , OTCEscrow.Status st, ) = _offer(id);
        found = st == OTCEscrow.Status.Open;
    }

    // ---- actions ----
    function createGivingNative(uint256 s, uint256 tokSeed, uint256 amtN, uint256 amtT, uint256 takerSeed) external {
        address m = _actor(s);
        amtN = bound(amtN, 1, 1e24);
        amtT = bound(amtT, 1, 1e24);
        address taker = takerSeed % 3 == 0 ? address(0) : _actor(takerSeed);
        uint16 bps = otc.feeBps();
        (bool ok, bytes memory ret) = _as(m, address(otc), amtN, abi.encodeWithSignature("createOfferGivingNative(address,uint256,address)", address(_token(tokSeed)), amtT, taker));
        if (!ok) return;
        uint256 id = abi.decode(ret, (uint256));
        lockedNative += amtN; created++; ghostStatus[id] = OTCEscrow.Status.Open; ghostFeeBps[id] = bps; calls["createNative"]++;
    }

    function createGivingToken(uint256 s, uint256 tokSeed, uint256 amtN, uint256 amtT, uint256 takerSeed) external {
        address m = _actor(s);
        HsToken t = _token(tokSeed);
        amtN = bound(amtN, 1, 1e24);
        amtT = bound(amtT, 1, 1e24);
        address taker = takerSeed % 3 == 0 ? address(0) : _actor(takerSeed);
        uint16 bps = otc.feeBps();
        (bool ok, bytes memory ret) = _as(m, address(otc), 0, abi.encodeWithSignature("createOfferGivingToken(address,uint256,uint256,address)", address(t), amtT, amtN, taker));
        if (!ok) return;
        uint256 id = abi.decode(ret, (uint256));
        lockedTok[address(t)] += amtT; created++; ghostStatus[id] = OTCEscrow.Status.Open; ghostFeeBps[id] = bps; calls["createToken"]++;
    }

    function fill(uint256 s, uint256 idSeed) external {
        (uint256 id, bool found) = _pickOpen(idSeed);
        if (!found) return;
        (, address taker, address token, uint256 amtN, uint256 amtT, bool givesNative, , uint16 bps) = _offer(id);
        address t = taker != address(0) && s % 4 != 0 ? taker : _actor(s); // mostly the allowed taker, sometimes anyone
        bool ok;
        if (givesNative) (ok, ) = _as(t, address(otc), 0, abi.encodeWithSignature("fillOfferGivingToken(uint256)", id));
        else (ok, ) = _as(t, address(otc), amtN, abi.encodeWithSignature("fillOfferGivingNative(uint256)", id));
        if (!ok) return;
        if (givesNative) lockedNative -= amtN; else lockedTok[token] -= amtT;
        feesExpected += (amtN * bps) / 10_000;
        ghostStatus[id] = OTCEscrow.Status.Filled; calls["fill"]++;
    }

    function cancel(uint256 s, uint256 idSeed) external {
        (uint256 id, bool found) = _pickOpen(idSeed);
        if (!found) return;
        (address maker, , address token, uint256 amtN, uint256 amtT, bool givesNative, , ) = _offer(id);
        address who = s % 5 == 0 ? _actor(s) : maker; // sometimes a stranger tries
        (bool ok, ) = _as(who, address(otc), 0, abi.encodeWithSignature("cancelOffer(uint256)", id));
        if (!ok) return;
        if (givesNative) lockedNative -= amtN; else lockedTok[token] -= amtT;
        ghostStatus[id] = OTCEscrow.Status.Cancelled; calls["cancel"]++;
    }

    /// Tries to fill or cancel an offer that is already closed; it must fail.
    function poke(uint256 s, uint256 idSeed, bool tryFill) external {
        uint256 n = otc.nextOfferId();
        if (n <= 1) return;
        uint256 id = bound(idSeed, 1, n - 1);
        (, , , uint256 amtN, , bool givesNative, OTCEscrow.Status st, ) = _offer(id);
        if (st == OTCEscrow.Status.Open) return;
        bool ok;
        if (!tryFill) (ok, ) = _as(_actor(s), address(otc), 0, abi.encodeWithSignature("cancelOffer(uint256)", id));
        else if (givesNative) (ok, ) = _as(_actor(s), address(otc), 0, abi.encodeWithSignature("fillOfferGivingToken(uint256)", id));
        else (ok, ) = _as(_actor(s), address(otc), amtN, abi.encodeWithSignature("fillOfferGivingNative(uint256)", id));
        if (ok) closedOfferActedOn = true;
        calls["poke"]++;
    }

    // ---- environment changes ----
    function setFee(uint256 bps) external { vm.prank(otc.owner()); try otc.setFeeBps(uint16(bound(bps, 0, 400))) { calls["setFee"]++; } catch {} }
    function setPaused(uint256 seed) external { vm.prank(otc.owner()); otc.setPaused(seed % 5 == 0); } // paused about 1 time in 5
    function setCap(uint256 tokSeed, uint256 cap, bool native) external {
        vm.prank(otc.owner());
        otc.setMaxOfferAmount(native ? address(0) : address(_token(tokSeed)), cap % 2 == 0 ? 0 : bound(cap, 1, 1e24));
    }
    function setTokenTax(uint256 bps) external { tokens[2].setFee(bound(bps, 0, 500)); }
    function setBlocked(uint256 s, uint256 tokSeed, bool on) external { _token(tokSeed).setBlocked(_actor(s), on); }
    function setRejecterAccepts(bool on) external { rejecter.setAccept(on); }
    function warp(uint256 secs) external { vm.warp(block.timestamp + bound(secs, 0, 7 days)); }

    function tokenCount() external view returns (uint256) { return tokens.length; }
    receive() external payable {}
}

contract OTCEscrowInvariantTest is Test {
    OTCEscrow internal otc;
    OTCEscrowHandler internal handler;

    function setUp() public {
        otc = new OTCEscrow(address(0xFEE));
        handler = new OTCEscrowHandler(otc);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](13);
        sels[0] = OTCEscrowHandler.createGivingNative.selector;
        sels[1] = OTCEscrowHandler.createGivingToken.selector;
        sels[2] = OTCEscrowHandler.fill.selector;
        sels[3] = OTCEscrowHandler.cancel.selector;
        sels[4] = OTCEscrowHandler.poke.selector;
        sels[5] = OTCEscrowHandler.setFee.selector;
        sels[6] = OTCEscrowHandler.setPaused.selector;
        sels[7] = OTCEscrowHandler.setCap.selector;
        sels[8] = OTCEscrowHandler.setTokenTax.selector;
        sels[9] = OTCEscrowHandler.setBlocked.selector;
        sels[10] = OTCEscrowHandler.setRejecterAccepts.selector;
        sels[11] = OTCEscrowHandler.warp.selector;
        sels[12] = OTCEscrowHandler.createGivingNative.selector; // weight creates a little higher
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// I1
    function invariant_nativeSolvency() public view {
        assertEq(address(otc).balance, handler.lockedNative(), "escrow BDAG != BDAG locked by open offers");
    }

    /// I2
    function invariant_tokenSolvency() public view {
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            address t = address(handler.tokens(i));
            assertEq(HsToken(t).balanceOf(address(otc)), handler.lockedTok(t), "escrow tokens != tokens locked by open offers");
        }
    }

    /// I3 (closed offers stay closed)
    function invariant_closedStaysClosed() public view {
        assertFalse(handler.closedOfferActedOn(), "a filled or cancelled offer was filled or cancelled again");
    }

    /// I3 + I5
    function invariant_statusAndFeeSnapshot() public view {
        uint256 n = otc.nextOfferId();
        for (uint256 id = 1; id < n; id++) {
            (, , , , , , OTCEscrow.Status st, , uint16 bps) = otc.getOffer(id);
            assertEq(uint8(st), uint8(handler.ghostStatus(id)), "offer status changed outside the handler's record");
            assertEq(bps, handler.ghostFeeBps(id), "offer fee snapshot changed");
        }
    }

    /// I4
    function invariant_feesExact() public view {
        assertEq(address(0xFEE).balance, handler.feesExpected(), "fee recipient paid a different amount than the offers' snapshot fees");
    }

    /// I6
    function invariant_ids() public view {
        assertEq(otc.nextOfferId(), handler.created() + 1, "offer ids skipped or repeated");
        assertEq(otc.totalOffers(), handler.created(), "totalOffers mismatch");
    }

    /// Run log (not an assertion): how many real actions landed in this run. Shown with -vv.
    function afterInvariant() external view {
        console.log("created %s, filled %s, cancelled %s", handler.created(), handler.calls("fill"), handler.calls("cancel"));
        console.log("closed-offer retries refused %s, fee changes %s", handler.calls("poke"), handler.calls("setFee"));
    }
}

/// Stateless fuzz tests for single properties.
contract OTCEscrowFuzzTest is Test {
    OTCEscrow internal otc;
    HsToken internal tok;
    address internal maker = address(0xA1);
    address internal taker = address(0xB2);

    function setUp() public {
        otc = new OTCEscrow(address(0xFEE));
        tok = new HsToken("Plain", "PLN");
        tok.mint(maker, 1e30); tok.mint(taker, 1e30);
        vm.deal(maker, 1e30); vm.deal(taker, 1e30);
        vm.prank(maker); tok.approve(address(otc), type(uint256).max);
        vm.prank(taker); tok.approve(address(otc), type(uint256).max);
    }

    /// Filling a token-for-BDAG offer: maker gets amountNative minus fee, fee recipient the fee, taker the tokens.
    function testFuzz_fillSplitsExactly(uint256 amtN, uint256 amtT, uint16 bps) public {
        amtN = bound(amtN, 1, 1e27); amtT = bound(amtT, 1, 1e27); bps = uint16(bound(bps, 0, 300));
        otc.setFeeBps(bps);
        vm.prank(maker);
        uint256 id = otc.createOfferGivingToken(address(tok), amtT, amtN, address(0));
        uint256 m0 = maker.balance; uint256 f0 = address(0xFEE).balance; uint256 t0 = tok.balanceOf(taker);
        vm.prank(taker);
        otc.fillOfferGivingNative{value: amtN}(id);
        uint256 fee = (amtN * bps) / 10_000;
        assertEq(address(0xFEE).balance - f0, fee);
        assertEq(maker.balance - m0, amtN - fee);
        assertEq(tok.balanceOf(taker) - t0, amtT);
        assertEq(address(otc).balance, 0);
        assertEq(tok.balanceOf(address(otc)), 0);
    }

    /// The owner changing the fee after an offer is created never changes that offer's fee.
    function testFuzz_feeChangeDoesNotTouchOpenOffer(uint256 amtN, uint16 before_, uint16 after_) public {
        amtN = bound(amtN, 1, 1e27); before_ = uint16(bound(before_, 0, 300)); after_ = uint16(bound(after_, 0, 300));
        otc.setFeeBps(before_);
        vm.prank(maker);
        uint256 id = otc.createOfferGivingNative{value: amtN}(address(tok), 1e18, address(0));
        otc.setFeeBps(after_);
        uint256 f0 = address(0xFEE).balance;
        vm.prank(taker);
        otc.fillOfferGivingToken(id);
        assertEq(address(0xFEE).balance - f0, (amtN * before_) / 10_000);
    }

    /// Cancelling refunds exactly what was locked, and only the maker can cancel.
    function testFuzz_cancelRefundsExactly(uint256 amt, bool native, address stranger) public {
        vm.assume(stranger != maker);
        amt = bound(amt, 1, 1e27);
        vm.startPrank(maker);
        uint256 id = native
            ? otc.createOfferGivingNative{value: amt}(address(tok), 1e18, address(0))
            : otc.createOfferGivingToken(address(tok), amt, 1e18, address(0));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(bytes("not your offer"));
        otc.cancelOffer(id);
        uint256 nb = maker.balance; uint256 tb = tok.balanceOf(maker);
        vm.prank(maker);
        otc.cancelOffer(id);
        if (native) assertEq(maker.balance - nb, amt); else assertEq(tok.balanceOf(maker) - tb, amt);
        assertEq(address(otc).balance, 0);
        assertEq(tok.balanceOf(address(otc)), 0);
    }

    /// The per-offer cap: amounts above it are refused, at or below are accepted, 0 = no cap.
    function testFuzz_capEnforced(uint256 cap, uint256 amt) public {
        cap = bound(cap, 1, 1e27); amt = bound(amt, 1, 2e27);
        otc.setMaxOfferAmount(address(0), cap);
        vm.prank(maker);
        if (amt > cap) {
            vm.expectRevert(bytes("exceeds per-offer cap"));
            otc.createOfferGivingNative{value: amt}(address(tok), 1, address(0));
        } else {
            otc.createOfferGivingNative{value: amt}(address(tok), 1, address(0));
        }
    }

    /// A token that takes a transfer tax is refused at creation, so nothing can get stuck.
    function testFuzz_taxedTokenRefused(uint256 bps, uint256 amt) public {
        bps = bound(bps, 1, 5_000); amt = bound(amt, 10_000, 1e27);
        tok.setFee(bps);
        vm.prank(maker);
        vm.expectRevert(bytes("token took a transfer fee or rebased - unsupported"));
        otc.createOfferGivingToken(address(tok), amt, 1e18, address(0));
    }

    /// A private offer can only be filled by its named taker.
    function testFuzz_privateOfferOnlyTaker(address other) public {
        vm.assume(other != taker && other != address(0) && other.code.length == 0);
        vm.deal(other, 1e30); tok.mint(other, 1e30);
        vm.prank(other); tok.approve(address(otc), type(uint256).max);
        vm.prank(maker);
        uint256 id = otc.createOfferGivingNative{value: 1e18}(address(tok), 1e18, taker);
        vm.prank(other);
        vm.expectRevert(bytes("not your offer to fill"));
        otc.fillOfferGivingToken(id);
    }
}
