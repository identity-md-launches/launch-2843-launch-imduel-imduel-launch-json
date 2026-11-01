// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

/// Random actions against one hook pool. Every action must succeed (fail_on_revert).
contract Handler is Test {
    using CurrencyLibrary for Currency;

    IMDuelHook public hook;
    PoolSwapTest router;
    PoolKey key;
    address[] public owners;
    mapping(address => bool) listed; // every address a reward can be recorded for (the books count them)
    uint256 public swaps;
    uint256 public moves;

    constructor(IMDuelHook hook_, PoolSwapTest router_, PoolKey memory key_) {
        (hook, router, key) = (hook_, router_, key_);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? key.currency0 : key.currency1));
            t.mint(address(this), 1e36);
            t.approve(address(router), type(uint256).max);
            t.approve(address(hook), type(uint256).max);
        }
        _noteOwner(address(0xA));
        _noteOwner(address(0xB));
        _noteOwner(address(0xC));
        _noteOwner(tx.origin);
    }

    function _noteOwner(address who) internal {
        if (!listed[who]) {
            listed[who] = true;
            owners.push(who);
        }
    }

    function ownersLength() external view returns (uint256) {
        return owners.length;
    }

    function trade(bool zeroForOne, uint256 size, uint8 owner, bool exactOut) external {
        size = bound(size, 1e12, 20e18);
        uint16 plyBefore = hook.game(key.toId()).ply;
        bytes memory data = owner % 5 == 4 ? bytes("") : abi.encodePacked(owners[owner % 3]);
        if (owner % 5 == 4) _noteOwner(tx.origin); // the owner of a trade naming none: here the random sender
        router.swap(
            key,
            SwapParams(zeroForOne, exactOut ? int256(size) : -int256(size), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
        swaps++;
        if (hook.game(key.toId()).ply != plyBefore) moves++;
    }

    /// Same as `trade`, listed again so trading is picked more often than the other actions.
    function tradeAgain(bool zeroForOne, uint256 size, uint8 owner) external {
        this.trade(zeroForOne, size, owner, false);
    }

    function tradeNextBlock(bool zeroForOne, uint256 size, uint8 owner) external {
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.roll(vm.getBlockNumber() + 1);
        this.trade(zeroForOne, size, owner, false);
    }

    function nextBlock(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 120));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function longPause() external {
        vm.warp(vm.getBlockTimestamp() + hook.TURN_TIMEOUT() + 1);
        vm.roll(vm.getBlockNumber() + 50);
    }

    function fund(bool inCurrency1, uint256 amount) external {
        hook.fundChest(key, inCurrency1, bound(amount, 1, 50e18));
    }

    function withdrawReward(bool inCurrency1, uint8 owner) external {
        hook.withdraw(owners[owner % owners.length], inCurrency1 ? key.currency1 : key.currency0);
    }

    /// Anyone sends the owed $IMDUEL burn to 0x...dEaD.
    function burn() external {
        hook.withdraw(address(0xdEaD), hook.imduel());
    }

    /// A long silence: past TURN_TIMEOUT and the 256 blocks BLOCKHASH serves (no history contract here), so timeouts
    /// and expired windows happen in every run.
    function idle() external {
        vm.warp(vm.getBlockTimestamp() + 3_600);
        vm.roll(vm.getBlockNumber() + 300);
    }
}

/// The main duel under random actions: every action succeeds, the books balance and the board stays sound.
contract InvariantTest is Base {
    using CurrencyLibrary for Currency;

    Handler handler;

    function setUp() public {
        deployV4();
        deployMintAndApprove2Currencies();
        deployHook(config(v5(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        handler = new Handler(hook, swapRouter, pool);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_heldEqualsOwed() public view {
        address[] memory who = new address[](handler.ownersLength());
        for (uint256 j; j < who.length; j++) who[j] = handler.owners(j);
        assertSolvent(who);
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boardHasBothKingsAndPlyIsBounded() public view {
        IMDuelHook.Game memory g = hook.game(id);
        uint256 wk;
        uint256 bk;
        for (uint256 s; s < 64; s++) {
            uint256 p = (g.board >> (s << 2)) & 0xF;
            if (p == 6) wk++;
            if (p == 14) bk++;
        }
        assertEq(wk, 1, "one white king");
        assertEq(bk, 1, "one black king");
        assertLt(g.ply, hook.MAX_PLY());
    }

    function afterInvariant() external {
        emit log_named_uint("swaps", handler.swaps());
        emit log_named_uint("moves", handler.moves());
    }
}
