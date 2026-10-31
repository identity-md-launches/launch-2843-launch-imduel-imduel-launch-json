// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

/// The protocol slice: 0.1% of every swap in every pool, converted into $IMDUEL in batches, half to the main duel's
/// $IMDUEL chest and half burned.
contract SliceTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    bytes32 constant CONVERTED = keccak256("Converted(address,uint256,uint256,uint256)");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant MIN = 1e15;

    Currency imd;
    Currency duel;
    Currency x; // some other token
    PoolKey main;

    function token(string memory name) internal returns (Currency c) {
        MockERC20 t = mockToken(name, name);
        t.mint(address(this), 1e36);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        c = Currency.wrap(address(t));
    }

    function sorted(Currency a, Currency b) internal pure returns (Currency, Currency) {
        return a < b ? (a, b) : (b, a);
    }

    function newPool(Currency a, Currency b) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = sorted(a, b);
        (k,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(k);
    }

    /// The hook and the main duel, with deep liquidity unless `shallow`.
    function deploy(bool shallow) internal {
        deployV4();
        (imd, duel, x) = (token("IMD"), token("IMDUEL"), token("X"));
        HookConfig memory c = config(v5(), imd);
        (c.minImd, c.minImduel) = (MIN, MIN);
        deployHook(c);
        if (shallow) {
            (Currency c0, Currency c1) = sorted(imd, duel);
            (main,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        } else {
            main = newPool(imd, duel);
            sampleBlocks(main);
        }
        (pool, id) = (main, main.toId());
    }

    function setUp() public {
        deploy(false);
    }

    function pay(PoolKey memory k, Currency input, uint256 amount) internal {
        swap(k, input == k.currency0, -int256(amount), "");
    }

    function mainChest() internal view returns (uint256) {
        return hook.chest(hook.mainId(), duel < imd ? 0 : 1);
    }

    function burned() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(duel)).balanceOf(DEAD);
    }

    function converted(Vm.Log[] memory logs) internal pure returns (uint256 spent, uint256 bought, uint256 burnt) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == CONVERTED) (spent, bought, burnt) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
    }

    function test_mainDuelSliceBuysImduelHalfToTheChestHalfBurned() public {
        vm.recordLogs();
        pay(main, imd, 10e18); // slice 0.01e18 of IMD, over the batch minimum: converted inside this trade
        (uint256 spent, uint256 bought, uint256 burnt) = converted(vm.getRecordedLogs());
        assertEq(spent, 0.01e18, "the whole pile");
        assertGt(bought, 0);
        assertEq(burnt, bought / 2);
        assertEq(burned(), burnt, "burned at the dead address");
        assertGe(mainChest(), bought - burnt, "the other half joins the main $IMDUEL chest");
        assertEq(hook.pile(imd.toId()), 0);
        assertSolvent(nobody());
    }

    function test_otherDuelsFeedTheMainChest() public {
        PoolKey memory duelX = newPool(x, imd); // a community duel against IMD
        uint256 chestBefore = mainChest();
        pay(duelX, x, 10e18); // its slice is in IMD (here the output side)
        pay(duelX, imd, 10e18);
        assertGt(mainChest(), chestBefore, "the main $IMDUEL chest grew");
        assertGt(burned(), 0);
        assertGt(hook.chest(duelX.toId(), 0) + hook.chest(duelX.toId(), 1), 0, "the duel keeps its 0.65%");
    }

    function test_imduelDuelsNeedNoSwap() public {
        PoolKey memory duelX = newPool(x, duel);
        vm.recordLogs();
        pay(duelX, duel, 10e18); // slice 0.01e18 of $IMDUEL
        (uint256 spent, uint256 bought, uint256 burnt) = converted(vm.getRecordedLogs());
        assertEq(spent, 0.01e18);
        assertEq(bought, spent, "no swap");
        assertEq(burnt, 0.005e18);
        assertEq(burned(), 0.005e18);
    }

    function test_aBatchStopsAtItsPriceLimit() public {
        // a shallow main duel and a deep community duel: the pile outgrows what one batch may buy
        deployV4();
        (imd, duel, x) = (token("IMD"), token("IMDUEL"), token("X"));
        HookConfig memory c = config(v5(), imd);
        (c.minImd, c.minImduel) = (0.1e18, MIN); // a batch of up to 1 IMD: the band limits it, not the cap
        deployHook(c);
        (Currency c0, Currency c1) = sorted(imd, duel);
        (main,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(main, ModifyLiquidityParams(-887220, 887220, 10e18, 0), "");
        sampleBlocks(main);
        PoolKey memory duelX = newPool(x, imd);
        (uint160 before,,,) = manager.getSlot0(main.toId());
        pay(duelX, imd, 1_000e18); // slice 1e18 of IMD; the main duel is 10e18 deep
        uint256 left = hook.pile(imd.toId());
        assertGt(left, 0.9e18, "most of the pile waits for later batches");
        assertLt(left, 1e18, "one batch was bought");
        (uint160 sqrtAfter,,,) = manager.getSlot0(main.toId());
        uint256 moved = sqrtAfter > before ? sqrtAfter - before : before - sqrtAfter;
        assertLe(moved * 10_000 / before, 10, "within 0.1% of the sqrt price");
    }

    /// A sandwich with the attacker's own liquidity. The batch limit is a price band, so the hook buys whatever
    /// liquidity sits in that band: an attacker places a narrow $IMDUEL band just past a price it pushes to, the batch
    /// buys from that band at the pushed price, and the attacker takes the band back and pushes the price home.
    function test_aBatchCannotBeSoldAtAPushedPrice() public {
        deployV4();
        (imd, duel, x) = (token("IMD"), token("IMDUEL"), token("X"));
        HookConfig memory c = config(v5(), imd);
        (c.minImd, c.minImduel) = (MIN, MIN);
        deployHook(c);
        (Currency c0, Currency c1) = sorted(imd, duel);
        (main,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(main, ModifyLiquidityParams(-887220, 887220, 10e18, 0), "");
        sampleBlocks(main);
        PoolKey memory duelX = newPool(x, imd);
        for (uint256 i; i < 5; i++) pay(duelX, imd, 1_000e18); // a deep community duel piles ~5 IMD
        assertGt(hook.pile(imd.toId()), 4e18);
        next(12);

        address attacker = makeAddr("attacker");
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? imd : duel));
            t.mint(attacker, 1e30);
            vm.startPrank(attacker);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
        }
        uint256 imd0 = imd.balanceOf(attacker);
        uint256 duel0 = duel.balanceOf(attacker);
        bool hookDir = imd == main.currency0; // the batch's direction: IMD in, $IMDUEL out
        (uint160 home,,,) = manager.getSlot0(main.toId());

        vm.startPrank(attacker);
        // the band: one tick spacing past a price 20% (in sqrt) further the hook's way, all $IMDUEL
        int24 t1 = TickMath.getTickAtSqrtPrice(uint160(uint256(home) * (hookDir ? 80 : 125) / 100)) / 60 * 60;
        ModifyLiquidityParams memory band = ModifyLiquidityParams(hookDir ? t1 - 60 : t1, hookDir ? t1 : t1 + 60, 1e22, 0);
        modifyLiquidityRouter.modifyLiquidity(main, band, "");
        // push to the band's edge; this trade's own batch then buys from the band
        pushTo(hookDir, TickMath.getSqrtPriceAtTick(t1));
        band.liquidityDelta = -1e22;
        modifyLiquidityRouter.modifyLiquidity(main, band, "");
        pushTo(!hookDir, home);
        vm.stopPrank();

        (uint160 back,,,) = manager.getSlot0(main.toId());
        assertApproxEqRel(back, home, 2e15, "price is home (the return trade converts a batch too)");
        // the attacker's result in IMD, $IMDUEL valued at the home price
        int256 dImd = int256(imd.balanceOf(attacker)) - int256(imd0);
        int256 dDuel = int256(duel.balanceOf(attacker)) - int256(duel0);
        uint256 duelInImd = FullMath.mulDiv(FullMath.mulDiv(_abs(dDuel), 1 << 96, home), 1 << 96, home);
        if (!hookDir) duelInImd = FullMath.mulDiv(FullMath.mulDiv(_abs(dDuel), home, 1 << 96), home, 1 << 96);
        int256 profit = dImd + (dDuel < 0 ? -int256(duelInImd) : int256(duelInImd));
        emit log_named_int("attacker profit (IMD, 1e18)", profit);
        assertLe(profit, 0, "the sandwich doesn't pay");
    }

    /// Trades the main duel to just short of `target` with the input it needs: a trade its price limit stops early
    /// reverts (PartialFill), so this one swaps all of its input.
    function pushTo(bool zeroForOne, uint160 target) internal {
        (uint160 now_,,,) = manager.getSlot0(main.toId());
        uint128 l = manager.getLiquidity(main.toId());
        uint256 need = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(target, now_, l, true)
            : SqrtPriceMath.getAmount1Delta(now_, target, l, true);
        need = need * 1_000_000 / 997_000 * 1_000_000 / 995_000 * 9_999 / 10_000; // LP fee, hook fee, a hair less
        swapRouter.swap(main, SwapParams(zeroForOne, -int256(need), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false), "");
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return uint256(v < 0 ? -v : v);
    }

    function test_aFailedConversionNeverBreaksATrade() public {
        deploy(true); // the main duel has no liquidity: a batch can't buy anything
        PoolKey memory duelX = newPool(x, imd);
        pay(duelX, imd, 10e18);
        pay(duelX, imd, 10e18);
        assertEq(hook.pile(imd.toId()), 0.02e18, "the slice waits");
        hook.convert(imd); // asked directly: nothing to buy, nothing lost
        assertEq(hook.pile(imd.toId()), 0.02e18);
    }

    /// A duel whose slice couldn't buy $IMDUEL can't open, so no pile waits for good (swarm audit 2026-10-27, finding 4).
    /// There is no native ETH route: an ETH duel pairs IMD or $IMDUEL and its slice is taken in that token.
    function test_noRouteNoDuel() public {
        Currency y = token("Y");
        (Currency c0, Currency c1) = sorted(x, y);
        vm.expectRevert(); // NoRoute, wrapped by the pool manager
        initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.expectRevert(); // ETH against a token: no route either
        initPool(CurrencyLibrary.ADDRESS_ZERO, x, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        newPool(x, imd); // with a routing side it opens
        newPool(x, duel);
        (PoolKey memory ethImd,) = initPool(CurrencyLibrary.ADDRESS_ZERO, imd, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        assertEq(hook.game(ethImd.toId()).slice, 1, "ETH / IMD: the slice in IMD");
    }

    function test_anyoneCanConvert() public {
        pay(main, duel, 0.5e18); // slice 0.5e15 of IMD on the output side: under the minimum
        uint256 waiting = hook.pile(imd.toId());
        assertGt(waiting, 0);
        vm.prank(address(0xC0FFEE));
        hook.convert(imd);
        assertEq(hook.pile(imd.toId()), 0);
        assertGt(burned(), 0);
    }

    function test_booksBalanceAcrossPools() public {
        PoolKey memory duelX = newPool(x, imd);
        PoolKey memory duelY = newPool(x, duel);
        for (uint256 i; i < 6; i++) {
            pay(main, i % 2 == 0 ? imd : duel, 3e18);
            pay(duelX, i % 2 == 0 ? imd : x, 3e18);
            pay(duelY, i % 2 == 0 ? duel : x, 3e18);
            next(12);
        }
        PoolKey[] memory pools = new PoolKey[](3);
        (pools[0], pools[1], pools[2]) = (main, duelX, duelY);
        assertSolvent(imd, pools, nobody());
        assertSolvent(duel, pools, nobody());
        assertSolvent(x, pools, nobody());
    }
}
