// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {HookConfig, IMDuelHarness} from "./Harness.sol";

/// The mate's payout at its edges (the Fable reviews' lists): the loser right in both token orders, a draw, a dust
/// mate, an empty pot, a timeout mate through the real path, solvency fuzzed with IMD as currency1, and the swarm's
/// small fixes.
contract MatePotTest is Base {
    using CurrencyLibrary for Currency;

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

    /// The prize is at most twice what the game's trading put into both pots, the winner's pot's share valued in the
    /// loser's token at the pool's price (1:1 here).
    function test_thePrizeIsAtMostTwiceTheGamesInflow() public {
        setUpOrder(false);
        fund();
        uint256 w = whiteTeam();
        mateAgainstIn(1 - w, address(0xA), 1e30, 1 - w == 0 ? 1e18 : 0, 1 - w == 0 ? 0 : 1e18); // 1 into the loser's pot
        assertEq(hook.owed(address(0xA), token(1 - w).toId()), 2e18, "twice the loser's pot's inflow");
        uint256 loser = 1 - whiteTeam(); // game 1: colours swapped
        mateAgainstIn(loser, address(0xB), 1e30, loser == 0 ? 0 : 3e18, loser == 0 ? 3e18 : 0); // 3 into the winner's pot
        assertEq(hook.owed(address(0xB), token(loser).toId()), 6e18, "twice the other pot's inflow, valued at 1:1");
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

    /// Through the real path: a two-trade game pays twice its own fees, far under the quarter and the 2x bid.
    function test_aShortGamePaysTwiceItsOwnFees() public {
        setUpOrder(false);
        fund();
        uint256 loser = whiteTeam(); // White gets mated
        forcedMate(true); // Black's only move mates
        hook.setGameIn(id, 0, 0); // nothing traded yet this game
        black(1e18, address(0xB));
        next(12);
        white(1e18, address(0)); // plays the mate; its own fee counts too
        assertEq(st().gameNo, 1, "mate");
        (uint256 in0, uint256 in1) = hook.gameInflow(id, 0);
        assertGt(in0 + in1, 0, "the two trades' pot fees");
        uint256 won = hook.owed(address(0xB), token(loser).toId());
        assertApproxEqRel(won, 2 * (in0 + in1), 0.001e18, "twice the game's inflow (the two tokens at 1:1)");
        assertLt(won, 1e17, "far under the quarter and twice the bid");
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

    /// A zero minimum would make every conversion batch spend nothing, so the constructor refuses it.
    function test_theConstructorRefusesZeroMinimums() public {
        setUpOrder(false);
        HookConfig memory c = config(engine, currency0);
        c.minImd = 0;
        vm.expectRevert(IMDuelHook.BadConfig.selector);
        new IMDuelHarness(c);
        c = config(engine, currency0);
        c.minImduel = 0;
        vm.expectRevert(IMDuelHook.BadConfig.selector);
        new IMDuelHarness(c);
    }
}
