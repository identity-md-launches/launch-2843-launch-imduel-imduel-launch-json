// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

/// Stands in for the EIP-2935 history contract: serves the hash of block `n`, nothing else.
contract HistoryStub {
    uint256 immutable n;
    bytes32 immutable h;

    constructor(uint256 n_, bytes32 h_) {
        (n, h) = (n_, h_);
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(abi.decode(input, (uint256)) == n);
        return abi.encode(h);
    }
}

/// The game flow driven by real swaps on a v4 PoolManager with engine v5: every block is a turn (bids, the biggest
/// owning it), the next block's trade plays it, timeouts, expired turns, teams and colours. Several swaps without
/// next() between them share a block.
contract GameTest is Base {
    function setUp() public {
        setUpMainDuel();
    }

    // ---------------------------------------------------------------- turns

    function test_aTradeBidsForTheTurn() public {
        uint256 board0 = st().board;
        white(1e18, address(0xA));
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 0, "nothing is played inside the trade");
        assertEq(g.board, board0);
        assertEq(bid().owner, address(0xA));
        assertEq(g.closeBlock, vm.getBlockNumber());
    }

    function test_theNextBlocksTradePlaysTheTurn() public {
        white(1e18, address(0xA));
        next(12);
        vm.recordLogs();
        black(1e18, address(0xB)); // plays White's move, then bids for Black
        assertEq(count(vm.getRecordedLogs(), MOVED), 1);
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 1);
        assertEq(g.moveOwner, address(0xA));
        assertEq(bid().owner, address(0xB), "the same trade bids for Black");
    }

    function test_ownerDefaultsToTxOrigin() public {
        white(1e18, address(0));
        assertEq(bid().owner, tx.origin);
    }

    function test_theOtherTeamCannotBidOnThisTurn() public {
        black(5e18, address(0xB));
        assertFalse(bid().open);
    }

    function test_anyTradeSizeBids() public {
        white(1_000, address(0xD)); // dust: no minimum trade
        assertEq(bid().owner, address(0xD));
        assertEq(bid().strength, 9_000, "against an empty pot even dust plays at the cap");
        playTurn();
        black(1e18, address(0xB));
        playTurn();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, false, 1e21);
        hook.fundChest(pool, true, 1e21);
        white(1_000, address(0xD));
        assertEq(bid().owner, address(0xD));
        assertEq(bid().strength, 0, "against a pot, dust plays at the engine's base strength");
    }

    function test_theBiggestTradeInTheBlockOwnsTheTurn() public {
        white(1e18, address(0xA));
        vm.recordLogs();
        white(3e18, address(0xC));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(count(logs, BID), 1);
        assertEq(count(logs, MOVED), 0, "no engine run for a bid");
        IMDuelHook.Game memory g = st();
        assertEq(bid().owner, address(0xC));
        assertGt(bid().size, 2.9e18);
    }

    function test_aSmallerTradeInTheBlockDoesNotTakeTheTurn() public {
        white(3e18, address(0xA));
        white(1e18, address(0xB));
        assertEq(bid().owner, address(0xA));
    }

    function test_aTurnClosesWithItsBlock() public {
        white(1e18, address(0xA));
        next(12);
        white(9e20, address(0xC)); // too late to outbid: it plays A's move, and it's Black's turn now
        assertEq(st().moveOwner, address(0xA));
        assertFalse(bid().open);
    }

    /// The dice are the hash of the bid's block, fixed once that block ends: whoever plays the turn, and whenever,
    /// the move is the same.
    function test_whoPlaysTheTurnAndWhenDoesNotChangeTheMove() public {
        white(1e18, address(0xA));
        uint256 bidBlock = vm.getBlockNumber();
        uint256 snap = vm.snapshotState();
        next(12);
        black(1e18, address(0xB));
        uint256 soon = st().board;
        vm.revertToState(snap);
        vm.roll(bidBlock + 200); // later, by the other team, within the chain's memory
        vm.warp(vm.getBlockTimestamp() + 2_400);
        trade(whiteTeam(), 5e18, address(0xC));
        assertEq(st().board, soon, "same move");
    }

    /// Past BLOCKHASH's 256 blocks the hash comes from the EIP-2935 history contract: the same dice, the same move,
    /// still its owner's.
    function test_anOldTurnIsPlayedWithTheHistoryContractsHash() public {
        white(1e18, address(0xA));
        uint256 bidBlock = vm.getBlockNumber();
        uint256 snap = vm.snapshotState();
        next(12);
        bytes32 h = this.hashOf(bidBlock); // an external call: via_ir may reuse a stale block.number in this function
        assertTrue(h != 0);
        black(1e18, address(0xB));
        uint256 soon = st().board;
        vm.revertToState(snap);
        vm.etch(0x0000F90827F1C53a10cb7A02335B175320002935, address(new HistoryStub(bidBlock, h)).code);
        vm.roll(bidBlock + 300);
        vm.warp(vm.getBlockTimestamp() + 3_600);
        black(1e18, address(0xB));
        assertEq(st().board, soon, "same move");
        assertEq(st().moveOwner, address(0xA), "still the owner's turn");
    }

    function hashOf(uint256 n) external view returns (bytes32) {
        return blockhash(n);
    }

    /// A turn whose block hash the chain no longer serves becomes a timeout turn in the block that notices it.
    function test_anExpiredTurnBecomesATimeoutTurn() public {
        white(1e18, address(0xA));
        vm.roll(vm.getBlockNumber() + 300); // past BLOCKHASH's 256, and no history contract here
        black(1e18, address(0xB));
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 0, "not played");
        assertEq(bid().owner, address(0), "now a timeout turn");
        assertEq(g.closeBlock, vm.getBlockNumber());
        playTurn();
        assertEq(st().ply, 1);
        assertEq(st().moveOwner, address(0));
        assertEq(st().moveStrength, 0);
    }

    function test_playedPositionsEnterTheRepetitionMemory() public {
        white(1e18, address(0xA));
        assertEq(hook.history(id, 0), 0, "a bid is not a position");
        playTurn();
        assertTrue(hook.history(id, 0) != 0, "remembered once played");
    }

    // ---------------------------------------------------------------- strength

    /// Strength is what the trade received as a share of its own team's pot, read when it bids: +30% per tenfold
    /// (0.1% 0, 1% 30%, 10% 60%, the whole pot and up 90%). An empty pot plays at 90%. Pots of 1,000 tokens; the pool
    /// (1e24 a side) barely moves for these trades, so what a trade receives is about what it pays.
    function test_strengthFollowsTheShareOfTheTeamsPot() public {
        white(1e18, address(0xA));
        assertEq(bid().strength, 9_000, "an empty pot: the cap");
        playTurn();
        black(1e18, address(0xB));
        playTurn();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, false, 1e21);
        hook.fundChest(pool, true, 1e21);
        uint256[4] memory amounts = [uint256(1e18), 1e19, 1e20, 1e21];
        uint256[4] memory want = [uint256(0), 3_000, 6_000, 9_000];
        for (uint256 i; i < 4; i++) {
            white(amounts[i], address(0xA));
            assertApproxEqAbs(bid().strength, want[i], 90, "step curve");
            playTurn();
            black(1e18, address(0xB));
            playTurn();
        }
    }

    // ---------------------------------------------------------------- teams and colours

    function test_teamsSwapColoursEveryGame() public {
        assertEq(whiteTeam(), 1, "the team of the token people buy ($IMDUEL, currency1) plays White first");
        uint256 b;
        b = put(b, "g1", 6);
        b = put(b, "a1", 4);
        b = put(b, "h8", 14);
        b = put(b, "g7", 9);
        b = put(b, "h7", 9);
        hook.setPosition(id, b, side("g1"), side("h8"), 0, 0);
        hook.applyMove(pool, mv("a1", "a8"), address(0xA11CE), 0); // back-rank mate ends game 0
        assertEq(st().gameNo, 1);
        next(12);
        trade(1, 1e18, address(0xA)); // currency1's team now plays Black: no bid
        assertFalse(bid().open);
        trade(0, 1e18, address(0xB)); // currency0's team plays White
        assertEq(bid().owner, address(0xB));
    }

    // ---------------------------------------------------------------- timeouts

    function test_silentSidePlaysAtZeroStrength() public {
        next(hook.TURN_TIMEOUT());
        black(1e18, address(0xB)); // a Black trade on White's turn: White's turn opens as a timeout
        assertEq(bid().owner, address(0));
        assertEq(st().closeBlock, vm.getBlockNumber());
        playTurn();
        IMDuelHook.Game memory g = st();
        assertEq(g.ply, 1);
        assertEq(g.moveOwner, address(0));
        assertEq(g.moveStrength, 0);
    }

    function test_lateTradeStillBidsNormally() public {
        next(hook.TURN_TIMEOUT() + 100);
        white(1e18, address(0xA));
        assertEq(bid().owner, address(0xA), "not a timeout turn");
    }

    function test_aTimeoutTurnCanBeTakenInItsBlock() public {
        next(hook.TURN_TIMEOUT());
        black(1e18, address(0)); // times White out
        white(1e18, address(0xA)); // a White trade in the same block takes the turn back
        assertEq(bid().owner, address(0xA));
        playTurn();
        assertEq(st().moveOwner, address(0xA));
    }

    // ---------------------------------------------------------------- configuration

    function newHook(HookConfig memory c) internal returns (IMDuelHook) {
        return new IMDuelHook(c.manager, c.engine, c.imd, c.minImd, c.minImduel, c.turnBlocks);
    }

    /// Uniswap's hook checklist, item 1: only the PoolManager drives the callbacks, only the hook itself converts
    /// through its gas-capped call.
    function test_onlyThePoolManagerAndTheHookCanCallIn() public {
        SwapParams memory p = SwapParams(true, -1e18, MIN_PRICE_LIMIT);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.afterInitialize(address(this), pool, SQRT_PRICE_1_1, 0);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.beforeSwap(address(this), pool, p, "");
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.afterSwap(address(this), pool, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(IMDuelHook.NotManager.selector);
        hook.unlockCallback(abi.encode(uint8(0), abi.encode(address(this), currency0, uint256(1))));
        vm.expectRevert(IMDuelHook.NotSelf.selector);
        hook.convertBatch(currency0);
    }

    function test_rejectsBadConfig() public {
        HookConfig memory c = config(IChessEngine(address(0)), currency0);
        vm.expectRevert(IMDuelHook.BadConfig.selector);
        newHook(c);
        c = config(IChessEngine(address(0xC0DE)), currency0); // an address without code passes: the launch's admission
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector); // floor builds the hook on a chain where the engine
        newHook(c); // has none (its address is checked off chain); only this plain address stops the deploy
        c = config(engine, currency0);
        c.turnBlocks = 0;
        vm.expectRevert(IMDuelHook.BadConfig.selector);
        newHook(c);
        c.turnBlocks = 1_001;
        vm.expectRevert(IMDuelHook.BadConfig.selector);
        newHook(c);
    }

    /// The launch factory deploys the hook and opens the main duel in one transaction: the first pool opened is the
    /// main duel and must pair IMD; its other token is $IMDUEL. Later pools never replace it.
    function test_theFirstPoolOpenedIsTheMainDuel() public {
        assertEq(Currency.unwrap(hook.imduel()), Currency.unwrap(currency1), "set up by the main duel");
        assertEq(PoolId.unwrap(hook.mainId()), PoolId.unwrap(id));
        (, PoolId other) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(hook.mainId()), PoolId.unwrap(id), "a later IMD pool is not the main duel");
        assertTrue(hook.game(other).live);
    }

    function test_theMainDuelMustPairImd() public {
        Currency fresh = Currency.wrap(address(mockToken("IMD", "IMD")));
        deployHook(config(engine, fresh)); // IMD is neither of the default currencies
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.expectRevert();
        initPool(CurrencyLibrary.ADDRESS_ZERO, fresh, IHooks(address(hook)), 3000, SQRT_PRICE_1_1); // IMD / ETH
    }

    // ---------------------------------------------------------------- whole games, robustness

    /// A whole game driven by swaps: each block the side to move trades (playing the last turn and bidding), sometimes
    /// with a rival bidding in the same block.
    function test_aGamePlaysOutThroughSwaps() public {
        uint256 seed = 7;
        uint256 moves;
        uint256 bids;
        uint256 maxGas;
        uint256 over;
        for (uint256 step_; step_ < 400 && over == 0; step_++) {
            seed = uint256(keccak256(abi.encode(seed)));
            next(12 + seed % 30);
            vm.recordLogs();
            uint256 team = toMove();
            uint256 g0 = gasleft();
            trade(team, 1e17 + seed % 3e20, address(0));
            uint256 used = g0 - gasleft();
            if (used > maxGas) maxGas = used;
            if ((seed >> 40) % 3 == 0) trade(team, 1e17 + (seed >> 64) % 6e20, address(0)); // a rival, same block
            Vm.Log[] memory logs = vm.getRecordedLogs();
            moves += count(logs, MOVED);
            bids += count(logs, BID);
            assertEq(count(logs, FAILED), 0, "the engine never fails");
            over += count(logs, OVER);
        }
        emit log_named_uint("moves played", moves);
        emit log_named_uint("bids (incl. outbid ones)", bids);
        emit log_named_uint("most gas for a swap", maxGas);
        assertEq(over, 1, "the game finished");
    }

    /// No sequence of trades, blocks and owners makes a swap revert.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_swapsNeverRevert(uint256 seed) public {
        for (uint256 i; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 size = 1 + seed % 5e20;
            uint256 r = (seed >> 8) % 10;
            if (r == 0) next(hook.TURN_TIMEOUT());
            else if (r < 6) next((seed >> 16) % 60);
            address owner = (seed >> 24) % 3 == 0 ? address(uint160(seed)) : address(0);
            if ((seed >> 32) % 3 == 0) swap(pool, (seed >> 36) % 2 == 0, int256(size), ""); // exact output
            else trade((seed >> 40) % 2, size, owner);
        }
    }
}
