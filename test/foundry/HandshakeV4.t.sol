// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HandshakeV4} from "../../Handshake_OTC_Escrow/contracts/HandshakeV4.sol";
import {HsToken, HsRejecter} from "./HandshakeTestTokens.sol";

/// Same behaviour as Reef's WBDAG (WETH9-style; withdraw pays out with a plain call).
contract TestWBDAG {
    string public name = "Wrapped BDAG";
    string public symbol = "WBDAG";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function deposit() public payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        (bool ok, ) = msg.sender.call{value: a}("");
        require(ok, "send");
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address t, uint256 a) external returns (bool) { return transferFrom(msg.sender, t, a); }
    function transferFrom(address f, address t, uint256 a) public returns (bool) {
        require(balanceOf[f] >= a, "bal");
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) {
            require(allowance[f][msg.sender] >= a, "allow");
            allowance[f][msg.sender] -= a;
        }
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
    receive() external payable { deposit(); }
}

/// A token that tries to call back into Handshake while being moved.
contract ReenterToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    HandshakeV4 public hs;
    uint256 public targetId;
    bool public armed;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function arm(HandshakeV4 h, uint256 id) external { hs = h; targetId = id; armed = true; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (armed) { armed = false; hs.fill(targetId); }
        return true;
    }
}

contract HandshakeV4Base is Test {
    HandshakeV4 hs;
    TestWBDAG wbdag;
    HsToken tok;
    address owner = address(this);
    address feeTo = makeAddr("fee");
    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    function setUp() public virtual {
        wbdag = new TestWBDAG();
        hs = new HandshakeV4(address(wbdag), feeTo);
        tok = new HsToken("Test", "TST");
        tok.mint(maker, 1_000_000e18);
        tok.mint(taker, 1_000_000e18);
        vm.deal(maker, 1_000_000 ether);
        vm.deal(taker, 1_000_000 ether);
        vm.prank(maker);
        wbdag.deposit{value: 500_000 ether}();
    }

    function _approve(address who, address asset, uint256 amt) internal {
        vm.prank(who);
        HsToken(asset).approve(address(hs), amt);
    }

    function _offerTokenForBdag(uint256 amtTok, uint256 amtBdag) internal returns (uint256 id) {
        _approve(maker, address(tok), amtTok);
        vm.prank(maker);
        id = hs.createOffer(address(tok), amtTok, amtBdag, false, address(0), 0);
    }

    function _offerBdagForToken(uint256 amtBdag, uint256 amtTok) internal returns (uint256 id) {
        _approve(maker, address(wbdag), amtBdag);
        vm.prank(maker);
        id = hs.createOffer(address(tok), amtTok, amtBdag, true, address(0), 0);
    }

    function _assertHoldsNothing() internal view {
        assertEq(address(hs).balance, 0, "holds BDAG");
        assertEq(wbdag.balanceOf(address(hs)), 0, "holds WBDAG");
        assertEq(tok.balanceOf(address(hs)), 0, "holds token");
    }
}

contract HandshakeV4Test is HandshakeV4Base {
    // ----- the two trade directions -----

    function test_makerSellsToken_fundsMoveWalletToWallet() public {
        uint256 id = _offerTokenForBdag(1_000e18, 400 ether);
        _assertHoldsNothing(); // creating deposited nothing
        assertEq(tok.balanceOf(maker), 1_000_000e18);

        uint256 mBdag = maker.balance;
        uint256 tTok = tok.balanceOf(taker);
        vm.prank(taker);
        hs.fill{value: 400 ether}(id);

        assertEq(maker.balance - mBdag, 399 ether); // 400 minus 0.25%
        assertEq(feeTo.balance, 1 ether);
        assertEq(tok.balanceOf(taker) - tTok, 1_000e18);
        assertEq(tok.balanceOf(maker), 1_000_000e18 - 1_000e18);
        _assertHoldsNothing();
    }

    function test_makerSellsBdag_viaWbdag_takerGetsRealBdag() public {
        uint256 id = _offerBdagForToken(200 ether, 5_000e18);
        _assertHoldsNothing();

        _approve(taker, address(tok), 5_000e18);
        uint256 tBdag = taker.balance;
        uint256 mW = wbdag.balanceOf(maker);
        uint256 mTok = tok.balanceOf(maker);
        vm.prank(taker);
        hs.fill(id);

        assertEq(taker.balance - tBdag, 199.5 ether); // real BDAG, minus 0.25%
        assertEq(feeTo.balance, 0.5 ether);
        assertEq(mW - wbdag.balanceOf(maker), 200 ether);
        assertEq(tok.balanceOf(maker) - mTok, 5_000e18);
        _assertHoldsNothing();
    }

    // ----- creating -----

    function test_create_needsApprovalAndBalance() public {
        vm.prank(maker);
        vm.expectRevert("approve first");
        hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0);

        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert("maker balance too low");
        hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0);

        vm.prank(maker);
        vm.expectRevert("approve first");
        hs.createOffer(address(tok), 1e18, 1 ether, true, address(0), 0); // WBDAG not approved
    }

    function test_create_rejectsBadInputs() public {
        _approve(maker, address(tok), type(uint256).max);
        vm.startPrank(maker);
        vm.expectRevert("token has no code");
        hs.createOffer(makeAddr("eoa"), 1, 1, false, address(0), 0);
        vm.expectRevert("use BDAG, not WBDAG, as the token");
        hs.createOffer(address(wbdag), 1, 1, false, address(0), 0);
        vm.expectRevert("zero amount");
        hs.createOffer(address(tok), 0, 1, false, address(0), 0);
        vm.expectRevert("zero amount");
        hs.createOffer(address(tok), 1, 0, false, address(0), 0);
        vm.expectRevert("already expired");
        hs.createOffer(address(tok), 1, 1, false, address(0), uint64(block.timestamp));
        vm.expectRevert("can't trade with yourself");
        hs.createOffer(address(tok), 1, 1, false, maker, 0);
        vm.stopPrank();
    }

    // ----- filling -----

    function test_fill_failsCleanlyIfMakerMovedTheirFunds() public {
        uint256 id = _offerTokenForBdag(1_000e18, 400 ether);
        vm.startPrank(maker);
        tok.transfer(makeAddr("elsewhere"), tok.balanceOf(maker));
        vm.stopPrank();
        assertFalse(hs.offerReady(id));

        uint256 tBdag = taker.balance;
        vm.prank(taker);
        vm.expectRevert();
        hs.fill{value: 400 ether}(id);
        assertEq(taker.balance, tBdag); // taker's BDAG never left
        _assertHoldsNothing();
        (, , , , , , HandshakeV4.Status st, , , ) = hs.offers(id);
        assertEq(uint8(st), uint8(HandshakeV4.Status.Open)); // the failed fill changed nothing
    }

    function test_fill_failsIfMakerRevokedApproval() public {
        uint256 id = _offerBdagForToken(10 ether, 10e18);
        _approve(maker, address(wbdag), 0);
        assertFalse(hs.offerReady(id));
        _approve(taker, address(tok), 10e18);
        uint256 tTok = tok.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert();
        hs.fill(id);
        assertEq(tok.balanceOf(taker), tTok);
    }

    function test_fill_wrongValue() public {
        uint256 id = _offerTokenForBdag(1e18, 1 ether);
        vm.prank(taker);
        vm.expectRevert("wrong BDAG amount");
        hs.fill{value: 0.5 ether}(id);

        uint256 id2 = _offerBdagForToken(1 ether, 1e18);
        _approve(taker, address(tok), 1e18);
        vm.prank(taker);
        vm.expectRevert("no BDAG needed for this offer");
        hs.fill{value: 1 ether}(id2);
    }

    function test_fill_privateTakerOnly() public {
        _approve(maker, address(tok), 1e18);
        vm.prank(maker);
        uint256 id = hs.createOffer(address(tok), 1e18, 1 ether, false, taker, 0);
        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        vm.expectRevert("not your offer to fill");
        hs.fill{value: 1 ether}(id);
        vm.prank(taker);
        hs.fill{value: 1 ether}(id);
    }

    function test_fill_onlyOnce_andNotByMaker() public {
        uint256 id = _offerTokenForBdag(2e18, 2 ether);
        vm.prank(maker);
        vm.expectRevert("can't fill your own offer");
        hs.fill{value: 2 ether}(id);
        vm.prank(taker);
        hs.fill{value: 1 ether * 2}(id);
        vm.prank(taker);
        vm.expectRevert("not open");
        hs.fill{value: 2 ether}(id);
    }

    function test_fill_expiry() public {
        _approve(maker, address(tok), 1e18);
        vm.prank(maker);
        uint256 id = hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(hs.offerReady(id));
        vm.prank(taker);
        vm.expectRevert("expired");
        hs.fill{value: 1 ether}(id);
    }

    function test_fill_refusesFeeOnTransferTokens_bothWays() public {
        uint256 id = _offerTokenForBdag(100e18, 1 ether);
        tok.setFee(100); // 1% transfer fee switched on after the offer was made
        vm.prank(taker);
        vm.expectRevert("token took a transfer fee or rebased - unsupported");
        hs.fill{value: 1 ether}(id);

        uint256 id2 = _offerBdagForToken(1 ether, 100e18);
        _approve(taker, address(tok), 100e18);
        vm.prank(taker);
        vm.expectRevert("token took a transfer fee or rebased - unsupported");
        hs.fill(id2);
        _assertHoldsNothing();
    }

    function test_fill_feeFixedAtCreation() public {
        uint256 id = _offerTokenForBdag(1e18, 100 ether); // made at 0.25%
        hs.setFeeBps(300);
        uint256 mBdag = maker.balance;
        vm.prank(taker);
        hs.fill{value: 100 ether}(id);
        assertEq(maker.balance - mBdag, 99.75 ether);
        assertEq(feeTo.balance, 0.25 ether);
    }

    function test_fill_zeroFee() public {
        hs.setFeeBps(0);
        uint256 id = _offerBdagForToken(3 ether, 3e18);
        _approve(taker, address(tok), 3e18);
        uint256 tBdag = taker.balance;
        vm.prank(taker);
        hs.fill(id);
        assertEq(taker.balance - tBdag, 3 ether);
        assertEq(feeTo.balance, 0);
        _assertHoldsNothing();
    }

    function test_fill_makerContractRefusingBdag_failsWithNothingMoved() public {
        HsRejecter rej = new HsRejecter();
        tok.mint(address(rej), 10e18);
        rej.exec(address(tok), 0, abi.encodeWithSignature("approve(address,uint256)", address(hs), 10e18));
        bytes memory r = rej.exec(address(hs), 0, abi.encodeWithSelector(HandshakeV4.createOffer.selector, address(tok), 10e18, 1 ether, false, address(0), uint64(0)));
        uint256 id = abi.decode(r, (uint256));
        vm.prank(taker);
        vm.expectRevert("BDAG transfer failed");
        hs.fill{value: 1 ether}(id);
        assertEq(tok.balanceOf(address(rej)), 10e18);
        _assertHoldsNothing();
    }

    function test_fill_reentrancyBlocked() public {
        ReenterToken rt = new ReenterToken();
        rt.mint(taker, 10e18);
        _approve(maker, address(wbdag), 2 ether);
        vm.startPrank(maker);
        uint256 id1 = hs.createOffer(address(rt), 1e18, 1 ether, true, address(0), 0);
        uint256 id2 = hs.createOffer(address(rt), 1e18, 1 ether, true, address(0), 0);
        vm.stopPrank();
        vm.prank(taker);
        rt.approve(address(hs), 10e18);
        rt.arm(hs, id2);
        // The token's callback into fill() hits the guard; the whole fill reverts and nothing moves.
        uint256 mW = wbdag.balanceOf(maker);
        vm.prank(taker);
        vm.expectRevert("token transferFrom failed");
        hs.fill(id1);
        assertEq(wbdag.balanceOf(maker), mW);
        assertEq(rt.balanceOf(taker), 10e18);
        assertTrue(hs.offerReady(id1) && hs.offerReady(id2));
        _assertHoldsNothing();
    }

    // ----- cancelling, pausing, admin -----

    function test_cancel_onlyMaker_andStopsFills() public {
        uint256 id = _offerTokenForBdag(1e18, 1 ether);
        vm.prank(taker);
        vm.expectRevert("not your offer");
        hs.cancelOffer(id);
        vm.prank(maker);
        hs.cancelOffer(id);
        vm.prank(taker);
        vm.expectRevert("not open");
        hs.fill{value: 1 ether}(id);
    }

    function test_pause_blocksCreateAndFill_butCancelWorks() public {
        uint256 id = _offerTokenForBdag(1e18, 1 ether);
        hs.setPaused(true);
        assertFalse(hs.offerReady(id));
        _approve(maker, address(tok), 2e18);
        vm.prank(maker);
        vm.expectRevert("paused");
        hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0);
        vm.prank(taker);
        vm.expectRevert("paused");
        hs.fill{value: 1 ether}(id);
        vm.prank(maker);
        hs.cancelOffer(id);
    }

    function test_caps() public {
        hs.setMaxOfferAmount(address(0), 10 ether);
        hs.setMaxOfferAmount(address(tok), 100e18);
        _approve(maker, address(tok), type(uint256).max);
        vm.startPrank(maker);
        vm.expectRevert("exceeds per-offer cap");
        hs.createOffer(address(tok), 1e18, 11 ether, false, address(0), 0);
        vm.expectRevert("exceeds per-offer cap");
        hs.createOffer(address(tok), 101e18, 1 ether, false, address(0), 0);
        hs.createOffer(address(tok), 100e18, 10 ether, false, address(0), 0);
        vm.stopPrank();
    }

    function test_admin_onlyOwner_andLimits() public {
        vm.startPrank(taker);
        vm.expectRevert("not owner");
        hs.setFeeBps(10);
        vm.expectRevert("not owner");
        hs.setPaused(true);
        vm.expectRevert("not owner");
        hs.setFeeRecipient(taker);
        vm.expectRevert("not owner");
        hs.setMaxOfferAmount(address(0), 1);
        vm.expectRevert("not owner");
        hs.transferOwnership(taker);
        vm.stopPrank();
        vm.expectRevert("fee too high");
        hs.setFeeBps(301);
        hs.transferOwnership(taker);
        assertEq(hs.owner(), taker);
    }

    function test_directBdagRefused() public {
        vm.prank(taker);
        (bool ok, ) = address(hs).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ----- fuzz: both directions, any amounts and fee -----

    function testFuzz_fill_conservesValue_andHoldsNothing(uint96 amtBdag, uint96 amtTok, uint16 fee, bool makerGivesNative) public {
        amtBdag = uint96(bound(amtBdag, 1, 400_000 ether));
        amtTok = uint96(bound(amtTok, 1, 900_000e18));
        fee = uint16(bound(fee, 0, 300));
        hs.setFeeBps(fee);
        uint256 id = makerGivesNative ? _offerBdagForToken(amtBdag, amtTok) : _offerTokenForBdag(amtTok, amtBdag);
        if (makerGivesNative) _approve(taker, address(tok), amtTok);

        uint256 before = maker.balance + taker.balance + feeTo.balance + wbdag.balanceOf(maker);
        uint256 tokBefore = tok.balanceOf(maker) + tok.balanceOf(taker);
        vm.prank(taker);
        hs.fill{value: makerGivesNative ? 0 : amtBdag}(id);

        assertEq(maker.balance + taker.balance + feeTo.balance + wbdag.balanceOf(maker), before);
        assertEq(tok.balanceOf(maker) + tok.balanceOf(taker), tokBefore);
        assertEq(feeTo.balance, (uint256(amtBdag) * fee) / 10_000);
        _assertHoldsNothing();
    }
}

/// Random sequences of create / fill / cancel / makers moving funds away. The contract must never be left
/// holding BDAG, WBDAG or tokens, whatever happens.
contract V4Handler is Test {
    HandshakeV4 hs;
    TestWBDAG wbdag;
    HsToken tok;
    address[3] actors;
    uint256 public fills;

    constructor(HandshakeV4 h, TestWBDAG w, HsToken t) {
        hs = h; wbdag = w; tok = t;
        for (uint256 i; i < 3; i++) {
            actors[i] = address(uint160(0xA000 + i));
            vm.deal(actors[i], 1_000_000 ether);
            tok.mint(actors[i], 1_000_000e18);
            vm.startPrank(actors[i]);
            wbdag.deposit{value: 300_000 ether}();
            wbdag.approve(address(hs), type(uint256).max);
            tok.approve(address(hs), type(uint256).max);
            vm.stopPrank();
        }
    }

    function create(uint256 a, uint96 amtB, uint96 amtT, bool giveNative) external {
        address m = actors[a % 3];
        amtB = uint96(bound(amtB, 1, 1_000 ether));
        amtT = uint96(bound(amtT, 1, 1_000e18));
        vm.prank(m);
        try hs.createOffer(address(tok), amtT, amtB, giveNative, address(0), 0) {} catch {}
    }

    function fill(uint256 a, uint256 id) external {
        uint256 n = hs.totalOffers();
        if (n == 0) return;
        id = bound(id, 1, n);
        address t = actors[a % 3];
        (, , , uint256 amtB, , bool giveNative, , , , ) = hs.offers(id);
        vm.prank(t);
        try hs.fill{value: giveNative ? 0 : amtB}(id) { fills++; } catch {}
    }

    function cancel(uint256 a, uint256 id) external {
        uint256 n = hs.totalOffers();
        if (n == 0) return;
        id = bound(id, 1, n);
        vm.prank(actors[a % 3]);
        try hs.cancelOffer(id) {} catch {}
    }

    function moveAway(uint256 a, uint96 amt) external {
        address m = actors[a % 3];
        vm.startPrank(m);
        uint256 bal = tok.balanceOf(m);
        tok.transfer(address(0xdead), bound(amt, 0, bal));
        vm.stopPrank();
    }
}

contract HandshakeV4InvariantTest is Test {
    HandshakeV4 hs;
    TestWBDAG wbdag;
    HsToken tok;
    V4Handler h;

    function setUp() public {
        wbdag = new TestWBDAG();
        hs = new HandshakeV4(address(wbdag), makeAddr("fee"));
        tok = new HsToken("Test", "TST");
        h = new V4Handler(hs, wbdag, tok);
        targetContract(address(h));
    }

    function afterInvariant() public view {
        assertGt(h.fills(), 0, "no fills happened, so the run proved little");
    }

    function invariant_neverHoldsFunds() public view {
        assertEq(address(hs).balance, 0);
        assertEq(wbdag.balanceOf(address(hs)), 0);
        assertEq(tok.balanceOf(address(hs)), 0);
    }
}
