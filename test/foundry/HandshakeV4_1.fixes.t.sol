// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HandshakeV4_1} from "../../Handshake_OTC_Escrow/contracts/HandshakeV4_1.sol";
import {HsToken} from "./HandshakeTestTokens.sol";
import {TestWBDAG} from "./HandshakeV4.t.sol";
import {HandshakeV41Base, V41Handler} from "./HandshakeV4_1.t.sol";

/// Delivers the full amount to the receiver but takes one extra unit from the sender (pre-audit F-01).
contract OverchargeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a + 1;
        balanceOf[t] += a;
        return true;
    }
}

/// Tests for the Chord v2.1 fixes ported to Handshake v4.1.
contract HandshakeV41FixesTest is HandshakeV41Base {
    address alice = makeAddr("alice");

    // ---- Olympix 5.1.1 / Proovant CHORD-01: a stale offer can't be revived by a new approval ----

    function test_5_1_1_staleTokenOfferNotRevived() public {
        tok.mint(alice, 100e18);
        vm.startPrank(alice);
        tok.approve(address(hs), 100e18);
        uint256 idA = hs.createOffer(address(tok), 100e18, 100 ether, false, address(0), 0, 300);
        tok.transfer(makeAddr("elsewhere"), 100e18); // A goes stale
        vm.stopPrank();
        assertFalse(hs.offerReady(idA));

        // Alice gets 100 back and approves exactly 100 for a new offer B at a higher price: refused, because
        // A still has 100 committed.
        tok.mint(alice, 100e18);
        vm.startPrank(alice);
        tok.approve(address(hs), 100e18);
        vm.expectRevert("maker balance too low for all your open offers");
        hs.createOffer(address(tok), 100e18, 200 ether, false, address(0), 0, 300);

        // She cancels A; B goes through and A can't be filled.
        hs.cancelOffer(idA);
        uint256 idB = hs.createOffer(address(tok), 100e18, 200 ether, false, address(0), 0, 300);
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert("not open");
        hs.fill{value: 100 ether}(idA);

        uint256 before = alice.balance;
        vm.prank(taker);
        hs.fill{value: 200 ether}(idB);
        assertEq(alice.balance - before, 200 ether - (200 ether * 25) / 10_000, "sold at B's price");
    }

    function test_5_1_1_staleBdagOfferNotRevived() public {
        // Maker gives BDAG (as WBDAG): same rule on the WBDAG side.
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        wbdag.deposit{value: 10 ether}();
        wbdag.approve(address(hs), 10 ether);
        hs.createOffer(address(tok), 1e18, 10 ether, true, address(0), 0, 300);
        vm.expectRevert("maker balance too low for all your open offers");
        hs.createOffer(address(tok), 2e18, 10 ether, true, address(0), 0, 300);
        vm.stopPrank();
        assertEq(hs.committed(alice, address(wbdag)), 10 ether);
    }

    function test_5_1_1_approvalMustCoverAllOpenOffers() public {
        tok.mint(alice, 200e18);
        vm.startPrank(alice);
        tok.approve(address(hs), 100e18);
        hs.createOffer(address(tok), 100e18, 1 ether, false, address(0), 0, 300);
        vm.expectRevert("approve enough for all your open offers");
        hs.createOffer(address(tok), 100e18, 2 ether, false, address(0), 0, 300);
        tok.approve(address(hs), 200e18); // backing both on purpose is fine
        hs.createOffer(address(tok), 100e18, 2 ether, false, address(0), 0, 300);
        vm.stopPrank();
        assertEq(hs.committed(alice, address(tok)), 200e18);
    }

    function test_committed_releasedOnFillAndCancel_perAsset() public {
        _approve(maker, address(tok), type(uint256).max);
        _approve(maker, address(wbdag), type(uint256).max);
        vm.startPrank(maker);
        uint256 a = hs.createOffer(address(tok), 10e18, 1 ether, false, address(0), 0, 300);
        uint256 b = hs.createOffer(address(tok), 10e18, 1 ether, false, address(0), 0, 300);
        uint256 c = hs.createOffer(address(tok), 5e18, 2 ether, true, address(0), 0, 300);
        vm.stopPrank();
        assertEq(hs.committed(maker, address(tok)), 20e18);
        assertEq(hs.committed(maker, address(wbdag)), 2 ether);

        vm.prank(taker);
        hs.fill{value: 1 ether}(a);
        assertEq(hs.committed(maker, address(tok)), 10e18, "fill releases");

        vm.prank(maker);
        hs.cancelOffer(b);
        assertEq(hs.committed(maker, address(tok)), 0, "cancel releases");

        _approve(taker, address(tok), 5e18);
        vm.prank(taker);
        hs.fill(c);
        assertEq(hs.committed(maker, address(wbdag)), 0, "WBDAG side released");
    }

    function test_committed_expiredOfferStaysUntilCancelled() public {
        tok.mint(alice, 100e18);
        vm.startPrank(alice);
        tok.approve(address(hs), 100e18);
        uint256 id = hs.createOffer(address(tok), 100e18, 1 ether, false, address(0), uint64(block.timestamp + 1 hours), 300);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert("maker balance too low for all your open offers");
        hs.createOffer(address(tok), 100e18, 2 ether, false, address(0), 0, 300);
        hs.cancelOffer(id); // expired offers can be cancelled to release them
        hs.createOffer(address(tok), 100e18, 2 ether, false, address(0), 0, 300);
        vm.stopPrank();
    }

    function testFuzz_committed_neverUnderflows(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 12));
        _approve(maker, address(tok), type(uint256).max);
        uint256[] memory ids = new uint256[](n);
        uint256 sum;
        for (uint256 i; i < n; i++) {
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1_000e18);
            vm.prank(maker);
            ids[i] = hs.createOffer(address(tok), amt, 1 ether, false, address(0), 0, 300);
            sum += amt;
        }
        assertEq(hs.committed(maker, address(tok)), sum);
        for (uint256 i; i < n; i++) {
            if (uint256(keccak256(abi.encode(seed, i, "x"))) % 2 == 0) { vm.prank(maker); hs.cancelOffer(ids[i]); }
            else { vm.prank(taker); hs.fill{value: 1 ether}(ids[i]); }
        }
        assertEq(hs.committed(maker, address(tok)), 0);
    }

    // ---- Olympix 5.2.1: the maker's maximum fee -------------------------------------------------

    function test_5_2_1_feeAboveMakerMaxReverts() public {
        hs.setFeeBps(300); // a fee change landing before the maker's create is mined
        _approve(maker, address(tok), 1e18);
        _approve(maker, address(wbdag), 1 ether);
        vm.startPrank(maker);
        vm.expectRevert("fee above your max");
        hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0, 25);
        vm.expectRevert("fee above your max");
        hs.createOffer(address(tok), 1e18, 1 ether, true, address(0), 0, 25);
        vm.stopPrank();

        hs.setFeeBps(25);
        vm.prank(maker);
        uint256 id = hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0, 25); // equal is fine
        assertEq(hs.getOffer(id).feeBpsAtCreation, 25);
    }

    function test_5_2_1_offerCreatedEmitsFee() public {
        hs.setFeeBps(40);
        _approve(maker, address(tok), 1e18);
        vm.expectEmit(true, true, true, true, address(hs));
        emit HandshakeV4_1.OfferCreated(1, maker, address(0), address(tok), 1 ether, 1e18, false, 0, 40);
        vm.prank(maker);
        hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0, 300);
    }

    // ---- Proovant CHORD-02: a fill can't spend what backs the taker's own open offers ---------------

    function _aliceOffersToken(uint256 amt) internal returns (uint256 id) {
        tok.mint(alice, amt);
        vm.startPrank(alice);
        tok.approve(address(hs), amt);
        id = hs.createOffer(address(tok), amt, 1 ether, false, address(0), 0, 300);
        vm.stopPrank();
    }

    /// Maker sells BDAG for `amtTok` of the token, so the taker pays with the token.
    function _makerSellsBdag(uint256 amtTok) internal returns (uint256 id) {
        _approve(maker, address(wbdag), type(uint256).max);
        vm.prank(maker);
        id = hs.createOffer(address(tok), amtTok, 1 ether, true, address(0), 0, 300);
    }

    function test_CHORD02_fillCantSpendTakersCommittedApproval() public {
        uint256 mine = _aliceOffersToken(1_000e18);
        uint256 theirs = _makerSellsBdag(600e18);
        tok.mint(alice, 600e18);

        vm.prank(alice);
        vm.expectRevert("approve this fill on top of your own open offers");
        hs.fill(theirs);
        assertTrue(hs.offerReady(mine));

        vm.startPrank(alice);
        tok.approve(address(hs), 1_600e18);
        hs.fill(theirs);
        vm.stopPrank();
        assertTrue(hs.offerReady(mine), "her own offer stays backed");
        assertEq(tok.allowance(alice, address(hs)), 1_000e18);
    }

    function test_CHORD02_fillCantSpendTakersCommittedBalance() public {
        uint256 mine = _aliceOffersToken(1_000e18); // she holds exactly 1,000
        uint256 theirs = _makerSellsBdag(600e18);
        vm.startPrank(alice);
        tok.approve(address(hs), 1_600e18);
        vm.expectRevert("fill would leave your own open offers short of balance");
        hs.fill(theirs);
        vm.stopPrank();
        assertTrue(hs.offerReady(mine));
    }

    function test_CHORD02_noOwnOffers_exactApprovalStillWorks() public {
        uint256 theirs = _makerSellsBdag(600e18);
        tok.mint(alice, 600e18);
        vm.startPrank(alice);
        tok.approve(address(hs), 600e18);
        hs.fill(theirs);
        vm.stopPrank();
        assertEq(uint8(hs.getOffer(theirs).status), uint8(HandshakeV4_1.Status.Filled));
    }

    function test_CHORD02_payingInBdag_unaffectedByOwnOffers() public {
        // Alice's open offer gives the token; she pays BDAG for this fill, so nothing she committed is touched.
        _aliceOffersToken(5e18);
        _approve(maker, address(tok), 1e18);
        vm.prank(maker);
        uint256 theirs = hs.createOffer(address(tok), 1e18, 1 ether, false, address(0), 0, 300);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        hs.fill{value: 1 ether}(theirs);
    }

    function testFuzz_CHORD02_takerOffersAlwaysBackedAfterFill(uint96 own, uint96 fillAmt, uint96 extra) public {
        own = uint96(bound(own, 1, 1_000e18));
        fillAmt = uint96(bound(fillAmt, 1, 1_000e18));
        uint256 mine = _aliceOffersToken(own);
        uint256 theirs = _makerSellsBdag(fillAmt);
        tok.mint(alice, fillAmt);
        vm.startPrank(alice);
        tok.approve(address(hs), uint256(own) + bound(extra, 0, uint256(fillAmt) * 2));
        try hs.fill(theirs) {} catch {}
        vm.stopPrank();
        assertTrue(hs.offerReady(mine), "taker's own offer must stay backed whether or not the fill went through");
    }

    // ---- F-01, F-05, ownership ------------------------------------------------------------------

    function test_F01_payerOverchargedIsRefused() public {
        OverchargeToken ot = new OverchargeToken();
        ot.mint(maker, 10e18);
        vm.prank(maker);
        ot.approve(address(hs), 10e18);
        vm.prank(maker);
        uint256 id = hs.createOffer(address(ot), 1e18, 1 ether, false, address(0), 0, 300);
        vm.prank(taker);
        vm.expectRevert("token took a transfer fee or rebased - unsupported");
        hs.fill{value: 1 ether}(id);
    }

    function test_F05_feeRecipientCantBeTheContract() public {
        vm.expectRevert("bad recipient");
        hs.setFeeRecipient(address(hs));
        vm.expectRevert("bad recipient");
        hs.setFeeRecipient(address(0));
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert("bad fee recipient");
        new HandshakeV4_1(address(wbdag), next);
    }

    function test_ownership_pendingCanBeReplaced() public {
        hs.transferOwnership(taker);
        hs.transferOwnership(alice);
        vm.prank(taker);
        vm.expectRevert("not pending owner");
        hs.acceptOwnership();
        vm.prank(alice);
        hs.acceptOwnership();
        assertEq(hs.owner(), alice);
    }
}

/// Random create / fill / cancel / move-away sequences: committed must always equal the sum of each maker's
/// Open offers, per asset.
contract HandshakeV41CommittedInvariantTest is Test {
    HandshakeV4_1 hs;
    TestWBDAG wbdag;
    HsToken tok;
    V41Handler h;

    function setUp() public {
        wbdag = new TestWBDAG();
        hs = new HandshakeV4_1(address(wbdag), makeAddr("fee"));
        tok = new HsToken("Test", "TST");
        h = new V41Handler(hs, wbdag, tok);
        targetContract(address(h));
    }

    function invariant_committedMatchesOpenOffers() public view {
        uint256 n = hs.totalOffers();
        for (uint256 i; i < 3; i++) {
            address a = address(uint160(0xA000 + i));
            uint256 sumW;
            uint256 sumT;
            for (uint256 id = 1; id <= n; id++) {
                HandshakeV4_1.Offer memory o = hs.getOffer(id);
                if (o.maker != a || o.status != HandshakeV4_1.Status.Open) continue;
                if (o.makerGivesNative) sumW += o.amountNative; else sumT += o.amountToken;
            }
            assertEq(hs.committed(a, address(wbdag)), sumW, "WBDAG committed");
            assertEq(hs.committed(a, address(tok)), sumT, "token committed");
        }
    }

    function invariant_neverHoldsFunds() public view {
        assertEq(address(hs).balance, 0);
        assertEq(wbdag.balanceOf(address(hs)), 0);
        assertEq(tok.balanceOf(address(hs)), 0);
    }
}
