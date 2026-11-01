// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Rules} from "../src/Rules.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {BlockToken, SkimToken, ReenterToken, VoidToken, CallbackToken, DebtOwner, NoReceive} from "./Tokens.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// Fails to choose; its fallback plays the first legal move.
contract BrokenEngine is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        revert("broken");
    }

    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256)
        external
        pure
        returns (uint16 m, Rules.Played memory)
    {
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        m = Bitboard.legalMoves(Bitboard.fromBoard(board, w, b), !black)[0];
        return (m, Rules.move(board, mover, other, black, m));
    }
}

/// Fails to choose and to fall back: the game can only end as a draw.
contract DeadEngine is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        revert("dead");
    }

    function playAny(uint256, uint32, uint32, bool, uint256) external pure returns (uint16, Rules.Played memory) {
        revert("dead");
    }
}

/// Anyone can create a pool with any token: hostile tokens and engine failures must never break trading or the books.
/// Runs out of gas on every choice (a pathological position); its fallback plays the first legal move.
contract GreedyEngine is IChessEngine {
    function play(uint256, uint32, uint32, bool, uint256, uint256, uint64[8] calldata, uint32, uint16)
        external
        pure
        returns (uint16, Rules.Played memory)
    {
        while (true) {}
    }

    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256)
        external
        pure
        returns (uint16 m, Rules.Played memory)
    {
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        m = Bitboard.legalMoves(Bitboard.fromBoard(board, w, b), !black)[0];
        return (m, Rules.move(board, mover, other, black, m));
    }
}

contract HostileTest is Base {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    Currency token; // the hostile token, paired with a plain one

    function setUp() public {
        deployV4();
    }

    /// A pool of `t` against the hook's IMD (every duel needs a route for its slice), with liquidity.
    function pairWith(MockERC20 t) internal {
        MockERC20 q = deployHookAside(v5());
        for (uint256 i; i < 2; i++) {
            MockERC20 x = i == 0 ? t : q;
            x.mint(address(this), 1e30);
            x.approve(address(swapRouter), type(uint256).max);
            x.approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        t.approve(address(hook), type(uint256).max);
        (Currency c0, Currency c1) = address(t) < address(q)
            ? (Currency.wrap(address(t)), Currency.wrap(address(q)))
            : (Currency.wrap(address(q)), Currency.wrap(address(t)));
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        token = Currency.wrap(address(t));
    }

    /// A native ETH / IMD duel on a hook aside, with liquidity: ETH's team is the "token" team.
    function pairEth() internal {
        MockERC20 q = deployHookAside(v5());
        q.mint(address(this), 1e30);
        q.approve(address(swapRouter), type(uint256).max);
        q.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 1e30);
        (pool, id) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(q)), IHooks(address(hook)), 3000, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity{value: 1e27}(pool, ModifyLiquidityParams(-887220, 887220, 1e24, 0), "");
        token = CurrencyLibrary.ADDRESS_ZERO;
    }

    /// The token's team (White in game 0) gets mated: Black's only legal move mates (forcedMate). `owner` bids for
    /// it with 1 unit of the token; the next block's trade (White's) plays it, and the mate's payout (a quarter of the
    /// token team's chest, capped at twice the bid: 2 units) is recorded for `owner` in the token, through the real
    /// resolve path.
    function mateForcedOn(address owner) internal {
        forcedMate(true);
        assertEq(whiteTeam(), tokenTeam(), "the token's team is White in game 0");
        black(1e18, owner);
        next(12);
        white(1e18, address(0)); // plays Black's move first
    }

    function tokenTeam() internal view returns (uint256) {
        return pool.currency0 == token ? 0 : 1;
    }

    /// The token's team gets mated through the harness: a quarter of its chest is recorded for `owner` in the token.
    function tokenTeamMatedFor(address owner) internal {
        mateAgainst(tokenTeam(), owner, 1e30);
    }

    function finalizeWithATinyTrade() internal {
        next(12);
        trade(1 - tokenTeam(), 100, address(0));
    }

    // ---------------------------------------------------------------- engine failure

    /// A trade sent with too little gas for the engine must not get the fallback's seeded legal move instead (which
    /// would let anyone force an unthinking move on the queued turn by choosing the gas limit): it either plays the
    /// engine's move or reverts (NotEnoughGas), so gas estimates include the move. Swept over gas limits around the engine's cost, each from the same state.
    function test_starvingTheEngineNeverPlaysTheFallback() public {
        setUpMainDuel();
        white(1e18, address(0xA)); // a turn to play
        next(12);
        bytes memory call = abi.encodeCall(
            PoolSwapTest.swap,
            (
                pool,
                SwapParams(toMove() == 1, -1e18, toMove() == 1 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                bytes("")
            )
        );
        uint256 played;
        uint256 reverted;
        // Resolution now reserves the complete engine cap before calling it (imported audit gas finding).
        // Sweep through that admission threshold as well as budgets that only cover an open-window bid.
        for (uint256 g = 200_000; g <= 4_000_000; g += 50_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = address(swapRouter).call{gas: g}(call);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (ok) {
                assertEq(count(logs, FAILED), 0, "a starved engine played the fallback move");
                if (count(logs, MOVED) == 1) played++;
            } else {
                reverted++;
            }
            vm.revertToState(snap);
        }
        assertGt(played, 0, "enough gas plays the engine's move");
        assertGt(reverted, 0, "too little reverts");
    }

    /// An engine that burns its whole cap: a trade with less gas than the cap reverts (its estimate can't skip the
    /// move), a trade with more gets the fallback move at 0%, so a pathological position costs at most ~5M gas once.
    function test_aGasBurningEngineCostsOneExpensiveTradeNotTheGame() public {
        deployMintAndApprove2Currencies();
        deployHook(config(new GreedyEngine(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e18, address(0xA));
        next(12);
        bytes memory call = abi.encodeCall(
            PoolSwapTest.swap,
            (
                pool,
                SwapParams(whiteTeam() == 0, -1e17, whiteTeam() == 0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                bytes("")
            )
        );
        (bool ok, bytes memory err) = address(swapRouter).call{gas: 1_500_000}(call);
        assertFalse(ok, "a normal gas limit reverts");
        assertTrue(err.length > 0);
        vm.recordLogs();
        (ok,) = address(swapRouter).call{gas: 6_000_000}(call);
        assertTrue(ok, "with more than the cap the fallback plays");
        assertEq(count(vm.getRecordedLogs(), FAILED), 1);
        assertEq(st().ply, 1);
        assertEq(st().moveStrength, 0);
    }

    function test_brokenEngineFallsBackToALegalMove() public {
        deployMintAndApprove2Currencies();
        deployHook(config(new BrokenEngine(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e18, address(0xA));
        vm.recordLogs();
        playTurn();
        assertEq(count(vm.getRecordedLogs(), FAILED), 1);
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 1, "the game still moved");
        assertEq(g.moveStrength, 0);
        assertEq(g.moveOwner, address(0xA));
    }

    /// If the fallback fails too (an engine bug), the game ends as a draw (reason 6) and a new one starts, so the
    /// pool never freezes: nothing is played or paid, the bid is cleared, and trading goes on (audit 2026-10-31).
    function test_aDeadEngineEndsTheGameAsADrawAndTradingGoesOn() public {
        deployMintAndApprove2Currencies();
        deployHook(config(new DeadEngine(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        white(1e18, address(0xA));
        vm.recordLogs();
        playTurn();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(count(logs, FAILED), 1);
        assertEq(count(logs, OVER), 1, "the game ended");
        uint256 reason;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DrawTriggered(bytes32,uint32,uint8,uint16)")) {
                (, reason,) = abi.decode(logs[i].data, (uint32, uint8, uint16));
            }
        }
        assertEq(reason, 6, "a draw by engine failure");
        IMDuelHook.Game memory g = st();
        assertEq(g.gameNo, 1, "a new game");
        assertEq(g.ply, 0, "nothing played");
        assertEq(
            hook.owed(address(0xA), currency0.toId()) + hook.owed(address(0xA), currency1.toId()), 0, "nothing paid"
        );
        next(12);
        trade(1 - whiteTeam(), 1e18, address(0)); // and the next trade goes through as well
    }

    // ---------------------------------------------------------------- hostile tokens

    function test_blockedRecipientStaysOwedAndTradingContinues() public {
        BlockToken t = new BlockToken();
        pairWith(t);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        t.block_(address(0xB0B));
        tokenTeamMatedFor(address(0xB0B)); // played and paid: the token refuses 0xB0B
        finalizeWithATinyTrade();
        assertEq(hook.owed(address(0xB0B), token.toId()), 25e18, "kept owed");
        assertEq(hook.chest(id, tokenTeam()), 75e18);
        assertEq(claims(token), hook.chest(id, tokenTeam()) + 25e18 + hook.owed(DEAD, token.toId()));
        trade(tokenTeam(), 1e18, address(0)); // and trading goes on
    }

    function test_feeOnTransferTokenFundsOnlyWhatArrives() public {
        SkimToken t = new SkimToken(); // no liquidity: the test routers can't settle a fee-on-transfer token
        MockERC20 q = deployHookAside(v5()); // its IMD: every duel needs a route
        (Currency c0, Currency c1) = address(t) < address(q)
            ? (Currency.wrap(address(t)), Currency.wrap(address(q)))
            : (Currency.wrap(address(q)), Currency.wrap(address(t)));
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        token = Currency.wrap(address(t));
        t.mint(address(this), 1_000e18);
        t.approve(address(hook), type(uint256).max);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        assertEq(hook.chest(id, tokenTeam()), 99e18, "the chest records what arrived");
        assertEq(claims(token), 99e18);
    }

    /// A token whose transferFrom returns nothing (USDT) funds a chest too (swarm audit, engine launch job).
    function test_aTokenReturningNothingFundsAChest() public {
        VoidToken t = new VoidToken();
        MockERC20 q = deployHookAside(v5()); // its IMD: every duel needs a route
        (Currency c0, Currency c1) = address(t) < address(q)
            ? (Currency.wrap(address(t)), Currency.wrap(address(q)))
            : (Currency.wrap(address(q)), Currency.wrap(address(t)));
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        token = Currency.wrap(address(t));
        t.mint(address(this), 1_000e18);
        t.approve(address(hook), type(uint256).max);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        assertEq(hook.chest(id, tokenTeam()), 100e18);
        assertEq(claims(token), 100e18);
    }

    /// A token that calls back on transfer gets its chance only inside a claim, in the hook's own unlock: a nested
    /// withdrawal there can't unlock again, the claim reverts as a whole and nothing is lost.
    function test_reenteringTokenCannotBreakAClaim() public {
        ReenterToken t = new ReenterToken();
        pairWith(t);
        hook.fundChest(pool, tokenTeam() == 1, 100e18);
        tokenTeamMatedFor(address(0xCAFE));
        finalizeWithATinyTrade();
        assertEq(hook.owed(address(0xCAFE), token.toId()), 25e18, "recorded");
        tokenTeamMatedFor(address(0xB0B));
        finalizeWithATinyTrade();
        uint256 bob = hook.owed(address(0xB0B), token.toId());
        assertGt(bob, 0);
        t.arm(address(0xB0B), address(hook), abi.encodeCall(IMDuelHook.withdraw, (address(0xCAFE), token)));
        vm.expectRevert();
        hook.withdraw(address(0xB0B), token); // the callback's nested unlock fails, so the whole claim does
        assertEq(hook.owed(address(0xB0B), token.toId()), bob, "nothing lost");
        assertEq(hook.owed(address(0xCAFE), token.toId()), 25e18, "nothing moved");
        t.arm(address(0), address(0), "");
        hook.withdraw(address(0xB0B), token);
        assertEq(t.balanceOf(address(0xB0B)), bob - 1, "claimed once the token behaves, but for the 1 wei kept owed");
    }

    // ---------------------------------------------------------------- hostile move owners (jobs f7f2a606 and 885d5cb6)

    /// A move owner paid while the PoolManager is unlocked could act on it: take 1 wei and leave the debt, settle 1 wei
    /// into the hook's own delta, or sync a currency, each making the trade that plays its move revert, and every
    /// later one, for about a day (the four mediums of launches f7f2a606 and 2666). Rewards are never sent inside a
    /// trade: the owner's code never runs, the reward is recorded, the move is played, trading goes on.
    function debtOwnerIsRefusedAndTradingGoesOn(Currency debtIn) internal {
        debtOwnerIsRefusedAndTradingGoesOn(debtIn, false);
    }

    function debtOwnerIsRefusedAndTradingGoesOn(Currency debtIn, bool creditsTheHook) internal {
        DebtOwner r = new DebtOwner(manager, debtIn);
        if (creditsTheHook) {
            r.creditTheHook(address(hook));
            vm.deal(address(r), 1 ether);
            // a funded token pot as well, so the hook holds deltas on both sides when the move pays
            MockERC20(Currency.unwrap(pool.currency1)).approve(address(hook), type(uint256).max);
            hook.fundChest(pool, true, 100e18);
        }
        if (token.isAddressZero()) hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        else hook.fundChest(pool, tokenTeam() == 1, 10e18);
        vm.recordLogs();
        mateForcedOn(address(r)); // the trade that plays the move: it must not revert
        assertEq(st().ply, 0, "the move is played and the mate starts a new game");
        assertEq(st().gameNo, 1);
        uint256 prize = paid(vm.getRecordedLogs());
        // the bid's size is what the pool received, net of the hook fee taken on that side
        assertApproxEqAbs(prize, 2e18, 2e16, "a quarter of the chest, capped at twice the 1-unit bid");
        assertEq(hook.owed(address(r), token.toId()), prize, "the reward is recorded, never pushed");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        next(12);
        trade(tokenTeam(), 1e18, address(0)); // and trading goes on, both ways
        next(12);
        trade(1 - tokenTeam(), 1e18, address(0));
        address[] memory who = new address[](1);
        who[0] = address(r);
        assertSolvent(who);
    }

    /// A reward owed to an address that can't receive it (job f7f2a606, low): the owed party sends it where it can.
    function test_anOwnerThatCannotReceiveWithdrawsElsewhere() public {
        pairEth();
        hook.fundChest{value: 10 ether}(pool, false, 10 ether);
        NoReceive r = new NoReceive();
        mateForcedOn(address(r));
        uint256 prize = hook.owed(address(r), 0);
        assertApproxEqAbs(
            prize, 2 ether, 2e16, "owed: a quarter of the 10 ETH chest, capped at twice the 1-unit bid; it takes no ETH"
        );
        vm.expectRevert();
        hook.withdraw(address(r), CurrencyLibrary.ADDRESS_ZERO);
        hook.withdrawTo(CurrencyLibrary.ADDRESS_ZERO, address(0xB0B)); // nobody else's call moves it
        assertEq(hook.owed(address(r), 0), prize);
        r.call(address(hook), abi.encodeCall(IMDuelHook.withdrawTo, (CurrencyLibrary.ADDRESS_ZERO, address(0xB0B))));
        assertEq(address(0xB0B).balance, prize - 1, "sent where the owner said, but for the 1 wei kept owed");
        assertEq(hook.owed(address(r), 0), 1);
        address[] memory who = new address[](1);
        who[0] = address(r);
        assertSolvent(who);
    }

    /// The one MatePaid in `logs`: its amount.
    function paid(Vm.Log[] memory logs) internal pure returns (uint256 amount) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == MATE_PAID) {
                (,,, amount) = abi.decode(logs[i].data, (uint32, address, address, uint256));
            }
        }
    }

    function test_anEthOwnerLeavingADebtCannotFreezeTheDuel() public {
        pairEth();
        debtOwnerIsRefusedAndTradingGoesOn(pool.currency1);
    }

    /// The recipient settles 1 wei into the hook's own delta instead (nonzero already: the swap's fee claims), so the
    /// count of nonzero deltas doesn't move; the guard must look at the hook's deltas themselves.
    function test_anEthOwnerCreditingTheHookCannotFreezeTheDuel() public {
        pairEth();
        debtOwnerIsRefusedAndTradingGoesOn(pool.currency1, true);
    }

    function test_aCallbackTokenOwnerLeavingADebtCannotFreezeTheDuel() public {
        CallbackToken t = new CallbackToken();
        pairWith(t);
        debtOwnerIsRefusedAndTradingGoesOn(pool.currency0 == token ? pool.currency1 : pool.currency0);
    }
}
