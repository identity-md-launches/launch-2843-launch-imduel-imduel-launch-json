// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Strength} from "../src/Strength.sol";
import {Base} from "./Base.sol";

/// Strength is what a trade received as a share of its own team's pot, read when it bids: after any mate the same trade played has been paid, untouched by liquidity, moved only by
/// money put into the pot. Main duel: currency0 = "IMD", currency1 = "$IMDUEL".
contract PotStrengthTest is Base {
    using CurrencyLibrary for Currency;

    function setUp() public {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function fundBoth(uint256 amount) internal {
        hook.fundChest(pool, false, amount);
        hook.fundChest(pool, true, amount);
    }

    /// The trade that plays a mate and then bids reads the pot after the mate's payout: here the losing team's own
    /// trade, whose pot the prize just left, so its bid is stronger than the same trade with no mate to play (the
    /// control), by the share the prize took: about 2 of 100, one point of a doubling.
    function test_strengthIsReadAfterTheMateTheTradePlayed() public {
        fundBoth(100e18);
        uint256 w = whiteTeam();
        forcedMate(false); // White's only move mates
        uint256 snap = vm.snapshotState();
        trade(1 - w, 5e18, address(0xB)); // the control: nothing queued, the trade just bids for Black's next move
        uint256 control = st().bids[1 - w].strength;
        vm.revertToState(snap);
        white(1e18, address(0xA)); // owns the mate: the prize is capped at twice this, about 2 of 100
        next(12);
        uint256 potBefore = hook.chest(id, 1 - w);
        trade(1 - w, 5e18, address(0xB)); // the loser's team plays the mate, then bids
        uint256 potAfter = hook.chest(id, 1 - w);
        assertLt(potAfter, potBefore - 1.9e18, "the prize left the loser's pot first");
        uint256 s = st().bids[1 - w].strength; // its bid, for its first move of the new game
        uint256 expected = Strength.BPS_PER_DOUBLING * 29 / 1000; // log2(100 / 98) is about 0.029 doublings: 26 points
        assertGt(s, control + 10, "stronger than the control: the pot was read after the payout");
        assertLt(s, control + expected + 20);
    }

    /// Liquidity added or pulled around a trade (a JIT bracket, a provider stepping out) changes nothing: the victim
    /// equals the control (the swarm's six proofs on the parked launch, now moot).
    function test_liquidityChangesNothing() public {
        fundBoth(1e21);
        uint256 snap = vm.snapshotState();
        white(1e19, address(0xA));
        uint256 control = bid().strength;
        assertApproxEqAbs(control, 3_000, 90, "a 1% share plays at 30%");
        vm.revertToState(snap);
        addLiquidity(pool); // twice the depth, added just before
        white(1e19, address(0xA));
        assertApproxEqAbs(bid().strength, control, 2, "more depth: the same strength");
        vm.revertToState(snap);
        modifyLiquidityRouter.modifyLiquidity(pool, ModifyLiquidityParams(-887220, 887220, -900_000e18, 0), ""); // a tenth left
        white(1e19, address(0xA));
        assertApproxEqAbs(bid().strength, control, 2, "less depth: the same strength");
    }

    /// Money put into a team's pot is the one thing that moves strength: each doubling of the pot costs that team's
    /// bids one doubling of share (about 9 points), and it raises what the other team wins by mating it.
    function test_aDonationWeakensTheTeamsBidsAndRaisesThePrizeForMatingIt() public {
        fundBoth(1e21);
        uint256 w = whiteTeam();
        white(1e19, address(0xA));
        uint256 before = bid().strength;
        playTurn();
        black(1e18, address(0xB));
        playTurn();
        hook.fundChest(pool, w == 1, 1e21); // White's pot doubled
        white(1e19, address(0xA));
        assertApproxEqAbs(before - bid().strength, Strength.BPS_PER_DOUBLING, 10, "one doubling weaker");
        playTurn();
        uint256 pot = hook.chest(id, w);
        mateAgainst(w, address(0xC), 1e30); // the other team mates White's team
        assertEq(hook.owed(address(0xC), (w == 0 ? currency0 : currency1).toId()), pot / 4, "a quarter of the doubled pot");
    }

    /// An exact-output trade's strength counts what the pool paid out for it, including the pot share the hook took
    /// from that output before the swap: the trader's own fee is part of its bid.
    function test_exactOutputStrengthIncludesThePotShare() public {
        hook.fundChest(pool, false, 2e21);
        hook.fundChest(pool, true, 1e21);
        assertEq(whiteTeam(), 1, "currency1's team is to move");
        swap(pool, true, 1e19, abi.encodePacked(address(0xA))); // exact output of 1e19 currency1: the fee in the output
        uint256 pot = hook.chest(id, 1);
        assertEq(pot, 1e21 + 1e19 * 65 / 20_000, "half the pot fee, from the output");
        assertEq(bid().strength, Strength.fromShare(1e19 + 1e19 * 65 / 20_000 + 1e19 * 10 / 10_000, pot), "measured on the output plus the fee on it");
    }

    /// An empty pot plays at the cap, and the first fees make it a pot: dust then plays at 0.
    function test_anEmptyPotPlaysAtTheCapUntilItIsAPot() public {
        white(1e18, address(0xA));
        assertEq(bid().strength, 9_000, "nothing to measure against");
        playTurn();
        black(1e18, address(0xB));
        playTurn();
        white(1e18, address(0xA)); // the pots now hold the fees of three trades, far less than a trade: still the cap
        assertEq(bid().strength, 9_000);
        playTurn();
        black(1e18, address(0xB));
        playTurn();
        fundBoth(1e21);
        white(1_000, address(0xA));
        assertEq(bid().strength, 0, "dust against a pot");
    }
}
