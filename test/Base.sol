// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {V4Fixture} from "./V4Fixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHarness, HookConfig} from "./Harness.sol";
import {Chessboard} from "./Chessboard.sol";

/// Shared setup: v4 PoolManager and routers, two test tokens, engine v5 and the hook (test harness) at an address
/// carrying its permission bits. By default currency0 stands in for IMD and currency1 for $IMDUEL, and `pool` is
/// their main duel (fee 3000, spacing 60).
abstract contract Base is Chessboard, V4Fixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD; // where the hook's $IMDUEL burn is owed
    bytes32 constant MOVED = keccak256("Moved(bytes32,uint32,uint16,uint16,address,uint256,uint16,uint8,bool)");
    bytes32 constant BID = keccak256("Bid(bytes32,uint32,uint16,address,uint256,uint16)");
    bytes32 constant OVER = keccak256("GameOver(bytes32,uint32,uint8,uint16)");
    bytes32 constant FAILED = keccak256("EngineFailed(bytes32,uint32,uint16)");
    bytes32 constant MATE_PAID = keccak256("MatePaid(bytes32,uint32,address,address,uint256)");
    bytes32 constant HOOK_SWAP = keccak256("HookSwap(bytes32,address,int128,int128,uint24)");

    IChessEngine engine;
    IMDuelHarness hook;
    uint256 hooksDeployed;
    PoolKey pool;
    PoolId id;

    /// Engine v5 from its own build: it compiles at 200 optimizer runs (foundry.toml); importing it would compile
    /// the importing file the same way.
    function v5() internal virtual returns (IChessEngine) {
        return IChessEngine(vm.deployCode("ChessEngineV5.sol:ChessEngineV5"));
    }

    /// How many blocks a move takes bids for: 1 in suites written for one-block turns, the launch value (3) where a
    /// suite overrides it.
    function turnBlocks() internal view virtual returns (uint256) {
        return 1;
    }

    /// The hook with IMD `imd`; $IMDUEL is the other token of the first pool opened.
    function config(IChessEngine e, Currency imd) internal view returns (HookConfig memory) {
        return HookConfig(manager, e, imd, turnBlocks());
    }

    /// A hook whose IMD and $IMDUEL are two fresh tokens, their main duel opened (no liquidity), so the default
    /// currencies route nowhere and can't open a duel. Returns its IMD, for pairing other tokens with.
    function deployHookAside(IChessEngine e) internal returns (MockERC20 imd) {
        imd = mockToken("IMD", "IMD");
        Currency a = Currency.wrap(address(imd));
        Currency b = Currency.wrap(address(mockToken("IMDUEL", "IMDUEL")));
        deployHook(config(e, a));
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function deployHook(HookConfig memory c) internal virtual {
        engine = c.engine;
        // a fresh address each time: a redeployed hook would keep the old one's storage (its main duel)
        address at = address(IMDUEL_HOOK_FLAGS | (uint160(0x1D0E1 + hooksDeployed++) << 40));
        deployCodeTo("Harness.sol:IMDuelHarness", abi.encode(c), at);
        hook = IMDuelHarness(at);
    }

    /// The default setup: managers, tokens, the hook with v5 and the main duel with deep liquidity.
    function setUpMainDuel() internal {
        deployV4();
        deployMintAndApprove2Currencies();
        deployHook(config(v5(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
    }

    function addLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-887220, 887220, 1_000_000e18, 0), "");
    }

    // ---------------------------------------------------------------- trading

    /// An exact-input trade buying team `team`'s token (0: currency0, 1: currency1) in `pool`.
    function trade(uint256 team, uint256 amountIn, address owner) internal {
        swap(pool, team == 1, -int256(amountIn), owner == address(0) ? bytes("") : abi.encodePacked(owner));
    }

    /// The team playing White in the current game: in game 0 the side the slice isn't taken in, then alternating.
    function whiteTeam() internal view returns (uint256) {
        return (st().gameNo & 1) ^ (st().base ^ 1);
    }

    uint256 constant WELL_TRADED = 1e24; // a game's inflow per pot that never binds the mate's inflow cap in a test

    /// Plays a mate in one against team `loser` through the harness (recorded and paid at once), at the end of a
    /// well-traded game: White's rook on a8 if White is the other team, else Black's rook on a1; the mating move is
    /// owned by `owner`, whose trade paid `paid`.
    function mateAgainst(uint256 loser, address owner, uint256 paid) internal {
        mateAgainstIn(loser, owner, paid, WELL_TRADED, WELL_TRADED);
    }

    /// mateAgainst after a game whose trading put `in0` and `in1` into the pots.
    function mateAgainstIn(uint256 loser, address owner, uint256 paid, uint256 in0, uint256 in1) internal {
        hook.setGameIn(id, in0, in1);
        uint256 b;
        if (whiteTeam() != loser) {
            b = put(put(put(put(put(put(b, "g1", 6), "a1", 4), "g8", 14), "f7", 9), "g7", 9), "h7", 9);
            hook.setPosition(id, b, side("g1"), side("g8"), 0, 0);
            hook.applyMove(pool, mv("a1", "a8"), owner, paid);
        } else {
            b = put(put(put(put(put(put(b, "g8", 14), "a8", 12), "g1", 6), "f2", 1), "g2", 1), "h2", 1);
            hook.setPosition(id, b, side("g1"), side("g8"), 1, 0);
            hook.applyMove(pool, mv("a8", "a1"), owner, paid);
        }
    }

    /// A position whose side to move has one legal move, and it mates: in check from a queen beside its king, the
    /// king takes it and uncovers its rook along the back rank. White (half-move 0): Kc8xd7, Rh8 mates Ka8 behind
    /// pawns a7, b7. Black (half-move 1): the mirror, Kc1xd2, Rh1 mates Ka1.
    function forcedMate(bool blackMates) internal {
        hook.setGameIn(id, WELL_TRADED, WELL_TRADED); // a well-traded game: the mate's inflow cap doesn't bind
        uint256 b;
        if (!blackMates) {
            b = put(put(put(put(put(put(b, "c8", 6), "h8", 4), "a8", 14), "a7", 9), "b7", 9), "d7", 13);
            hook.setPosition(id, b, side("c8"), side("a8"), 0, 0);
        } else {
            b = put(put(put(put(put(put(b, "c1", 14), "h1", 12), "a1", 6), "a2", 1), "b2", 1), "d2", 5);
            hook.setPosition(id, b, side("a1"), side("c1"), 1, 0);
        }
    }

    function white(uint256 amountIn, address owner) internal {
        trade(whiteTeam(), amountIn, owner);
    }

    function black(uint256 amountIn, address owner) internal {
        trade(1 - whiteTeam(), amountIn, owner);
    }

    /// Plays the queued turn: a dust trade in the next block by the team that owns it (which then doesn't bid again).
    function playTurn() internal {
        uint256 t = toMove();
        next(12);
        trade(t, 100, address(0));
    }

    /// The team whose turn it is.
    function toMove() internal view returns (uint256) {
        return whiteTeam() ^ (st().ply & 1);
    }

    /// Next block, `secs` later. vm.getBlock* because with via_ir a test can reuse a stale block.* value.
    function next(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function st() internal view returns (IMDuelHook.Game memory) {
        return hook.game(id);
    }

    /// The top bid for the move being bid for now in pool `pid`: the side to move's.
    function bidOf(PoolId pid) internal view returns (IMDuelHook.TopBid memory) {
        IMDuelHook.Game memory g = hook.game(pid);
        return g.bids[(g.gameNo & 1) ^ (g.base ^ 1) ^ (g.ply & 1)];
    }

    /// bidOf the main duel.
    function bid() internal view returns (IMDuelHook.TopBid memory) {
        return bidOf(id);
    }

    function count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) if (logs[i].topics[0] == topic) n++;
    }

    function claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    /// What the hook holds in `c`, and what it owes in `c`: the chests of `pools` (with the main duel's, which takes
    /// every pool's slice), the burn owed to 0x...dEaD and the rewards recorded for `who` and for the signing wallet
    /// (the owner of every trade that names none).
    function books(Currency c, PoolKey[] memory pools, address[] memory who) internal view returns (uint256, uint256) {
        // the signing wallet can be anyone in an invariant run, 0x...dEaD included: count each owed slot once
        uint256 total = hook.owed(DEAD, c.toId()) + (tx.origin == DEAD ? 0 : hook.owed(tx.origin, c.toId()));
        bool main;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].currency0 == c) total += hook.chest(pools[i].toId(), 0);
            if (pools[i].currency1 == c) total += hook.chest(pools[i].toId(), 1);
            main = main || PoolId.unwrap(pools[i].toId()) == PoolId.unwrap(hook.mainId());
        }
        (Currency m0, Currency m1) = hook.imd() < hook.imduel() ? (hook.imd(), hook.imduel()) : (hook.imduel(), hook.imd());
        if (!main && (c == m0 || c == m1)) total += hook.chest(hook.mainId(), c == m0 ? 0 : 1);
        for (uint256 j; j < who.length; j++) if (who[j] != tx.origin && who[j] != DEAD) total += hook.owed(who[j], c.toId());
        return (claims(c), total);
    }

    /// Everything the hook holds in `c` is owed to someone.
    function assertSolvent(Currency c, PoolKey[] memory pools, address[] memory who) internal view {
        (uint256 held, uint256 total) = books(c, pools, who);
        assertEq(held, total, "held = chests + burn + owed");
    }

    /// assertSolvent for the main duel alone, both currencies.
    function assertSolvent(address[] memory who) internal view {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = pool;
        assertSolvent(pool.currency0, pools, who);
        assertSolvent(pool.currency1, pools, who);
    }

    function nobody() internal pure returns (address[] memory) {
        return new address[](0);
    }
}
