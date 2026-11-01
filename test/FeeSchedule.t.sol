// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

contract RefusesEthUntilAsked {
    bool public accepting;

    function acceptEth() external {
        accepting = true;
    }

    function withdrawTo(IMDuelHook hook, Currency c, address to) external {
        hook.withdrawTo(c, to);
    }

    receive() external payable {
        require(accepting, "refused");
    }
}

/// The fee on exact-output and partial orders (half the 0.65% pot fee from each side, the 0.1% slice in $IMDUEL,
/// burned), and the refusals around pots and owed payouts. Main duel: currency0 = "IMD", currency1 = "$IMDUEL".
contract FeeScheduleTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    /// An exact-output order its price limit would stop short is refused whole (PartialFill), and nothing is paid.
    function test_exactOutputStoppedByItsPriceLimitIsRefused() public {
        uint256 in0 = currency0.balanceOfSelf();
        uint256 out1 = currency1.balanceOfSelf();
        vm.expectRevert(); // PartialFill, wrapped by the pool manager
        swapRouter.swap(
            pool,
            SwapParams(true, 100e18, SQRT_PRICE_1_1 * 99_999 / 100_000),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(currency0.balanceOfSelf(), in0);
        assertEq(currency1.balanceOfSelf(), out1);
        assertEq(claims(currency0) + claims(currency1), 0, "no fee kept");
    }

    /// An exact-output buy of $IMDUEL delivers exactly what was asked; the hook keeps half the pot fee and the slice of
    /// that output on top (the slice burned) and the other half of the pot fee from the IMD input.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_exactOutputDeliversTheOrderAndTakesItsFeeOnTop(uint256 amount) public {
        amount = bound(amount, 1e9, 500e18);
        uint256 out1 = currency1.balanceOfSelf();
        uint256 in0 = currency0.balanceOfSelf();
        swap(pool, true, int256(amount), ""); // exact output of currency1
        assertEq(currency1.balanceOfSelf() - out1, amount, "exactly the order");
        assertEq(hook.owed(DEAD, currency1.toId()), amount * 10 / 10_000, "the slice, burned");
        assertEq(hook.chest(id, 1), amount * 65 / 20_000, "half the pot fee from the output");
        uint256 fee0 = claims(currency0);
        uint256 poolIn = in0 - currency0.balanceOfSelf() - fee0;
        assertEq(fee0, poolIn * 65 / 20_000, "the other half from the pool's input");
        assertSolvent(nobody());
    }

    // ---------------------------------------------------------------- refusals around chests

    function test_fundChestWithoutAllowanceIsRefused() public {
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), 0);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest(pool, true, 1e18);
        assertEq(hook.chest(id, 1), 0);
        assertEq(claims(currency1), 0);
    }

    function test_fundChestBeyondBalanceIsRefused() public {
        address poor = address(0xB0B);
        vm.startPrank(poor);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest(pool, false, 1);
        vm.stopPrank();
        assertEq(hook.chest(id, 0), 0);
    }

    function test_fundChestWithTheWrongEthValueIsRefused() public {
        (PoolKey memory ethPool,) =
            initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 10 ether);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest{value: 1 ether}(ethPool, false, 2 ether);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest{value: 2 ether}(ethPool, false, 1 ether);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        hook.fundChest{value: 1 ether}(ethPool, true, 1 ether); // the token side takes no ETH
        hook.fundChest{value: 1 ether}(ethPool, false, 1 ether);
        assertEq(hook.chest(ethPool.toId(), 0), 1 ether);
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), 1 ether);
    }

    function test_fundChestOfZeroAddsNothing() public {
        hook.fundChest(pool, false, 0);
        assertEq(hook.chest(id, 0), 0);
        assertEq(claims(currency0), 0);
    }

    // ---------------------------------------------------------------- owed payouts

    function test_withdrawWithNothingOwedDoesNothing() public {
        vm.recordLogs();
        hook.withdraw(address(this), currency0);
        hook.withdrawTo(currency1, address(0xBEEF));
        hook.withdraw(address(0), CurrencyLibrary.ADDRESS_ZERO);
        assertEq(vm.getRecordedLogs().length, 0, "no unlock, no transfer, no event");
    }

    /// A reward the recipient could not take stays owed to it alone: nobody else can withdrawTo it, withdraw only
    /// ever sends to the owed party, and the owed party can redirect it with withdrawTo, once.
    function test_owedRewardOnlyEverReachesItsOwner() public {
        (pool, id) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(
            pool, ModifyLiquidityParams(-887220, 887220, 100e18, 0), ""
        );
        hook.fundChest{value: 100 ether}(pool, false, 100 ether);
        RefusesEthUntilAsked refuser = new RefusesEthUntilAsked();
        mateAgainst(0, address(refuser), 1e30); // ETH's team loses: the winner is paid in ETH
        uint256 due = hook.owed(address(refuser), 0);
        assertGt(due, 0, "the refused payout is owed");
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), hook.chest(id, 0) + due, "held = chest + owed");

        // somebody else asks for it to be sent to them: nothing moves
        address thief = address(0x7);
        vm.prank(thief);
        hook.withdrawTo(CurrencyLibrary.ADDRESS_ZERO, thief);
        assertEq(thief.balance, 0);
        assertEq(hook.owed(address(refuser), 0), due);

        // a retry to the refusing owner still fails and keeps it owed
        vm.expectRevert();
        hook.withdraw(address(refuser), CurrencyLibrary.ADDRESS_ZERO);
        assertEq(hook.owed(address(refuser), 0), due);

        // the owner redirects it, once
        address elsewhere = address(0xE15E);
        refuser.withdrawTo(hook, CurrencyLibrary.ADDRESS_ZERO, elsewhere);
        assertEq(elsewhere.balance, due - 1, "all but the 1 wei kept owed");
        assertEq(hook.owed(address(refuser), 0), 1);
        refuser.withdrawTo(hook, CurrencyLibrary.ADDRESS_ZERO, elsewhere);
        assertEq(elsewhere.balance, due - 1, "nothing twice");
        assertEq(claims(CurrencyLibrary.ADDRESS_ZERO), hook.chest(id, 0) + 1, "held = pot + the 1 wei");
    }
}
