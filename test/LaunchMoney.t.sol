// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Strength} from "../src/Strength.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

/// The brief's money rules as arithmetic against the production bytecode, in both token orders, every swap shape and
/// through the real swap path: no harness, no setter. The expected values come from the brief, not from the code:
/// 0.325% of each side of the raw swap into that token's pot, 0.1% of the IMDUEL side burned or, without IMDUEL, of
/// the IMD side into the main duel's IMD pot, and a mate paying the least of three amounts.
contract LaunchMoneyTest is LaunchFixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        setUpLaunches();
    }

    function pct(uint256 amount, uint256 num, uint256 den) internal pure returns (uint256) {
        return amount * num / den;
    }

    function abs(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    // ---------------------------------------------------------------- the fee, exactly

    /// Runs one swap of `amount` in pool `k` and checks every wei the hook took against the brief: both pots, the
    /// slice, HookSwap, and what the trader paid and got. `sliceTeam` is the side the slice falls on; `burns` says
    /// whether it is burned, else it goes to the main duel's IMD pot of `l`.
    function checkFee(
        Launched memory l,
        PoolKey memory k,
        uint256 team,
        bool exactOut,
        uint256 amount,
        uint256 sliceTeam,
        bool burns
    ) internal {
        PoolId pid = k.toId();
        bool zeroForOne = buying(team);
        uint256 spec = zeroForOne == !exactOut ? 0 : 1; // the specified side
        Currency c0 = k.currency0;
        Currency c1 = k.currency1;
        uint256[2] memory pots = [l.hook.chest(pid, 0), l.hook.chest(pid, 1)];
        uint256[2] memory bal = [c0.balanceOfSelf(), c1.balanceOfSelf()];
        uint256[2] memory held =
            [manager.balanceOf(address(l.hook), c0.toId()), manager.balanceOf(address(l.hook), c1.toId())];
        uint256 mainImd = l.hook.chest(l.id, l.imdTeam);
        uint256 burned = l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId());

        vm.recordLogs();
        swap(k, zeroForOne, exactOut ? int256(amount) : -int256(amount), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 raw0, int128 raw1) = rawSwap(logs);
        uint256[2] memory raw = [abs(raw0), abs(raw1)];

        uint256 unspecAmount = raw[1 - spec];
        uint256[2] memory base;
        base[spec] = amount; // the order
        base[1 - spec] = unspecAmount; // what the pool did on the other side
        uint256[2] memory toPot = [pct(base[0], 65, 20_000), pct(base[1], 65, 20_000)];
        uint256 slice = pct(base[sliceTeam], 10, 10_000);
        uint256[2] memory fee = [toPot[0], toPot[1]]; // a copy: pots and claims differ by the slice
        fee[sliceTeam] += slice;

        assertEq(l.hook.chest(pid, 0) - pots[0], toPot[0], "pot 0");
        assertEq(l.hook.chest(pid, 1) - pots[1], toPot[1], "pot 1");
        assertEq(manager.balanceOf(address(l.hook), c0.toId()) - held[0], fee[0], "claims in currency0");
        assertEq(manager.balanceOf(address(l.hook), c1.toId()) - held[1], fee[1], "claims in currency1");
        if (burns) {
            assertEq(
                l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId()) - burned,
                slice,
                "the slice is owed to 0x...dEaD"
            );
            // in the main duel the IMD pot is this swap's own pot, which takes its share and no slice
            uint256 own = PoolId.unwrap(pid) == PoolId.unwrap(l.id) ? toPot[l.imdTeam] : 0;
            assertEq(l.hook.chest(l.id, l.imdTeam) - mainImd, own, "and no slice goes to the IMD pot");
        } else {
            assertEq(l.hook.chest(l.id, l.imdTeam) - mainImd, slice, "the slice goes to the main duel's IMD pot");
            assertEq(l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId()), burned, "and nothing is burned");
        }

        // the order is exact: the trader pays or gets exactly what it named, and the fee on the other side comes on top
        uint256 inIdx = zeroForOne ? 0 : 1;
        uint256 outIdx = 1 - inIdx;
        uint256 spent = (inIdx == 0 ? bal[0] - c0.balanceOfSelf() : bal[1] - c1.balanceOfSelf());
        uint256 got = (outIdx == 0 ? c0.balanceOfSelf() - bal[0] : c1.balanceOfSelf() - bal[1]);
        if (exactOut) {
            assertEq(got, amount, "exact output: exactly the order");
            assertEq(raw[outIdx], amount + fee[outIdx], "the pool also paid the output side's fee");
            assertEq(spent, raw[inIdx] + fee[inIdx], "the input side's fee on top of the pool's input");
        } else {
            assertEq(spent, amount, "exact input: exactly the order");
            assertEq(raw[inIdx], amount - fee[inIdx], "the pool swapped the order less its fee");
            assertEq(got, raw[outIdx] - fee[outIdx], "the output side's fee off what the pool paid");
        }

        // URC-2: the hook's delta, negative from the swapper's side, only when it took something, once
        uint256 events = countOf(logs, HOOK_SWAP);
        if (fee[0] + fee[1] == 0) {
            assertEq(events, 0, "no fee, no HookSwap");
        } else {
            assertEq(events, 1, "one HookSwap per swap");
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] != HOOK_SWAP) continue;
                assertEq(logs[i].emitter, address(l.hook));
                assertEq(logs[i].topics[1], PoolId.unwrap(pid));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(swapRouter), "the swap's sender");
                (int128 h0, int128 h1, uint24 pips) = abi.decode(logs[i].data, (int128, int128, uint24));
                assertEq(h0, -int128(uint128(fee[0])));
                assertEq(h1, -int128(uint128(fee[1])));
                assertEq(pips, 7_500, "0.75% in pips");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_mainDuelFeeIsExact(bool tokenIs0, bool buysDuel, bool exactOut, uint256 amount) public {
        Launched memory l = launched(tokenIs0);
        deepen(l);
        amount = bound(amount, 1, buysDuel && !exactOut ? 200e18 : exactOut && !buysDuel ? 50e18 : 1_000_000e18);
        uint256 team = buysDuel ? l.duelTeam : l.imdTeam;
        checkFee(l, l.key, team, exactOut, amount, l.duelTeam, true);
        assertBooks(l, new address[](0));
    }

    /// The same at the launch's own fee with the protocol fee switched on: the swap's whole order still trades, so the
    /// hook's whole-order check never refuses a swap because Uniswap turned its fee on.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_aProtocolFeeChangesNothingForTheHook(
        bool tokenIs0,
        bool buysDuel,
        bool exactOut,
        uint256 amount,
        uint16 protocolFee
    ) public {
        Launched memory l = launched(tokenIs0);
        deepen(l);
        protocolFee = uint16(bound(protocolFee, 1, 1_000));
        vm.prank(feeController);
        manager.setProtocolFee(l.key, uint24(protocolFee) << 12 | protocolFee);
        amount = bound(amount, 1e6, buysDuel && !exactOut ? 200e18 : exactOut && !buysDuel ? 50e18 : 1_000_000e18);
        checkFee(l, l.key, buysDuel ? l.duelTeam : l.imdTeam, exactOut, amount, l.duelTeam, true);
    }

    /// A duel without IMDUEL takes its slice in IMD, into the main duel's IMD pot, whichever way the tokens sort and
    /// whichever way the trade goes. A duel with IMDUEL burns it.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sideDuelSlicesGoWhereTheBriefSays(
        bool tokenIs0,
        bool withDuel,
        bool buysOther,
        bool exactOut,
        uint256 amount
    ) public {
        Launched memory l = launched(tokenIs0);
        MockERC20 x = mockToken("X", "X");
        x.mint(address(this), 1e36);
        x.approve(address(swapRouter), type(uint256).max);
        x.approve(address(modifyLiquidityRouter), type(uint256).max);
        Currency xc = Currency.wrap(address(x));
        Currency partner = withDuel ? Currency.wrap(address(l.token)) : imd;
        (Currency c0, Currency c1) = xc < partner ? (xc, partner) : (partner, xc);
        if (withDuel) l.token.approve(address(modifyLiquidityRouter), type(uint256).max);
        (PoolKey memory side,) = initPool(c0, c1, IHooks(address(l.hook)), 3000, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(side, ModifyLiquidityParams(-887220, 887220, 1e23, 0), "");
        uint256 partnerTeam = partner == c0 ? 0 : 1;
        amount = bound(amount, 1, 100e18);
        checkFee(l, side, buysOther ? 1 - partnerTeam : partnerTeam, exactOut, amount, partnerTeam, withDuel);
        assertEq(l.hook.game(side.toId()).main, false, "a side duel is not the main duel");
        assertEq(PoolId.unwrap(l.hook.mainId()), PoolId.unwrap(l.id), "the main duel stays the first");
    }

    /// Dust whose every share rounds to zero costs nothing, says nothing, and still trades.
    function test_dustPaysNoFeeAndEmitsNothing() public {
        Launched memory l = below;
        deepen(l);
        (uint256 p0, uint256 p1) = (l.hook.chest(l.id, 0), l.hook.chest(l.id, 1));
        uint256 burned = l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId());
        vm.recordLogs();
        swap(l.key, buying(l.imdTeam), -int256(100), ""); // buys IMD with 100 wei of IMDUEL
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countOf(logs, HOOK_SWAP), 0);
        assertEq(l.hook.chest(l.id, 0), p0);
        assertEq(l.hook.chest(l.id, 1), p1);
        assertEq(l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId()), burned);
    }

    /// The fee rounds down, at each share's own edge: 307 wei pays no pot share and 308 pays one wei; 999 wei pays no
    /// slice and 1,000 pays one wei.
    function test_theFeeRoundsDownAtItsEdges() public {
        Launched memory l = below;
        deepen(l);
        uint256 burned = l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId());
        uint256 pot = l.hook.chest(l.id, l.duelTeam);
        swap(l.key, !buying(l.duelTeam), -int256(307), ""); // sells 307 wei IMDUEL for IMD
        assertEq(l.hook.chest(l.id, l.duelTeam), pot, "307 * 65 / 20,000 rounds to 0");
        swap(l.key, !buying(l.duelTeam), -int256(308), "");
        assertEq(l.hook.chest(l.id, l.duelTeam), pot + 1, "308 * 65 / 20,000 is 1");
        assertEq(l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId()), burned, "under 1,000 wei no slice");
        swap(l.key, !buying(l.duelTeam), -int256(999), "");
        assertEq(l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId()), burned, "999 wei: still none");
        swap(l.key, !buying(l.duelTeam), -int256(1_000), "");
        assertEq(l.hook.owed(DEAD, Currency.wrap(address(l.token)).toId()), burned + 1, "1,000 wei: 1 wei");
    }

    // ---------------------------------------------------------------- pots at their limit

    /// A full pot takes no more, and the trade still goes through, charged only what fit: the books stay exact, the
    /// other side's fee is untouched and HookSwap reports what was really taken.
    function test_aFullPotIsNotChargedAndTheTradeGoesOn() public {
        Launched memory l = above;
        MockERC20 x = mockToken("X", "X");
        x.mint(address(this), type(uint256).max);
        x.approve(address(swapRouter), type(uint256).max);
        x.approve(address(modifyLiquidityRouter), type(uint256).max);
        x.approve(address(l.hook), type(uint256).max);
        Currency xc = Currency.wrap(address(x));
        (Currency c0, Currency c1) = xc < imd ? (xc, imd) : (imd, xc);
        (PoolKey memory side, PoolId sid) = initPool(c0, c1, IHooks(address(l.hook)), 3000, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(side, ModifyLiquidityParams(-887220, 887220, 1e23, 0), "");
        uint256 xTeam = xc == c0 ? 0 : 1;
        // a mint takes at most 2^127 - 1 at once: two fill it to 2^128 - 2, and one wei more to the brim
        l.hook.fundChest(side, xTeam == 1, uint256(type(uint128).max) >> 1);
        l.hook.fundChest(side, xTeam == 1, uint256(type(uint128).max) >> 1);
        l.hook.fundChest(side, xTeam == 1, 1);
        assertEq(l.hook.chest(sid, xTeam), type(uint128).max, "full");
        vm.expectRevert(IMDuelHook.BadValue.selector);
        l.hook.fundChest(side, xTeam == 1, 1);

        (uint256 in0, uint256 in1) = l.hook.gameInflow(sid, 0);
        assertEq(in0 + in1, 0, "donations are no inflow");
        uint256 xClaims = manager.balanceOf(address(l.hook), xc.toId());
        vm.recordLogs();
        swap(side, buying(xTeam), -int256(1e18), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(l.hook.chest(sid, xTeam), type(uint128).max, "still full");
        assertEq(manager.balanceOf(address(l.hook), xc.toId()), xClaims, "nothing taken in X");
        assertEq(countOf(logs, HOOK_SWAP), 1, "the IMD side was charged");
        assertEq(l.hook.chest(sid, 1 - xTeam), 1e18 * 65 / 20_000, "its pot share");
        (in0, in1) = l.hook.gameInflow(sid, 0);
        assertEq(xTeam == 0 ? in0 : in1, 0, "what didn't enter the pot is no inflow");
        assertEq(xTeam == 0 ? in1 : in0, 1e18 * 65 / 20_000);
    }

    /// The slice into a nearly full main IMD pot takes only what fits and the swap's fee shrinks with it.
    function test_aSliceIntoAFullMainPotTakesWhatFits() public {
        Launched memory l = below;
        MockERC20(IMD).mint(address(this), type(uint256).max - MockERC20(IMD).totalSupply());
        MockERC20 x = mockToken("X", "X");
        x.mint(address(this), 1e36);
        x.approve(address(swapRouter), type(uint256).max);
        x.approve(address(modifyLiquidityRouter), type(uint256).max);
        Currency xc = Currency.wrap(address(x));
        (Currency c0, Currency c1) = xc < imd ? (xc, imd) : (imd, xc);
        (PoolKey memory side, PoolId sid) = initPool(c0, c1, IHooks(address(l.hook)), 3000, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(side, ModifyLiquidityParams(-887220, 887220, 1e23, 0), "");
        uint256 room = 5;
        l.hook.fundChest(l.key, l.imdTeam == 1, uint256(type(uint128).max) >> 1);
        l.hook.fundChest(l.key, l.imdTeam == 1, (uint256(type(uint128).max) >> 1) + 1 - room);
        assertEq(type(uint128).max - l.hook.chest(l.id, l.imdTeam), room);
        uint256 held = manager.balanceOf(address(l.hook), imd.toId());
        uint256 imdTeamHere = imd == c0 ? 0 : 1;
        swap(side, !buying(imdTeamHere), -int256(1e18), ""); // pays 1 IMD in: its slice is 1e15
        assertEq(l.hook.chest(l.id, l.imdTeam), type(uint128).max, "the pot filled to the brim");
        assertEq(l.hook.chest(sid, imdTeamHere), 1e18 * 65 / 20_000, "the side pot's own share is untouched");
        assertEq(
            manager.balanceOf(address(l.hook), imd.toId()) - held, 1e18 * 65 / 20_000 + room, "only what fit was taken"
        );
    }

    // ---------------------------------------------------------------- the mate

    /// Plays one mate by team `winner`'s bid through the real path and checks the payout against the brief: the least
    /// of a quarter of the loser's pot (as it stands when the move is played), twice the bid's payment and what the
    /// game's trades paid into the loser's pot, in the loser's token; the rest stays. `settle` is the size of the trade
    /// that plays the move, whose own fee feeds the pot but counts for the next game.
    function mateAndCheck(Launched memory l, address owner, uint256 settle) internal returns (uint256 amount) {
        IMDuelHook.Game memory g = st(l);
        uint256 winner = moverOf(g);
        uint256 loser = 1 - winner;
        IMDuelHook.TopBid memory b = g.bids[winner];
        assertTrue(b.open, "a bid is waiting");
        assertEq(b.owner, owner);
        (uint256 in0, uint256 in1) = l.hook.gameInflow(l.id, g.gameNo);
        uint256 inflow = loser == 0 ? in0 : in1;
        Currency c = cur(l, loser);
        uint256 owed0 = l.hook.owed(owner, c.toId());
        uint256 owedOther = l.hook.owed(owner, cur(l, winner).toId());
        script.script(2, true, false);
        closeWindow(l);
        vm.recordLogs();
        swap(l.key, buying(loser), -int256(settle), ""); // any trade plays it: here one buying the loser
        script.script(0, false, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countOf(logs, GAME_OVER), 1, "the mate ended the game");
        assertEq(st(l).gameNo, g.gameNo + 1);
        assertEq(st(l).ply, 0);
        uint256 potAfter = l.hook.chest(l.id, loser);
        (bool seen, address to, Currency paidIn, uint256 paid) = matePaid(logs);
        uint256 potWhenPlayed = potAfter + paid;
        uint256 expected = potWhenPlayed / 4;
        if (uint256(b.size) * 2 < expected) expected = uint256(b.size) * 2;
        if (inflow < expected) expected = inflow;
        amount = expected;
        assertEq(paid, expected, "the least of the three");
        assertEq(seen, expected != 0, "MatePaid only for a real payment");
        assertEq(l.hook.owed(owner, c.toId()), owed0 + expected, "recorded for the move's owner");
        assertEq(l.hook.owed(owner, cur(l, winner).toId()), owedOther, "nothing in the winner's token");
        if (seen) {
            assertEq(to, owner);
            assertTrue(paidIn == c, "in the loser's token");
        }
    }

    /// On a fresh game the pot is only the game's own fees, so the quarter is the least of the three. The reward is
    /// recorded: the owner's balance moves by no wei inside the trade that mated.
    function test_aQuarterOfThePotBindsOnAFreshGame() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            buyDuel(l, 100e18, ALICE); // White's bid: the buy feeds both pots
            uint256 balance = MockERC20(IMD).balanceOf(ALICE);
            uint256 paid = mateAndCheck(l, ALICE, 1e15);
            (uint256 potWhenPlayed) = l.hook.chest(l.id, l.imdTeam) + paid;
            assertEq(paid, potWhenPlayed / 4, "the quarter is the least here");
            assertEq(MockERC20(IMD).balanceOf(ALICE), balance, "recorded, not sent");
            address[] memory who = new address[](1);
            who[0] = ALICE;
            assertBooks(l, who);
        }
    }

    /// A dust bid mates a well-funded, well-traded pot: twice the bid, and no more.
    function test_twiceTheBidBinds() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            addFullRange(l, 1e23); // IMD to sell for: the launch's own seed holds none yet
            buyDuel(l, 1e12, ALICE); // the mating bid, dust
            uint256 size = st(l).bids[l.duelTeam].size;
            buy(l, l.imdTeam, 1e25, abi.encodePacked(BOB)); // the other team trades big: both pots fill
            uint256 paid = mateAndCheck(l, ALICE, 1e15);
            assertEq(paid, size * 2, "twice what the bid paid");
        }
    }

    /// Donations fill the pot but never the cap: a mate takes only what the game's trades put in.
    function test_theGamesInflowBinds() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            l.hook.fundChest(l.key, l.imdTeam == 1, 1_000_000e18);
            buyDuel(l, 100e18, ALICE);
            (uint256 in0, uint256 in1) = l.hook.gameInflow(l.id, 0);
            uint256 inflow = l.imdTeam == 0 ? in0 : in1;
            assertEq(inflow, 100e18 * 65 / 20_000, "the bid's own half of the pot fee");
            uint256 paid = mateAndCheck(l, ALICE, 1e15);
            assertEq(paid, inflow, "the game's inflow is the least here");
            assertGt(l.hook.chest(l.id, l.imdTeam), 900_000e18, "the donation stays in the pot");
        }
    }

    /// Any mix of bid, donation, other team's volume and settling trade, in either order, in either colour.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_theMatePaysTheLeastOfThree(
        bool tokenIs0,
        uint256 bidIn,
        uint256 otherIn,
        uint256 donation,
        uint256 settle,
        bool secondGame
    ) public {
        Launched memory l = launched(tokenIs0);
        deepen(l);
        if (secondGame) {
            // a game is drawn first, so colours swap and the mater is IMD's team (its token is paid in IMDUEL)
            script.script(1, false, false);
            closeWindow(l);
            buy(l, l.duelTeam, 1e15, "");
            script.script(0, false, false);
            assertEq(st(l).gameNo, 1);
        }
        uint256 mater = moverOf(st(l));
        assertEq(mater, secondGame ? l.imdTeam : l.duelTeam);
        donation = bound(donation, 0, 1e24);
        bidIn = bound(bidIn, 1e9, secondGame ? 1e24 : 1e21);
        otherIn = bound(otherIn, 0, secondGame ? 1e21 : 1e24);
        settle = bound(settle, 1, 1e15);
        if (donation != 0) l.hook.fundChest(l.key, (1 - mater) == 1, donation);
        uint256 top = st(l).bids[mater].open ? uint256(st(l).bids[mater].size) : 0;
        buy(l, mater, bidIn + top * 12 / 10, abi.encodePacked(ALICE)); // clears any bid carried from before
        assertEq(st(l).bids[mater].owner, ALICE);
        if (otherIn >= 1e9) buy(l, 1 - mater, otherIn, abi.encodePacked(BOB));
        mateAndCheck(l, ALICE, settle);
    }

    /// The trade that plays the mate feeds the pots first, yet its fee counts for the next game and never for this
    /// game's cap. A pot grown only by that trade pays nothing more.
    function test_theSettlingTradeCountsForTheNextGame() public {
        Launched memory l = above;
        buyDuel(l, 1e12, ALICE);
        (uint256 in0, uint256 in1) = l.hook.gameInflow(l.id, 0);
        uint256 inflow = l.imdTeam == 0 ? in0 : in1;
        assertGt(inflow, 0);
        script.script(2, true, false);
        closeWindow(l);
        swap(l.key, buying(l.duelTeam), -int256(1e21), ""); // a whale's buy plays it, and fattens the IMD pot first
        script.script(0, false, false);
        assertEq(l.hook.owed(ALICE, imd.toId()), inflow, "only the game's own inflow");
        (uint256 next0, uint256 next1) = l.hook.gameInflow(l.id, 1);
        assertGt(next0 + next1, 0, "the whale's fee is the next game's");
        (uint256 old0, uint256 old1) = l.hook.gameInflow(l.id, 0);
        assertEq(old0 + old1, 0, "game 0's slot was started over");
    }

    /// Six mates in a row, three by each team: every payout is in the current loser's token, colours swap each game,
    /// each game's inflow starts over, and owed and the books stay exact.
    function test_sixGamesPayTheRightTokenEachTime() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            deepen(l);
            address[] memory who = new address[](2);
            (who[0], who[1]) = (ALICE, BOB);
            uint256[2] memory won;
            for (uint256 game; game < 6; game++) {
                IMDuelHook.Game memory g = st(l);
                uint256 mater = moverOf(g);
                address owner = game % 2 == 0 ? ALICE : BOB;
                if (g.bids[mater].open && vm.getBlockNumber() > g.closeBlock) {
                    swap(l.key, !buying(mater), -int256(1e9), ""); // settles a carried bid, a plain move
                    g = st(l);
                    mater = moverOf(g);
                }
                uint256 top = g.bids[mater].open ? uint256(g.bids[mater].size) : 0;
                buy(l, mater, (mater == l.imdTeam ? 1e24 : 1e20) + top * 2, abi.encodePacked(owner));
                assertEq(st(l).bids[mater].owner, owner, "a bid that clears the raise owns the move");
                uint256 loser = 1 - mater;
                uint256 before = l.hook.owed(owner, cur(l, loser).toId());
                uint256 paid = mateAndCheck(l, owner, 1e15);
                assertGt(paid, 0, "a traded game pays");
                assertEq(l.hook.owed(owner, cur(l, loser).toId()), before + paid);
                won[loser] += paid;
                assertBooks(l, who);
            }
            assertGt(won[0], 0, "currency0's team lost at least once");
            assertGt(won[1], 0, "currency1's team lost at least once");
            assertEq(st(l).gameNo, 6);
        }
    }

    // ---------------------------------------------------------------- what pays nothing

    /// Captures happen in the random legal play here; checks, a stalemate, too little material and an engine that
    /// fails and falls into a draw are scripted. None of them records a reward for anyone.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_nothingButMatePays(bool tokenIs0, uint8 ending, uint256 seedSize) public {
        Launched memory l = launched(tokenIs0);
        deepen(l);
        ending = uint8(bound(ending, 0, 4));
        seedSize = bound(seedSize, 1e15, 1e19);
        l.hook.fundChest(l.key, false, 1_000e18);
        l.hook.fundChest(l.key, true, 1_000e18);
        if (ending == 0) script.script(0, true, false); // a check
        if (ending == 1) script.script(1, false, false); // stalemate
        if (ending == 2) script.script(0, false, true); // too little material
        if (ending == 3) script.fail(true, true, false, false); // both engine calls fail: a draw
        // ending 4: plain random moves, captures among them
        address[] memory who = new address[](3);
        (who[0], who[1], who[2]) = (ALICE, BOB, tx.origin);
        uint256 draws;
        for (uint256 i; i < 12; i++) {
            IMDuelHook.Game memory g = st(l);
            uint256 t = moverOf(g);
            address owner = i % 2 == 0 ? ALICE : BOB;
            uint256 top = g.bids[t].open ? uint256(g.bids[t].size) * 2 : 0;
            buy(l, t, (t == l.imdTeam ? seedSize * 1e5 : seedSize) + top, abi.encodePacked(owner));
            closeWindow(l);
            vm.recordLogs();
            swap(l.key, !buying(t), -int256(1e9), ""); // plays it
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(countOf(logs, MATE_PAID), 0, "only a mate pays");
            draws += countOf(logs, GAME_OVER);
            for (uint256 j; j < 3; j++) {
                assertEq(l.hook.owed(who[j], l.key.currency0.toId()), 0, "nothing owed in currency0");
                assertEq(l.hook.owed(who[j], l.key.currency1.toId()), 0, "nothing owed in currency1");
            }
        }
        if (ending == 1 || ending == 2 || ending == 3) assertGt(draws, 0, "the games did end");
        assertBooks(l, who);
    }

    /// A timeout move that mates pays nobody, even with a fat pot and a well-traded game, and lists nobody.
    function test_aTimeoutMoveThatMatesPaysNothing() public {
        Launched memory l = above;
        deepen(l);
        closeWindow(l);
        swap(l.key, buying(l.duelTeam), -int256(1e9), ""); // plays the opening bid: Black (IMD's team) to move, unbid
        IMDuelHook.Game memory g = st(l);
        uint256 silent = moverOf(g);
        assertEq(silent, l.imdTeam);
        uint256 players = l.hook.playerCount();
        assertFalse(g.bids[silent].open, "nobody bid for IMD's team");
        vm.warp(uint256(g.turnStart) + l.hook.TURN_TIMEOUT());
        vm.roll(vm.getBlockNumber() + 1);
        buy(l, l.duelTeam, 1e20, abi.encodePacked(ALICE)); // the other team's buy opens the silent side's move at 0%
        g = st(l);
        assertTrue(g.bids[silent].open);
        assertEq(g.bids[silent].owner, address(0));
        assertEq(g.bids[silent].size, 0);
        script.script(2, true, false);
        nextBlock();
        vm.recordLogs();
        swap(l.key, buying(l.duelTeam), -int256(1e9), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countOf(logs, GAME_OVER), 1, "the timeout move mated");
        assertEq(countOf(logs, MATE_PAID), 0);
        assertEq(st(l).moveOwner, address(0));
        assertEq(l.hook.playerCount(), players, "nobody listed for a move of nobody's");
    }

    // ---------------------------------------------------------------- strength

    /// A bid's strength is what it received as a share of its own team's pot. Money in the other team's pot does not
    /// move it, and the same buy against a fatter pot of its own is strictly weaker (down to the floor).
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_strengthReadsItsOwnTeamsPot(bool tokenIs0, uint256 amount, uint256 otherDonation) public {
        Launched memory l = launched(tokenIs0);
        deepen(l);
        amount = bound(amount, 1e21, 1e24); // IMDUEL paid: about 0.1 to 100 IMD against a pot of about 32 IMD
        otherDonation = bound(otherDonation, 1, 1e25);
        uint256 team = l.imdTeam; // its next move's bid: none open
        uint256 snap = vm.snapshotState();
        l.hook.fundChest(l.key, l.duelTeam == 1, otherDonation);
        vm.recordLogs();
        buy(l, team, amount, abi.encodePacked(ALICE));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 a0, int128 a1) = rawSwap(logs);
        uint256 got = team == 0 ? abs(a0) : abs(a1);
        IMDuelHook.TopBid memory b = st(l).bids[team];
        assertEq(b.owner, ALICE);
        assertEq(b.strength, Strength.fromShare(got, l.hook.chest(l.id, team)), "a share of its own team's pot");
        assertGt(b.strength, 0, "a real share");
        assertEq(b.size, team == 0 ? abs(a1) : abs(a0), "the size is what it paid, in the other team's token");
        vm.revertToState(snap);
        buy(l, team, amount, abi.encodePacked(ALICE));
        assertEq(st(l).bids[team].strength, b.strength, "the other team's donation changed nothing");
        vm.revertToState(snap);
        l.hook.fundChest(l.key, l.imdTeam == 1, 1e24);
        buy(l, team, amount, abi.encodePacked(ALICE));
        assertLt(st(l).bids[team].strength, b.strength, "a bigger pot of its own weakens the same buy");
    }

    /// The first trades of a launch face empty pots and play at the cap, in both token orders; a whole pot's worth plays
    /// at 90% however it is bought.
    function test_aLaunchsFirstBidPlaysAtTheCap() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            buyDuel(l, 1e18, ALICE);
            assertEq(st(l).bids[l.duelTeam].strength, 9_000);
        }
    }
}
