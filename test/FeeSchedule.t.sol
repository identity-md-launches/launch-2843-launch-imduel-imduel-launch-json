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

/// The fee split (0.65% to the pot worth less, 0.1% slice, the same from a duel's first trade), the refusals around
/// pots and owed payouts, and the main duel's one-batch-per-block limit.
/// Main duel: currency0 = "IMD", currency1 = "$IMDUEL"; the slice is taken in IMD.
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

    /// An exact-output buy delivers exactly what was asked, and the hook keeps 0.65% of the output side (the pot worth
    /// less, here pot 1 once pot 0 holds something) plus 0.1% of the IMD input.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_exactOutputDeliversTheOrderAndTakesHalfAPercent(uint256 amount) public {
        amount = bound(amount, 1e9, 500e18);
        trade(1, 1e18, address(0)); // pot 0 holds 0.65%: the next pot share goes to pot 1
        next(12);
        uint256 chest1 = hook.chest(id, 1);
        uint256 pile0 = hook.pile(currency0.toId());
        uint256 in0 = currency0.balanceOfSelf();
        uint256 out1 = currency1.balanceOfSelf();
        swap(pool, true, int256(amount), ""); // exact output of currency1
        assertEq(currency1.balanceOfSelf() - out1, amount, "exactly the order");
        assertEq(hook.chest(id, 1) - chest1, amount * 65 / 10_000, "0.65% of the specified output");
        uint256 paid = in0 - currency0.balanceOfSelf();
        uint256 slice = hook.pile(currency0.toId()) - pile0;
        assertEq(slice, (paid - slice) * 10 / 10_000, "0.1% of what the pool took in, on top");
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

    function test_convertWithAnEmptyPileDoesNothing() public {
        vm.recordLogs();
        hook.convert(currency0);
        hook.convert(currency1);
        hook.convert(CurrencyLibrary.ADDRESS_ZERO);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(hook), "the hook emitted nothing");
        }
        assertEq(claims(currency0), 0);
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

    // ---------------------------------------------------------------- one main-duel batch per block

    /// However often convert is asked within one block, the main duel's IMD pile is converted at most once there,
    /// and a batch spends at most ten minimums.
    function test_mainDuelConvertsAtMostOnceAndTenMinimumsPerBlock() public {
        deployV4();
        deployMintAndApprove2Currencies();
        HookConfig memory c = config(v5(), currency0);
        uint256 min = 1e15;
        (c.minImd, c.minImduel) = (min, min);
        deployHook(c);
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        trade(1, 1_000e18, address(0)); // a 1e18 IMD slice, a thousand minimums
        sampleBlocks(pool);
        next(12);
        uint256 before = hook.pile(currency0.toId());
        assertGt(before, 10 * min * 3, "several batches wait");
        hook.convert(currency0);
        uint256 afterFirst = hook.pile(currency0.toId());
        assertEq(before - afterFirst, 10 * min, "one batch of ten minimums");
        for (uint256 i; i < 4; i++) {
            hook.convert(currency0);
        }
        trade(1, 100, address(0)); // a trade in the same block converts nothing more either
        assertEq(hook.pile(currency0.toId()), afterFirst, "no second batch in the block");
        next(12);
        hook.convert(currency0);
        assertEq(hook.pile(currency0.toId()), afterFirst - 10 * min, "the next block runs the next one");
    }

    /// The protocol slice's $IMDUEL is split exactly: half (rounded up) to the main duel's $IMDUEL chest, the rest
    /// burned to 0x...dEaD, and the hook's claims stay equal to what it owes.
    function test_conversionSplitsTheImduelHalfKeptHalfBurned() public {
        deployV4();
        deployMintAndApprove2Currencies();
        HookConfig memory c = config(v5(), currency0);
        (c.minImd, c.minImduel) = (1e15, 1e15);
        deployHook(c);
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        trade(1, 1_000e18, address(0));
        sampleBlocks(pool);
        next(12);
        uint256 chestBefore = hook.chest(id, 1);
        uint256 deadBefore = currency1.balanceOf(address(0xdEaD));
        vm.recordLogs();
        hook.convert(currency0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 converted = keccak256("Converted(address,uint256,uint256,uint256)");
        uint256 bought;
        uint256 burned;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == converted) {
                (, bought, burned) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertGt(bought, 0, "a batch bought $IMDUEL");
        assertEq(burned, bought / 2, "half burned");
        assertEq(currency1.balanceOf(address(0xdEaD)) - deadBefore, burned, "burned to 0x...dEaD");
        assertEq(hook.chest(id, 1) - chestBefore, bought - bought / 2, "the rest to the $IMDUEL chest");
        assertSolvent(nobody());
    }
}
