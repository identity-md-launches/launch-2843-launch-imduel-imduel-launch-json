// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {Rules} from "../src/Rules.sol";
import {Base} from "./Base.sol";

/// A test wallet calling a router, with a different transaction origin (a bundler).
contract RelayedWallet {
    function trade(PoolSwapTest router, PoolKey memory key, SwapParams memory params, bytes memory hookData) external {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        MockERC20(Currency.unwrap(input)).approve(address(router), uint256(-params.amountSpecified));
        router.swap(key, params, PoolSwapTest.TestSettings(false, false), hookData);
    }
}

contract GasBurningFallback is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        while (true) {}
    }

    function playAny(uint256, uint32, uint32, bool, uint256) external pure returns (uint16, Rules.Played memory) {
        while (true) {}
    }
}

/// Reproductions of the two low-severity findings on the imported hook.
contract AuditRegressionTest is Base {
    address internal relayer;

    function turnBlocks() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public {
        deployV4();
        deployMintAndApprove2Currencies();
        deployHook(config(v5(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 12_500, 60, SQRT_PRICE_1_1);
        addLiquidity(pool);
        relayer = makeAddr("relayer");
    }

    function closeWindow() internal {
        uint256 closing = st().closeBlock;
        vm.roll(closing + 1);
        vm.setBlockhash(closing, keccak256("audit window"));
    }

    function routerCall() internal view returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (pool, SwapParams(true, -1e20, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), bytes(""))
        );
    }

    function test_closedWindowPreservesNotEnoughGasAndCanBeRetried() public {
        bytes memory data = routerCall();
        uint256 snapshot = vm.snapshotState();
        uint256 beforeGas = gasleft();
        (bool ok,) = address(swapRouter).call{gas: 5_000_000}(data);
        uint256 estimate = (beforeGas - gasleft()) * 130 / 100;
        assertTrue(ok);
        vm.revertToState(snapshot);
        (ok,) = address(swapRouter).call{gas: estimate}(data);
        assertTrue(ok, "an estimate from the open window succeeds there");
        closeWindow();

        bytes32 gameBefore = keccak256(abi.encode(st()));
        uint256 chest0 = hook.chest(id, 0);
        uint256 chest1 = hook.chest(id, 1);
        uint256 claims0 = claims(currency0);
        uint256 claims1 = claims(currency1);
        bytes memory reason;
        (ok, reason) = address(swapRouter).call{gas: estimate}(data);
        assertFalse(ok, "the open-window estimate cannot also play the move");
        assertEq(
            reason,
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(IMDuelHook.NotEnoughGas.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            ),
            "the retry signal survives engine starvation"
        );
        assertEq(keccak256(abi.encode(st())), gameBefore, "failed trade leaves the bid and board unchanged");
        assertEq(hook.chest(id, 0), chest0);
        assertEq(hook.chest(id, 1), chest1);
        assertEq(claims(currency0), claims0);
        assertEq(claims(currency1), claims1);

        vm.recordLogs();
        (ok,) = address(swapRouter).call{gas: 6_000_000}(data);
        assertTrue(ok, "retry with the move's gas budget succeeds");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(count(logs, MOVED), 1);
        assertEq(count(logs, FAILED), 0, "the original engine move plays");
        assertEq(st().ply, 1);
        assertSolvent(nobody());
    }

    function test_starvedFallbackPreservesNotEnoughGas() public {
        deployHook(config(new GasBurningFallback(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 12_500, 60, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e20, address(this));
        closeWindow();
        bytes memory data = routerCall();
        // Enough for primary admission, then its entire cap is consumed; the fallback must check its own budget.
        vm.expectCall(address(engine), abi.encodeWithSelector(IChessEngine.play.selector));
        (bool ok, bytes memory reason) = address(swapRouter).call{gas: 4_500_000}(data);
        assertFalse(ok);
        assertEq(
            reason,
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(IMDuelHook.NotEnoughGas.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        assertEq(st().gameNo, 0, "starvation cannot force a draw");
        assertEq(st().ply, 0);
        vm.expectCall(address(engine), abi.encodeWithSelector(IChessEngine.playAny.selector));
        (ok,) = address(swapRouter).call{gas: 6_000_000}(data);
        assertTrue(ok, "a genuine failure with the full cap ends as a draw");
        assertEq(st().gameNo, 1);
        assertEq(st().ply, 0);
        assertEq(hook.owed(address(this), currency0.toId()), 0);
        assertEq(hook.owed(address(this), currency1.toId()), 0);
    }

    function walletMate(uint8 encoding) internal {
        RelayedWallet wallet = new RelayedWallet();
        MockERC20(Currency.unwrap(currency0)).mint(address(wallet), 1e20);
        forcedMate(false);
        bytes memory data = encoding == 20
            ? abi.encodePacked(address(wallet))
            : encoding == 32 ? abi.encode(address(wallet)) : bytes("");
        vm.prank(relayer, relayer);
        wallet.trade(swapRouter, pool, SwapParams(true, -1e20, MIN_PRICE_LIMIT), data);
        address owner = encoding == 0 ? relayer : address(wallet);
        assertEq(st().bids[1].owner, owner);
        closeWindow();
        vm.recordLogs();
        black(1e18, address(this));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(count(logs, MOVED), 1);
        assertEq(count(logs, MATE_PAID), 1);
        assertEq(st().moveOwner, owner);
        uint256 payout = hook.owed(owner, currency0.toId());
        assertGt(payout, 1);
        assertEq(hook.owed(encoding == 0 ? address(wallet) : relayer, currency0.toId()), 0);
        (uint256 moves, uint256 rare) = hook.stats(owner);
        assertGt(moves, 0);
        assertEq(rare & 0xffff, 1, "the mate counts for the same owner");
        assertEq(hook.players(0), owner);
        uint256 balance = MockERC20(Currency.unwrap(currency0)).balanceOf(owner);
        hook.withdraw(owner, currency0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(owner), balance + payout - 1);
        assertEq(hook.owed(owner, currency0.toId()), 1);
    }

    function test_emptyHookDataReproducesAcceptedRelayerAttribution() public {
        walletMate(0);
    }

    function test_packedHookDataKeepsWalletBidStatsAndMatePayout() public {
        walletMate(20);
    }

    function test_abiHookDataKeepsWalletBidStatsAndMatePayout() public {
        walletMate(32);
    }
}
