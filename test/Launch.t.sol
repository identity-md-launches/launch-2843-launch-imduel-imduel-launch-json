// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";
import {LaunchPolicy} from "../script/LaunchPolicy.sol";

/// The main duel opened the way the IMD launch factory opens a hook launch (launch.json; live launch 2406): the hook
/// is deployed, then in the same transaction a fresh 1B-supply token is minted and its pool with IMD opened at fee
/// 12500 and spacing 60, at the policy's price (2,500 IMD for the whole supply), and 80% of the supply
/// (LaunchPolicy.SEED_BPS) is seeded single-sided in the token. $IMDUEL's address can sort either side of IMD's; both are tested.
contract LaunchTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7; // IMD on Ethereum
    uint256 constant SUPPLY = LaunchPolicy.SUPPLY;
    int24 constant EDGE = LaunchPolicy.EDGE;

    Currency imd;
    Currency duel;

    function launch(address tokenAt) internal {
        deployV4();
        MockERC20 code = mockToken("x", "x");
        vm.etch(IMD, address(code).code);
        vm.etch(tokenAt, address(code).code);
        (imd, duel) = (Currency.wrap(IMD), Currency.wrap(tokenAt));
        deployHook(config(v5(), imd));

        MockERC20(tokenAt).mint(address(this), SUPPLY);
        MockERC20(IMD).mint(address(this), 1_000_000e18);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(i == 0 ? IMD : tokenAt);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        bool tokenIs0 = duel < imd;
        (Currency c0, Currency c1) = tokenIs0 ? (duel, imd) : (imd, duel);
        (uint160 at, int24 lower, int24 upper, uint256 liquidity) = LaunchPolicy.opening(tokenIs0);
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), LaunchPolicy.FEE, LaunchPolicy.SPACING, at);
        modifyLiquidityRouter.modifyLiquidity(pool, ModifyLiquidityParams(lower, upper, int256(liquidity), 0), "");
    }

    /// The team to trade for a move every block: if a turn is queued, its trade plays it and bids for the other side.
    function nextTeam() internal view returns (uint256) {
        return bid().open ? 1 - toMove() : toMove();
    }

    /// Buys $IMDUEL with `imdIn` IMD (exact input).
    function buy(uint256 imdIn) internal {
        swap(pool, imd == pool.currency0, -int256(imdIn), "");
    }

    /// Sells `tokensIn` $IMDUEL for IMD (exact input).
    function sell(uint256 tokensIn) internal {
        swap(pool, duel == pool.currency0, -int256(tokensIn), "");
    }

    function runLaunch(address tokenAt) internal {
        launch(tokenAt);
        assertEq(Currency.unwrap(hook.imduel()), tokenAt, "the factory's pool is the main duel");
        assertEq(PoolId.unwrap(hook.mainId()), PoolId.unwrap(id));

        // buyers move first: their first trade takes White's turn, whichever way the addresses sort
        uint256 g0 = gasleft();
        buy(50e18);
        emit log_named_uint("first buy (opens game 0, bids for White)", g0 - gasleft());
        assertEq(bid().owner, tx.origin, "the first buy owns White's turn");

        // the pool now holds IMD: a seller in the next block plays White's move and bids for Black
        next(12);
        sell(1_000_000e18);
        assertEq(st().ply, 1, "White's move is played");
        assertTrue(bid().open && bid().owner == tx.origin, "a sell bids for Black");

        // trading on: every trade's slice is $IMDUEL, all of it owed to the burn
        for (uint256 i; i < 30; i++) {
            next(12);
            if (nextTeam() == (duel == pool.currency0 ? 0 : 1)) buy(100e18);
            else sell(2_000_000e18);
        }
        uint256 owed = hook.owed(DEAD, duel.toId());
        assertGt(owed, 0, "every slice owed to the burn");
        hook.withdraw(DEAD, duel);
        assertEq(MockERC20(Currency.unwrap(duel)).balanceOf(DEAD), owed - 1, "burned by anyone's withdraw");
        assertGt(hook.chest(id, duel == pool.currency0 ? 0 : 1), 0, "the $IMDUEL pot grows");
        assertGt(uint256(st().gameNo) * 200 + st().ply, 20, "a move every block (a game may have ended on the way)");
        assertSolvent(nobody());
    }

    /// The Sepolia shape (hook launches there pair with ETH only), and an ETH-paired mainnet launch: "IMD" is native
    /// ETH, the main duel $IMDUEL / ETH (10 ETH for the supply); the slice is $IMDUEL there too.
    function test_launchPairedWithEth() public {
        deployV4();
        MockERC20 t = mockToken("IMDuel", "IMDUEL");
        (imd, duel) = (CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(t)));
        deployHook(config(v5(), imd));
        t.mint(address(this), SUPPLY);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        int24 open = 184_200; // log1.0001(1e9 tokens / 10 ETH), on the 60 spacing: tokens per ETH
        (pool, id) = initPool(imd, duel, IHooks(address(hook)), 12_500, 60, TickMath.getSqrtPriceAtTick(open));
        uint160 a = TickMath.getSqrtPriceAtTick(-EDGE);
        uint160 b = TickMath.getSqrtPriceAtTick(open);
        uint256 liquidity = FullMath.mulDiv(SUPPLY * LaunchPolicy.SEED_BPS / 10_000, 1 << 96, b - a);
        modifyLiquidityRouter.modifyLiquidity(pool, ModifyLiquidityParams(-EDGE, open, int256(liquidity * 999 / 1000), 0), "");
        assertEq(Currency.unwrap(hook.imduel()), address(t));
        vm.deal(address(this), 100 ether);
        swapNativeInput(pool, true, -0.5 ether, "", 0.5 ether); // buy $IMDUEL with ETH
        assertEq(st().closeBlock, vm.getBlockNumber(), "the first buy takes White's turn");
        for (uint256 i; i < 30; i++) {
            next(12);
            if (nextTeam() == 1) swapNativeInput(pool, true, -0.5 ether, "", 0.5 ether);
            else swap(pool, false, -20_000_000e18, "");
        }
        assertGt(hook.owed(DEAD, duel.toId()), 0, "the $IMDUEL slice, owed to the burn");
        assertEq(hook.chest(id, 0) + hook.chest(id, 1) > 0, true);
        assertGt(st().ply, 20);
        assertSolvent(nobody());
    }

    function test_launchTokenBelowImd() public {
        runLaunch(address(0x1000000000000000000000000000000000000001));
    }

    function test_launchTokenAboveImd() public {
        runLaunch(address(0xF000000000000000000000000000000000000001));
    }
}
