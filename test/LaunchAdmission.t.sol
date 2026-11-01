// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {V4Fixture} from "./V4Fixture.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {LaunchPolicy} from "../script/LaunchPolicy.sol";

/// The hook built the way the IMD launch's own admission floor builds it (hook job f7f2a606, 2026-10-29): on a blank
/// chain holding only a PoolManager and stand-in code at IMD, from launch/hook.json's arguments as given, by CREATE2
/// at a mined salt. The engine address has no code there, no history contract exists, and the token can sort either
/// side of IMD. Then what the floor checks: the callbacks refuse outsiders, nothing can be delegated or destroyed,
/// the factory's pool opens as the main duel, and trades go through (a move waits for the engine; its window's hash
/// is gone after 256 blocks and the turn times out). Run on every export: a hook that only deploys where the engine
/// already exists fails here, not in a paid launch.
contract LaunchAdmissionTest is V4Fixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7; // IMD on Ethereum
    address constant ENGINE = 0xc21788F704a8b9456f7391A01d8a3D95Be215a27; // ChessEngineV5, launch 2643
    address constant DEAD = 0x000000000000000000000000000000000000dEaD; // where the $IMDUEL burn is owed
    Currency imd = Currency.wrap(IMD);
    IMDuelHook hook;
    PoolKey key;
    Currency token;

    function setUp() public {
        deployV4();
        vm.etch(IMD, address(mockToken("IMD", "IMD")).code);
        assertEq(ENGINE.code.length, 0, "a blank chain: no engine");
    }

    /// The production hook from launch/hook.json by CREATE2, as the launch factory deploys it.
    function deployFromManifest() internal returns (IMDuelHook) {
        bytes memory args = LaunchPolicy.hookArgs(vm, vm.readFile("./launch/hook.json"), address(manager), ENGINE);
        bytes memory code = abi.encodePacked(type(IMDuelHook).creationCode, args);
        bytes32 h = keccak256(code);
        uint256 salt;
        while (uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))) & Hooks.ALL_HOOK_MASK
            != IMDUEL_HOOK_FLAGS) salt++;
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 32), mload(code), salt)
        }
        assertTrue(at != address(0), "the hook deploys on a blank chain, without the engine's code");
        return IMDuelHook(at);
    }

    /// The runtime code holds no DELEGATECALL, CALLCODE or SELFDESTRUCT (push data skipped).
    function assertNoEscape(bytes memory code) internal pure {
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff, "an escape opcode");
        }
    }

    function buy(uint256 imdIn) internal {
        swap(key, imd == key.currency0, -int256(imdIn), "");
    }

    function sell(uint256 tokensIn) internal {
        swap(key, token == key.currency0, -int256(tokensIn), "");
    }

    function run(address tokenAt) internal {
        vm.etch(tokenAt, IMD.code);
        token = Currency.wrap(tokenAt);
        hook = deployFromManifest();
        assertNoEscape(address(hook).code);
        assertEq(address(hook.engine()), ENGINE);
        assertEq(Currency.unwrap(hook.imd()), IMD);

        // callbacks refuse outsiders
        SwapParams memory p = SwapParams(true, -1, 0);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.afterInitialize(address(this), key, 0, 0);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.unlockCallback("");

        // the factory's pool: the token with IMD at the policy's price, single-sided seed
        bool tokenIs0 = token < imd;
        (Currency c0, Currency c1) = tokenIs0 ? (token, imd) : (imd, token);
        (uint160 at, int24 lower, int24 upper, uint256 liquidity) = LaunchPolicy.opening(tokenIs0);
        key = PoolKey(c0, c1, LaunchPolicy.FEE, LaunchPolicy.SPACING, IHooks(address(hook)));
        manager.initialize(key, at);
        assertEq(Currency.unwrap(hook.imduel()), tokenAt, "the factory's pool is the main duel");
        MockERC20(tokenAt).mint(address(this), LaunchPolicy.SUPPLY);
        MockERC20(IMD).mint(address(this), 1_000_000e18);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(i == 0 ? IMD : tokenAt);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(liquidity), 0), "");

        // a pool with no route to $IMDUEL can't open; one pairing IMD can
        Currency other = Currency.wrap(address(mockToken("Y", "Y")));
        Currency third = Currency.wrap(address(mockToken("Z", "Z")));
        (Currency a, Currency b) = other < third ? (other, third) : (third, other);
        PoolKey memory noRoute = PoolKey(a, b, 3000, 60, IHooks(address(hook)));
        vm.expectRevert(abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook),
            IHooks.afterInitialize.selector, abi.encodeWithSelector(IMDuelHook.NoRoute.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)));
        manager.initialize(noRoute, SQRT_PRICE_1_1);
        assertFalse(hook.game(noRoute.toId()).live, "a duel without a route to $IMDUEL can't open");
        (a, b) = other < imd ? (other, imd) : (imd, other);
        manager.initialize(PoolKey(a, b, 3000, 60, IHooks(address(hook))), SQRT_PRICE_1_1);

        // trades go through without the engine: the first buy bids, the move waits, the books hold
        buy(50e18);
        IMDuelHook.Game memory g = hook.game(key.toId());
        assertTrue(g.bids[tokenIs0 ? 0 : 1].open, "the first buy owns White's turn");
        for (uint256 i; i < 4; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            if (i % 2 == 0) sell(1_000_000e18);
            else buy(10e18);
        }
        g = hook.game(key.toId());
        assertEq(g.ply, 0, "no engine here: the move waits");
        // no history contract and the window's hash gone: the turn times out and trading goes on
        vm.roll(vm.getBlockNumber() + 300);
        vm.warp(vm.getBlockTimestamp() + 3600);
        buy(10e18);
        sell(1_000_000e18);
        uint256 held = manager.balanceOf(address(hook), c0.toId());
        assertEq(held, hook.chest(key.toId(), 0) + hook.owed(DEAD, c0.toId()), "held = chest + burn (currency0)");
        held = manager.balanceOf(address(hook), c1.toId());
        assertEq(held, hook.chest(key.toId(), 1) + hook.owed(DEAD, c1.toId()), "held = chest + burn (currency1)");
    }

    function test_blankChainTokenBelowImd() public {
        run(address(0x1000000000000000000000000000000000000001));
    }

    function test_blankChainTokenAboveImd() public {
        run(address(0xF000000000000000000000000000000000000001));
    }
}
