// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Base} from "./Base.sol";

/// Any two tokens are two equal teams; native ETH works like any token; pools on one hook keep separate games and
/// chests; each pool's base side (IMD, else $IMDUEL) sets the colours and its slice is taken in $IMDUEL where it has it.
contract TeamsTest is Base {
    using StateLibrary for IPoolManager;

    function setUp() public {
        deployV4();
        deployMintAndApprove2Currencies();
    }

    /// Every duel's slice goes to a main duel pot, so two tokens that are neither IMD nor $IMDUEL can't open a duel
    /// (swarm audit 2026-10-27, finding 4).
    function test_twoPlainTokensCannotDuel() public {
        deployHookAside(v5());
        vm.expectRevert(); // NoRoute, wrapped by the pool manager
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_nativeEthIsATeamLikeAnyToken() public {
        deployHook(config(v5(), currency0));
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1); // the main duel opens first
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(pool, ModifyLiquidityParams(-887220, 887220, 100e18, 0), "");
        swapNativeInput(pool, false, -1e18, "", 0); // pays currency1, buys ETH: ETH's team is White in game 0
        assertTrue(bid().open, "it takes White's turn");
        assertEq(st().slice, 1, "currency1 stands in for $IMDUEL here");
        assertEq(st().base, 1, "and is the base: ETH's team, the token bought, plays White first");
    }

    function test_sliceSide() public {
        deployHook(config(v5(), currency0)); // currency0 = IMD, currency1 = $IMDUEL
        (, PoolId main) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        assertEq(hook.game(main).slice, 1, "the main duel: in $IMDUEL");
        assertEq(hook.game(main).base, 0, "its base: IMD, so $IMDUEL's team plays White first");
        (, PoolId eth) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        assertEq(hook.game(eth).slice, 1, "$IMDUEL before ETH");
        (, PoolId ethImd) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency0, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        assertEq(hook.game(ethImd).slice, 1, "no $IMDUEL: in IMD");
        assertEq(hook.game(ethImd).base, 1);
    }

    /// Anyone may open a dynamic-fee pool with the hook. The hook never sets that fee, so the pool's LP fee stays 0;
    /// the game, the hook fee and the chests work as anywhere else.
    function test_aDynamicFeePoolPlaysWithAZeroLpFee() public {
        deployHook(config(v5(), currency0));
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1); // the main duel first
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        addLiquidity(pool);
        trade(whiteTeam(), 1e18, address(0xA));
        assertTrue(bid().open);
        playTurn();
        assertEq(st().ply, 1);
        assertGt(hook.chest(id, 0) + hook.chest(id, 1), 0);
        (,,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, 0);
    }

    function test_poolsOnOneHookKeepSeparateGamesAndChests() public {
        deployHook(config(v5(), currency0));
        (PoolKey memory a, PoolId ida) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (PoolKey memory b, PoolId idb) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        addLiquidity(a);
        modifyLiquidityRouter.modifyLiquidity(b, ModifyLiquidityParams(-887270, 887270, 1_000_000e18, 0), "");
        swap(a, true, -1e18, ""); // buys currency1 ($IMDUEL): White's turn in game 0
        assertTrue(bidOf(ida).open);
        assertFalse(bidOf(idb).open, "the other pool's game is untouched");
        assertGt(hook.chest(ida, 1), 0, "the bought token's pot");
        assertEq(hook.chest(idb, 1), 0, "and its chest");
        swap(b, true, -1e18, "");
        assertTrue(bidOf(idb).open);
        next(12);
        swap(a, false, -1e18, ""); // plays pool a's turn only
        assertEq(hook.game(ida).ply, 1);
        assertEq(hook.game(idb).ply, 0);
    }
}
