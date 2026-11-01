// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {HookConfig, IMDuelHarness} from "./Harness.sol";

/// A router that swaps in two pools inside one unlock, settling each currency once at the end.
contract TwoSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable m;

    constructor(IPoolManager m_) {
        m = m_;
    }

    function swap2(PoolKey memory a, SwapParams memory pa, PoolKey memory b, SwapParams memory pb) external {
        m.unlock(abi.encode(msg.sender, a, pa, b, pb));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory a, SwapParams memory pa, PoolKey memory b, SwapParams memory pb) =
            abi.decode(data, (address, PoolKey, SwapParams, PoolKey, SwapParams));
        m.swap(a, pa, "");
        m.swap(b, pb, "");
        Currency[4] memory cs = [a.currency0, a.currency1, b.currency0, b.currency1];
        for (uint256 i; i < 4; i++) {
            bool dup;
            for (uint256 j; j < i; j++) if (cs[j] == cs[i]) dup = true;
            if (dup) continue;
            int256 d = m.currencyDelta(address(this), cs[i]);
            if (d < 0) {
                m.sync(cs[i]);
                MockERC20(Currency.unwrap(cs[i])).transferFrom(payer, address(m), uint256(-d));
                m.settle();
            } else if (d > 0) {
                m.take(cs[i], payer, uint256(d));
            }
        }
        return "";
    }
}

/// The mate's payout at its edges (the Fable reviews' lists): the loser right in both token orders, a draw, a dust
/// mate, an empty pot, a timeout mate through the real path, solvency fuzzed with IMD as currency1, and the swarm's
/// small fixes.
contract MatePotTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /// The main duel with IMD as currency0 (as Base) or as currency1 (so $IMDUEL is currency0).
    function setUpOrder(bool imdIsCurrency1) internal {
        deployV4();
        deployMintAndApprove2Currencies();
        deployHook(config(v5(), imdIsCurrency1 ? currency1 : currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function fund() internal {
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
    }

    function token(uint256 team) internal view returns (Currency) {
        return team == 0 ? currency0 : currency1;
    }

    /// Both teams mate once each, through the harness: the prize always comes from the loser's pot in the loser's token.
    function losersPayInBothOrders(bool imdIsCurrency1) internal {
        setUpOrder(imdIsCurrency1);
        fund();
        assertEq(whiteTeam(), imdIsCurrency1 ? 0 : 1, "the token people buy ($IMDUEL) plays White first");
        for (uint256 loser; loser < 2; loser++) {
            address owner = address(uint160(0xA0 + loser));
            uint256 before = hook.chest(id, loser);
            mateAgainst(loser, owner, 1e30);
            assertEq(hook.owed(owner, token(loser).toId()), before / 4, "a quarter of the loser's pot, in the loser's token");
            assertEq(hook.owed(owner, token(1 - loser).toId()), 0, "nothing in the winner's token");
            assertEq(hook.chest(id, loser), before - before / 4);
        }
        assertEq(hook.chest(id, 0) + hook.chest(id, 1), 150e18);
        address[] memory who = new address[](2);
        (who[0], who[1]) = (address(0xA0), address(0xA1));
        assertSolvent(who);
    }

    function test_theLoserPaysWhenImduelIsCurrency1() public {
        losersPayInBothOrders(false);
    }

    function test_theLoserPaysWhenImduelIsCurrency0() public {
        losersPayInBothOrders(true);
    }

    /// A move that stalemates ends the game and pays nothing: the pots wait for a mate.
    function test_aDrawPaysNothing() public {
        setUpOrder(false);
        fund();
        uint256 b;
        b = put(b, "f7", 6);
        b = put(b, "g5", 5);
        b = put(b, "h8", 14); // Qg6 leaves the black king no move and no check
        hook.setPosition(id, b, side("f7"), side("h8"), 0, 0);
        vm.recordLogs();
        hook.applyMove(pool, mv("g5", "g6"), address(0xA), 1e30);
        assertEq(st().gameNo, 1, "the game ended");
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 0);
        assertEq(hook.chest(id, 0), 100e18);
        assertEq(hook.chest(id, 1), 100e18);
        assertEq(hook.owed(address(0xA), currency0.toId()) + hook.owed(address(0xA), currency1.toId()), 0);
    }

    /// A dust bid that mates earns at most twice its dust.
    function test_aDustMateEarnsTwiceItsDust() public {
        setUpOrder(false);
        fund();
        uint256 w = whiteTeam();
        mateAgainst(1 - w, address(0xD), 100);
        assertEq(hook.owed(address(0xD), token(1 - w).toId()), 200);
        assertEq(hook.chest(id, 1 - w), 100e18 - 200);
    }

    /// A mate against an empty pot pays nothing and still ends the game.
    function test_aMateAgainstAnEmptyPotPaysNothing() public {
        setUpOrder(false);
        uint256 w = whiteTeam();
        vm.recordLogs();
        mateAgainst(1 - w, address(0xA), 1e30);
        assertEq(st().gameNo, 1, "the game ended");
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 0);
        assertEq(hook.owed(address(0xA), token(1 - w).toId()), 0);
    }

    /// A timeout move that mates, through the real path (the silent side's move opened by the other team's trade,
    /// played by the next block's), pays nobody and lists nobody.
    function test_aTimeoutMatePaysNobody() public {
        setUpOrder(false);
        fund();
        uint256 w = whiteTeam();
        forcedMate(true); // Black's only move mates; nobody bids for it
        vm.warp(vm.getBlockTimestamp() + hook.TURN_TIMEOUT());
        white(1e18, address(0xA)); // White's trade opens Black's timeout move
        assertTrue(bid().open);
        assertEq(bid().owner, address(0));
        next(12);
        vm.recordLogs();
        white(1e18, address(0xA)); // plays it
        assertEq(st().gameNo, 1, "mate");
        assertEq(st().moveOwner, address(0));
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 0);
        assertGe(hook.chest(id, w), 100e18, "the loser's pot only grew (fees)");
        assertEq(hook.playerCount(), 0, "nobody played a move of their own");
    }

    /// Random trading with real engine moves and IMD as currency1 (mates pay out along the way): held always equals
    /// owed, in both currencies, before and after every claim.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_heldEqualsOwedWithImdAsCurrency1(uint256 seed) public {
        setUpOrder(true);
        fund();
        address[] memory who = new address[](4);
        (who[0], who[1], who[2], who[3]) = (tx.origin, address(0xA), address(0xB), address(0xC));
        for (uint256 i; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            if ((seed >> 8) % 4 != 0) next(12 + (seed >> 16) % 40);
            address owner = (seed >> 24) % 4 == 0 ? address(0) : who[1 + (seed >> 32) % 3];
            if ((seed >> 48) % 4 == 0) swap(pool, (seed >> 40) % 2 == 0, int256(1e15 + seed % 5e18), "");
            else trade((seed >> 40) % 2, 1e15 + seed % 5e20, owner);
        }
        assertSolvent(who);
        for (uint256 i; i < who.length; i++) {
            hook.withdraw(who[i], currency0);
            hook.withdraw(who[i], currency1);
        }
        assertSolvent(who);
    }

    // ---------------------------------------------------------------- the inflow cap (audit 2026-10-31, economics H1)

    /// A game played for dust puts nothing into the pots, so its mate pays nothing: a pot can't be harvested by fast
    /// games against oneself.
    function test_aDustGamePaysNothing() public {
        setUpOrder(false);
        fund();
        uint256 w = whiteTeam();
        vm.recordLogs();
        mateAgainstIn(1 - w, address(0xB07), 1e30, 0, 0);
        assertEq(st().gameNo, 1, "the game ended");
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 0);
        assertEq(hook.owed(address(0xB07), token(1 - w).toId()), 0);
        assertEq(hook.chest(id, 1 - w), 100e18, "the pot kept everything");
    }

    /// The prize is at most what the losing team's buyers paid into its pot this game; the winner's pot's inflow never
    /// counts (no price is read to value it).
    function test_thePrizeIsAtMostTheLosersOwnInflow() public {
        setUpOrder(false);
        fund();
        uint256 loser = 1 - whiteTeam();
        mateAgainstIn(loser, address(0xA), 1e30, loser == 0 ? 1e18 : 0, loser == 0 ? 0 : 1e18); // 1 into the loser's pot
        assertEq(hook.owed(address(0xA), token(loser).toId()), 1e18, "the loser's pot's inflow");
        loser = 1 - whiteTeam(); // game 1: colours swapped
        mateAgainstIn(loser, address(0xB), 1e30, loser == 0 ? 0 : 3e18, loser == 0 ? 3e18 : 0); // 3 into the winner's pot
        assertEq(hook.owed(address(0xB), token(loser).toId()), 0, "the winner's pot's inflow doesn't count");
        address[] memory who = new address[](2);
        (who[0], who[1]) = (address(0xA), address(0xB));
        assertSolvent(who);
    }

    /// Donations don't count as inflow: funding the loser's pot and mating it earns the funder nothing.
    function test_aDonationDoesNotRaiseTheCap() public {
        setUpOrder(false);
        uint256 w = whiteTeam();
        hook.fundChest(pool, 1 - w == 1, 100e18); // the loser's pot, from the would-be winner
        (uint256 in0, uint256 in1) = hook.gameInflow(id, 0);
        assertEq(in0 + in1, 0, "a donation is not trading");
        mateAgainstIn(1 - w, address(0xA), 1e30, 0, 0);
        assertEq(hook.owed(address(0xA), token(1 - w).toId()), 0);
    }

    /// Through the real path: the loser's buyers' pot fees cap the prize, far under the quarter and the 2x bid; the
    /// resolving trade's fee, however big, counts for the next game, the one its bid is for (audit 2026-11-01, L-1).
    function test_aShortGamePaysTheLosersFeesNotTheResolvingTrades() public {
        setUpOrder(false);
        fund();
        uint256 loser = whiteTeam(); // White gets mated
        forcedMate(true); // Black's only move mates
        hook.setGameIn(id, 0, 0); // nothing traded yet this game
        white(1e18, address(0xA)); // White's buyers pay into White's pot (a bid for White's next move)
        black(1e18, address(0xB)); // the mating bid, into Black's pot
        (uint256 in0, uint256 in1) = hook.gameInflow(id, 0);
        uint256 own = loser == 0 ? in0 : in1;
        assertGt(own, 0);
        next(12);
        white(1e23, address(0)); // plays the mate
        assertEq(st().gameNo, 1, "mate");
        assertEq(hook.owed(address(0xB), token(loser).toId()), own, "exactly the loser's buyers' pot fees");
        (uint256 next0, uint256 next1) = hook.gameInflow(id, 1);
        assertGt(next0 + next1, 5e20, "the resolving trade's 0.65% counts for game 1");
    }

    // ---------------------------------------------------------------- the swarm audit of 2026-11-01 (job 6acefe89)

    /// H-1: a side duel whose only LP is the attacker. Its own buy moves the price ~1e12 (sqrt) in the dust pool, and
    /// the old cap valued the dust inflow at that price, paying the 2x-bid prize from a pot others filled. Now a prize
    /// is at most the losing pot's inflow that game: the attacker's own fee.
    function test_aThinSideDuelPaysBackAtMostTheAttackersOwnFee() public {
        deployV4();
        MockERC20 imdToken = deployHookAside(v5());
        MockERC20 sideToken = mockToken("SIDE", "SIDE");
        for (uint256 i; i < 2; i++) {
            MockERC20 t = i == 0 ? imdToken : sideToken;
            t.mint(address(this), 1e30);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
            t.approve(address(hook), type(uint256).max);
        }
        (Currency imdC, Currency sideC) = (Currency.wrap(address(imdToken)), Currency.wrap(address(sideToken)));
        (Currency c0, Currency c1) = imdC < sideC ? (imdC, sideC) : (sideC, imdC);
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(pool, ModifyLiquidityParams(-887220, 887220, 1e6, 0), "");
        uint256 imdTeam = c0 == imdC ? 0 : 1;
        hook.fundChest(pool, imdTeam == 1, 100e18); // earlier traders' fees, as a donation (not this game's inflow)
        hook.fundChest(pool, imdTeam == 0, 1e18);
        assertEq(whiteTeam(), 1 - imdTeam, "SIDE's team (the token people buy) plays White");
        forcedMate(false); // White's only move mates
        hook.setGameIn(id, 0, 0);
        trade(1 - imdTeam, 1e18, address(this)); // the attacker's bid, through its own dust liquidity
        next(12);
        trade(1 - imdTeam, 1000, address(0)); // plays the mate
        assertEq(st().gameNo, 1, "mate");
        // the IMD pot pays back at most the attacker's own half of the pot fee on its 1 IMD: never what others put in,
        // and the attacker also lost the 0.1% IMD slice to the main duel's IMD pot
        assertLe(hook.owed(address(this), imdC.toId()), 1e18 * 65 / 20_000, "at most its own fee back");
        assertGe(hook.chest(id, imdTeam), 100e18, "the IMD pot kept what earlier traders put in");
    }

    /// M-1: a player who trades a game alone gets back at most the half of its pot fees that went into the losing pot
    /// (0.325% of its volume), under the 0.75% it was charged, so being the in-range LP never makes farming a pot pay.
    function test_aGameTradedAloneReturnsAtMostItsPotFees() public {
        setUpOrder(false);
        fund();
        uint256 loser = 1 - whiteTeam();
        uint256 volume = 1920e18;
        uint256 fees = volume * hook.CHEST_BPS() / 20_000; // 6.24e18: half of every leg's pot fee, into the loser's pot
        mateAgainstIn(loser, address(0xF), 12.5e18, loser == 0 ? fees : 0, loser == 0 ? 0 : fees);
        uint256 won = hook.owed(address(0xF), token(loser).toId());
        assertEq(won, fees, "the game's own pot fees");
        assertLt(won, volume * (hook.CHEST_BPS() + hook.SLICE_BPS()) / 10_000, "under what the hook charged");
    }

    /// L-2: a trade naming the PoolManager or the hook as its owner bids for the signer: a reward owed to either could
    /// never be claimed.
    function test_theManagerOrTheHookOwnsNoBid() public {
        setUpOrder(false);
        white(1e18, address(manager));
        assertEq(bid().owner, tx.origin, "the manager counts as none");
        white(2e18, address(hook));
        assertEq(bid().owner, tx.origin, "the hook counts as none");
        white(4e18, DEAD);
        assertEq(bid().owner, tx.origin, "0x...dEaD counts as none: its owed balance is the burn");
    }

    /// Info, and its review: a move whose window's hash the chain no longer serves keeps its bid's size and strength
    /// but plays for nobody, its window the block that finds it so: the board gets the paid strength, and letting a
    /// seen move expire to draw it again never pays (a mate then pays nobody).
    function test_anExpiredHashPlaysThePaidBidForNobody() public {
        setUpOrder(false);
        fund();
        uint256 loser = 1 - whiteTeam();
        forcedMate(false); // White's only move mates
        white(1e18, address(0xB1D));
        IMDuelHook.TopBid memory paid = bid();
        vm.warp(vm.getBlockTimestamp() + 9_000 * 12);
        vm.roll(vm.getBlockNumber() + 9_000); // past the 8,191 hashes (no history contract here either)
        black(100, address(0));
        assertEq(bid().owner, address(0), "now for nobody");
        assertEq(bid().size, paid.size, "the size kept");
        assertEq(bid().strength, paid.strength, "the strength kept");
        assertEq(st().gameNo, 0, "not played yet");
        next(12);
        black(100, address(0));
        assertEq(st().gameNo, 1, "the mate, played");
        assertEq(st().moveOwner, address(0));
        assertEq(hook.owed(address(0xB1D), token(loser).toId()), 0, "the bidder gets nothing");
        assertGe(hook.chest(id, loser), 100e18, "the pot keeps everything");
    }

    // ---------------------------------------------------------------- the reviews of the fixes (2026-11-01)

    /// Every swap shape (both directions, exact in and out, so each half of the pot fee is taken before or after the
    /// swap) puts half the pot fee into each pot and records exactly that as each pot's inflow; the books balance.
    function test_everySwapShapeRecordsItsPotFee() public {
        setUpOrder(false);
        fund();
        hook.setGameIn(id, 0, 0);
        for (uint256 k; k < 4; k++) {
            bool zeroForOne = k & 1 == 1;
            (uint256 c0, uint256 c1) = (hook.chest(id, 0), hook.chest(id, 1));
            (uint256 i0, uint256 i1) = hook.gameInflow(id, 0);
            swap(pool, zeroForOne, k & 2 == 2 ? int256(3e18) : -int256(3e18), "");
            (uint256 j0, uint256 j1) = hook.gameInflow(id, 0);
            assertEq(j0 - i0, hook.chest(id, 0) - c0, "pot 0: inflow == its half of the pot fee");
            assertEq(j1 - i1, hook.chest(id, 1) - c1, "pot 1: the same");
            assertGt(j0 - i0, 0, "both sides pay");
            assertGt(j1 - i1, 0);
        }
        assertSolvent(nobody());
    }

    /// Two swaps in one unlock, a main duel swap that plays a mate and a side duel's, in either order: each pool's
    /// game inflow is its own 0.325% of each leg, nothing leaks through the pending fee's transient slot, and the
    /// resolving swap's fee counts for the next game while the prize reads only the mating game's.
    function twoSwapsInOneUnlock(bool mainFirst) internal {
        setUpOrder(false);
        fund();
        MockERC20 xToken = mockToken("X", "X");
        xToken.mint(address(this), 1e30);
        Currency xC = Currency.wrap(address(xToken));
        (Currency c0, Currency c1) = currency0 < xC ? (currency0, xC) : (xC, currency0);
        PoolKey memory side = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        PoolId sid = side.toId();
        manager.initialize(side, SQRT_PRICE_1_1);
        xToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(side, ModifyLiquidityParams(-887220, 887220, 1_000_000e18, 0), "");
        TwoSwapRouter r = new TwoSwapRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(r), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(r), type(uint256).max);
        xToken.approve(address(r), type(uint256).max);
        forcedMate(true);
        hook.setGameIn(id, 0, 0);
        white(1e18, address(0xA)); // the losing team's buyers fund the prize
        black(1e18, address(0xB));
        (uint256 m0, uint256 m1) = hook.gameInflow(id, 0);
        next(12);
        bool mainDir = whiteTeam() == 1;
        bool sideDir = c0 == currency0; // sell IMD into the side duel
        SwapParams memory pm = SwapParams(mainDir, -int256(10e18), mainDir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
        SwapParams memory ps = SwapParams(sideDir, -int256(20e18), sideDir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
        if (mainFirst) r.swap2(pool, pm, side, ps);
        else r.swap2(side, ps, pool, pm);
        assertEq(st().gameNo, 1, "the mate was played");
        uint256 won = hook.owed(address(0xB), token(whiteTeam() == 0 ? 1 : 0).toId()); // game 0's White lost
        assertGt(won, 0);
        assertEq(won, whiteTeam() == 0 ? m1 : m0, "the prize reads the mating game's loser inflow only");
        (uint256 n0, uint256 n1) = hook.gameInflow(id, 1);
        assertGt(n0 + n1, 6.4e16, "the resolving swap's fee counts for game 1");
        assertLt(n0 + n1, 6.6e16, "once");
        (uint256 s0, uint256 s1) = hook.gameInflow(sid, 0);
        assertGt(s0 + s1, 1.28e17, "the side duel's own 0.325% of each of its ~20e18 legs");
        assertLt(s0 + s1, 1.31e17, "and nothing of the main duel's");
        assertEq(hook.chest(sid, 0) + hook.chest(sid, 1), s0 + s1, "the side duel's pots hold exactly its inflow");
    }

    function test_twoSwapsInOneUnlockKeepTheirInflowApart() public {
        twoSwapsInOneUnlock(true);
    }

    function test_twoSwapsInOneUnlockKeepTheirInflowApartReversed() public {
        twoSwapsInOneUnlock(false);
    }

    /// A fee-free swap after a fee-paying one in the same unlock adds no inflow: the pending pot fee is cleared by the
    /// swap that set it (round 3: a kept pending fee would be counted again by every later swap).
    function test_aFeeFreeSwapAfterAFeeInOneUnlockAddsNoInflow() public {
        setUpOrder(false);
        TwoSwapRouter r = new TwoSwapRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(r), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(r), type(uint256).max);
        hook.setGameIn(id, 0, 0);
        r.swap2(pool, SwapParams(true, -10e18, MIN_PRICE_LIMIT), pool, SwapParams(false, -100, MAX_PRICE_LIMIT));
        (uint256 in0, uint256 in1) = hook.gameInflow(id, 0);
        assertEq(in0, hook.chest(id, 0), "pot 0: the first swap's half only, not counted again by the dust swap");
        assertEq(in1, hook.chest(id, 1), "pot 1: the same");
        assertGt(in0 + in1, 0);
    }

    /// A mate against a team nobody bought this game still pays: every trade puts half its pot fee into each pot, so
    /// the losing pot's inflow is half of what the winners' buys paid (and no more).
    function test_aMateAgainstATeamNobodyBoughtStillPays() public {
        setUpOrder(false);
        fund();
        uint256 loser = whiteTeam();
        forcedMate(true); // Black mates
        hook.setGameIn(id, 0, 0);
        for (uint256 i; i < 5; i++) black(100e18, address(uint160(0x300 + i))); // only Black's token is bought
        address owner = bid().owner;
        (uint256 in0, uint256 in1) = hook.gameInflow(id, 0);
        uint256 own = loser == 0 ? in0 : in1;
        assertGt(own, 0, "the losing pot got the input side's half of every buy");
        next(12);
        black(1000, address(0));
        assertEq(st().gameNo, 1, "mate");
        assertEq(hook.owed(owner, token(loser).toId()), own, "exactly that game's inflow into the losing pot");
    }

    // ---------------------------------------------------------------- the swarm's small fixes (launch 2671's notes)

    function test_withdrawToRefusesAddressZeroTheHookAndTheManager() public {
        setUpOrder(false);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.withdrawTo(currency0, address(0));
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.withdrawTo(currency0, address(hook));
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.withdrawTo(currency0, address(manager));
    }
}
