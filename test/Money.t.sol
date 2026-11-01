// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {Vm} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract RefusesEth {
    bool public accepting;

    function acceptEth() external {
        accepting = true;
    }

    receive() external payable {
        require(accepting, "refused");
    }
}

/// Fees (0.65% to the pot worth less, 0.1% slice), the mate payout (a quarter of the loser's pot to the move that mated,
/// at most twice what its trade paid), claims, pot funding and solvency. Main duel: currency0 = "IMD", currency1 =
/// "$IMDUEL".
contract MoneyTest is Base {
    using CurrencyLibrary for Currency;

    uint256 constant TINY = 100; // a trade whose fee rounds to zero: finalizes a move without touching the chests

    function setUp() public {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    // ---------------------------------------------------------------- fees

    /// A buy of currency1 ($IMDUEL here) with 1 currency0: 0.325% of the input into currency0's pot, 0.325% of the
    /// output into currency1's pot, and the 0.1% slice of the $IMDUEL side burned (owed to 0x...dEaD).
    function test_aBuyFeedsBothPotsAndBurnsTheSlice() public {
        uint256 before = currency1.balanceOfSelf();
        trade(1, 1e18, address(0));
        uint256 received = currency1.balanceOfSelf() - before;
        uint256 out = received + claims(currency1); // what the pool paid out, before the hook's fee
        assertEq(hook.chest(id, 0), 1e18 * 65 / 20_000, "half the pot fee from the input");
        assertEq(hook.chest(id, 1), out * 65 / 20_000, "half from the output");
        assertEq(hook.owed(DEAD, currency1.toId()), out * 10 / 10_000, "the whole slice burned");
        assertEq(claims(currency0), hook.chest(id, 0));
    }

    /// URC-2: every trade emits the hook's own delta (the fee it took, in pool token order, negative from the
    /// swapper's side) and the hook fee rate, so indexers see what the trader really paid.
    function test_everyTradeEmitsHookSwapWithTheHookFee() public {
        vm.recordLogs();
        trade(1, 1e18, address(0)); // buys currency1: the pot fee and the slice both fall in currency1, the output
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != HOOK_SWAP) continue;
            n++;
            assertEq(logs[i].topics[1], PoolId.unwrap(id), "the pool");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(swapRouter), "the sender of the swap");
            (int128 a0, int128 a1, uint24 rate) = abi.decode(logs[i].data, (int128, int128, uint24));
            assertEq(uint256(uint128(-a0)), claims(currency0), "half the pot fee, from the input");
            assertEq(uint256(uint128(-a1)), claims(currency1), "the other half and the slice, from the output");
            assertEq(rate, 7_500, "the hook fee in pips");
        }
        assertEq(n, 1, "one HookSwap per swap");
        vm.recordLogs();
        trade(1, TINY, address(0)); // a dust trade: its fee rounds to zero, so the hook took nothing and says nothing
        assertEq(count(vm.getRecordedLogs(), HOOK_SWAP), 0, "no HookSwap without a hook delta");
    }

    /// Every trade feeds both pots by about the same value: one-sided buying still keeps them balanced (1:1 here).
    function test_everyTradeFeedsBothPots() public {
        for (uint256 i; i < 10; i++) trade(0, 1e18, address(0)); // buys currency0 only
        assertEq(hook.chest(id, 1), 10 * (1e18 * 65 / 20_000), "the input side's half, in currency1");
        assertApproxEqRel(hook.chest(id, 0), hook.chest(id, 1), 0.01e18, "the output side's half, about as much");
        assertEq(hook.owed(DEAD, currency1.toId()), 10 * 0.001e18, "the slice of the $IMDUEL input, burned");
        assertSolvent(nobody());
    }

    /// A trade must swap its whole order: the fee part taken before the swap counts all of it, so a trade its price
    /// limit stops early is refused rather than charged on what never traded (swarm audit 2026-10-27, finding 1). 100
    /// IMD in with the price allowed to move 0.001%: only about 10 would fill.
    function test_aTradeStoppedByItsPriceLimitIsRefused() public {
        uint256 before = currency0.balanceOfSelf();
        vm.expectRevert(); // PartialFill, wrapped by the pool manager
        swapRouter.swap(pool, SwapParams(true, -100e18, SQRT_PRICE_1_1 * 99_999 / 100_000), PoolSwapTest.TestSettings(false, false), "");
        assertEq(currency0.balanceOfSelf(), before, "nothing paid");
        swapRouter.swap(pool, SwapParams(true, -1e18, SQRT_PRICE_1_1 * 99_999 / 100_000), PoolSwapTest.TestSettings(false, false), "");
        assertGt(claims(currency1), 0, "a trade that fits inside its limit goes through");
    }

    /// Exact output with fees in the output (the specified side, taken before the swap): the trader gets exactly what
    /// it asked for; half the pot fee and the slice come off that output, the other half off the input.
    function test_exactOutputWithTheFeeInTheOutput() public {
        uint256 before = currency1.balanceOfSelf();
        swap(pool, true, 1e18, ""); // exact output of 1 currency1
        assertEq(currency1.balanceOfSelf() - before, 1e18, "exactly what was asked for");
        assertEq(hook.chest(id, 1), 1e18 * 65 / 20_000, "half the pot fee from the output");
        assertEq(hook.owed(DEAD, currency1.toId()), 0.001e18, "the slice, burned");
        assertGt(hook.chest(id, 0), 0, "the other half from the input");
    }

    /// Exact output of currency0: half the pot fee falls on that output, the other half and the slice on the
    /// unspecified $IMDUEL input.
    function test_exactOutputSlicesTheInput() public {
        uint256 inBefore = currency1.balanceOfSelf();
        uint256 outBefore = currency0.balanceOfSelf();
        swap(pool, false, 1e18, ""); // exact output of 1 currency0
        assertEq(currency0.balanceOfSelf() - outBefore, 1e18, "the specified output is preserved");
        assertEq(hook.chest(id, 0), 1e18 * 65 / 20_000, "half the pot fee from the output");
        uint256 spent = inBefore - currency1.balanceOfSelf();
        uint256 poolIn = spent - claims(currency1);
        assertEq(hook.chest(id, 1), poolIn * 65 / 20_000, "half from the pool's input");
        assertEq(hook.owed(DEAD, currency1.toId()), poolIn * 10 / 10_000, "the slice of the pool's input, burned");
        assertSolvent(nobody());
    }

    // ---------------------------------------------------------------- rewards

    function fund() internal {
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
    }

    /// White's rook mates on a8 (Kg1, rook on a`file`; Black: king on g8 or h8 behind pawns f7, g7, h7), played for
    /// `owner` whose trade paid `paid`, at half-move `ply` (even: White to move).
    function rookMate(uint16 ply, address owner, uint256 paid) internal {
        hook.setGameIn(id, WELL_TRADED, WELL_TRADED); // a well-traded game
        hook.setPosition(id, matingBoard("a1", "h8"), side("g1"), side("h8"), ply, 0);
        hook.applyMove(pool, mv("a1", "a8"), owner, paid);
    }

    function matingBoard(string memory rook, string memory king) internal pure returns (uint256 b) {
        b = put(b, "g1", 6);
        b = put(b, rook, 4);
        b = put(b, king, 14);
        b = put(b, "f7", 9);
        b = put(b, "g7", 9);
        b = put(b, "h7", 9);
    }

    /// The token a team is paid in when it wins: the loser's (0: currency0, 1: currency1).
    function teamToken(uint256 team) internal view returns (Currency) {
        return team == 0 ? currency0 : currency1;
    }

    /// What `who` claims in `c`: rewards are recorded, never pushed, and anyone may trigger the claim. A claim keeps 1
    /// wei owed, so the next reward updates the slot rather than creating it.
    function claimed(address who, Currency c) internal returns (uint256) {
        vm.prank(address(0xDEAD));
        hook.withdraw(who, c);
        return c.balanceOf(who);
    }

    function test_capturesAndChecksPayNothing() public {
        fund();
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "e8", 14);
        b = put(b, "a1", 4);
        b = put(b, "a8", 13); // a black queen
        hook.setPosition(id, b, side("e1"), side("e8"), 0, 0);
        hook.applyMove(pool, mv("a1", "a8"), address(0xA11CE), 1e30); // takes the queen, with check
        assertEq(hook.owed(address(0xA11CE), currency0.toId()) + hook.owed(address(0xA11CE), currency1.toId()), 0);
        assertEq(hook.chest(id, 0), 100e18);
        assertEq(hook.chest(id, 1), 100e18);
    }

    /// A mate takes a quarter of the LOSER's pot for the move that mated, in the loser's token.
    function test_mateTakesAQuarterOfTheLosersPot() public {
        fund();
        uint256 w = whiteTeam(); // read before the mate starts game 1 with colours swapped
        rookMate(0, address(0xA11CE), 1e30);
        assertEq(hook.owed(address(0xA11CE), teamToken(1 - w).toId()), 25e18, "a quarter of 100, in the loser's token");
        assertEq(hook.chest(id, 1 - w), 75e18, "taken from the loser's pot");
        assertEq(hook.chest(id, w), 100e18, "the winner's pot is untouched");
        assertEq(claimed(address(0xA11CE), teamToken(1 - w)), 25e18 - 1, "claimed, but for the 1 wei kept owed");
        assertEq(hook.owed(address(0xA11CE), teamToken(1 - w).toId()), 1);
        assertSolvent(alice());
    }

    function alice() internal pure returns (address[] memory who) {
        who = new address[](1);
        who[0] = address(0xA11CE);
    }

    function test_theMateIsCappedAtTwiceWhatItsTradePaid() public {
        fund();
        uint256 w = whiteTeam();
        rookMate(0, address(0xA11CE), 1e18); // the mating move's trade paid 1 token: it earns at most 2
        assertEq(hook.owed(address(0xA11CE), teamToken(1 - w).toId()), 2e18, "capped");
        assertEq(hook.chest(id, 1 - w), 98e18, "the rest stays in the pot");
        assertSolvent(alice());
    }

    /// A mate played for nobody (a timeout move) pays nobody: the pot keeps it all.
    function test_aMateForNobodyPaysNobody() public {
        fund();
        uint256 w = whiteTeam();
        vm.recordLogs();
        rookMate(0, address(0), 0);
        assertEq(hook.chest(id, 1 - w), 100e18, "nothing leaves the loser's pot");
        assertEq(hook.chest(id, w), 100e18);
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 0);
    }

    function test_theMateIsCountedForItsOwner() public {
        fund();
        uint256 w = whiteTeam();
        address a = address(0xA11CE);
        vm.recordLogs();
        rookMate(0, a, 1e30);
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 1);
        (, uint256 rare) = hook.stats(a);
        assertEq(rare & 0xffff, 1, "one mating move");
        // the amount won in units of 10^15 wei, in the loser's token: IMD (currency0) at bit 140, $IMDUEL at 180
        assertEq((rare >> (1 - w == 0 ? 140 : 180)) & ((1 << 40) - 1), 25_000, "25 tokens won");
    }

    function test_quietMovesPayNothing() public {
        fund();
        hook.applyMove(pool, mv("e2", "e4"), address(0xA11CE), 1e30);
        assertEq(hook.owed(address(0xA11CE), currency0.toId()) + hook.owed(address(0xA11CE), currency1.toId()), 0);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_feesCannotBeWithdrawnByAnyone() public {
        trade(1, 1e18, address(0));
        uint256 before = claims(currency0);
        vm.prank(address(0xDEAD));
        hook.withdraw(address(0xFEE), currency0);
        assertEq(currency0.balanceOf(address(0xFEE)), 0);
        assertEq(claims(currency0), before);
        assertSolvent(nobody());
    }

    /// A reward is recorded, never sent inside the trade: an owner that can't receive it (here a contract refusing
    /// ETH) costs the trade nothing, and the owner claims it once it can.
    function test_rewardsAreClaimedNeverPushed() public {
        // a native ETH pool: White (ETH's team) is paid in ETH, to a contract that refuses ETH
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(pool, ModifyLiquidityParams(-887220, 887220, 100e18, 0), "");
        hook.fundChest{value: 100 ether}(pool, false, 100 ether);
        address refuser = address(new RefusesEth());
        vm.recordLogs();
        // the mating team wins the loser's ETH: White mates if White is currency1's team, else Black does
        if (whiteTeam() == 1) {
            rookMate(0, refuser, 1e30);
        } else {
            uint256 b;
            b = put(b, "g8", 14);
            b = put(b, "a8", 12);
            b = put(b, "h1", 6);
            b = put(b, "f2", 1);
            b = put(b, "g2", 1);
            b = put(b, "h2", 1);
            hook.setGameIn(id, WELL_TRADED, WELL_TRADED);
            hook.setPosition(id, b, side("h1"), side("g8"), 1, 0);
            hook.applyMove(pool, mv("a8", "a1"), refuser, 1e30);
        }
        next(12);
        swapNativeInput(pool, true, -int256(TINY), "", TINY); // trading goes on
        assertEq(hook.owed(refuser, 0), 25 ether, "recorded: a quarter of the ETH pot");
        assertEq(refuser.balance, 0);
        assertEq(count(vm.getRecordedLogs(), MATE_PAID), 1);
        vm.expectRevert(); // it can't take ETH yet
        hook.withdraw(refuser, CurrencyLibrary.ADDRESS_ZERO);
        RefusesEth(payable(refuser)).acceptEth();
        vm.prank(address(0xDEAD)); // anyone may retry; only the reward owner receives it
        hook.withdraw(refuser, CurrencyLibrary.ADDRESS_ZERO);
        assertEq(refuser.balance, 25 ether - 1);
        assertEq(hook.owed(refuser, 0), 1, "1 wei stays owed");
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), hook.chest(id, 0) + 1);
    }

    // ---------------------------------------------------------------- funding a chest

    function test_fundChestWithTokens() public {
        hook.fundChest(pool, true, 100e18);
        assertEq(hook.chest(id, 1), 100e18);
        assertSolvent(nobody());
    }

    function test_fundChestWithEth() public {
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 10 ether);
        hook.fundChest{value: 5 ether}(pool, false, 5 ether);
        assertEq(hook.chest(id, 0), 5 ether);
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), 5 ether);
    }

    function test_fundChestNeedsTheRightValue() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest{value: 1 ether}(pool, false, 1 ether); // currency0 is a token: no ETH allowed
    }

    /// Both chests of a pool share one slot, 128 bits each: a full chest refuses funding and skips its fee share.
    function test_aFullChestTakesNoMore() public {
        uint256 full = type(uint128).max;
        MockERC20(Currency.unwrap(currency0)).mint(address(this), full);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), full);
        uint256 half = uint128(type(int128).max); // the PoolManager settles at most this much at once
        for (uint256 i; i < 2; i++) {
            hook.fundChest(pool, i == 1, half);
            hook.fundChest(pool, i == 1, half);
            hook.fundChest(pool, i == 1, 1);
        }
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest(pool, false, 1);
        trade(1, 1e18, address(0)); // buys currency1, whose pot is full
        assertEq(hook.chest(id, 0), full);
        assertEq(hook.chest(id, 1), full);
        assertGt(hook.owed(DEAD, currency1.toId()), 0, "the burn half of the slice is still taken");
        assertEq(claims(currency1), full + hook.owed(DEAD, currency1.toId()), "nothing else");
        assertSolvent(nobody());
    }

    function test_fundChestOnlyForHookPools() public {
        PoolKey memory other = pool;
        other.fee = 500;
        other.tickSpacing = 10; // never initialized
        vm.expectRevert(IMDuelHook.NotLive.selector);
        hook.fundChest(other, false, 1e18);
    }

    // ---------------------------------------------------------------- solvency

    /// Random trading with real engine moves (mates pay out along the way): held always equals owed.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_heldEqualsOwed(uint256 seed) public {
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
}
