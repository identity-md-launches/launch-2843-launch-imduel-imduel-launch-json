// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {Rules} from "../src/Rules.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Plays the move scripted for each board at almost no cost, so a moving trade's gas is the hook's and the rules'
/// own share.
contract ScriptedEngine is IChessEngine {
    mapping(uint256 => uint16) public moveFor;

    function script(uint256 board, uint16 move) external {
        moveFor[board] = move;
    }

    function play(uint256 board, uint32 mover, uint32 other, bool black, uint256, uint256, uint64[8] calldata,
        uint32, uint16) external view returns (uint16 m, Rules.Played memory)
    {
        m = moveFor[board];
        return (m, Rules.move(board, mover, other, black, m)); // the rules' cost belongs to the hook's share
    }

    function playAny(uint256, uint32, uint32, bool, uint256) external pure returns (uint16, Rules.Played memory) {
        revert();
    }
}

/// What swaps cost with engine v5 in the main duel. Run with --isolate for
/// numbers that match a real transaction (each swap its own transaction, cold storage).
contract HookGasTest is Base {
    uint256 constant PLAIN_BUDGET = 200_000;
    uint256 constant BID_BUDGET = 230_000;
    // the trade that plays a turn, from a fresh pool jumped to a position, the move a new player's first: three first
    // writes of the game plus the player's two stat words and the player list (2026-10-31; was 560k before the stats;
    // 640k since both pots take a share of every trade, 2026-11-02: the bid it plays then sits at another strength,
    // and the engine's share of the trade moves with strength; ~625k measured)
    uint256 constant MOVING_BUDGET = 640_000;
    uint256 constant RUNNING_BUDGET = 480_000; // its average in a running game

    function setUp() public {
        deployV4();
        deployMintAndApprove2Currencies();
    }

    function open() internal {
        deployHook(config(v5(), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        fundPots();
    }

    /// Pots of 1e22 a side, so the 1e20 bids below are a 1% share: 30% strength, as the budgets were set (an empty
    /// pot would play every bid at 90%, which costs the engine more).
    function fundPots() internal {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, false, 1e22);
        hook.fundChest(pool, true, 1e22);
    }

    function gasOf(uint256 team, uint256 amount, address owner) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        trade(team, amount, owner);
        used = g0 - gasleft();
    }

    function test_openingGas() public {
        measure(false);
    }

    function test_middlegameGas() public {
        measure(true);
    }

    function measure(bool middlegame) internal {
        open();
        if (middlegame) {
            (uint256 b, uint32 w, uint32 k) = replay(3, 30);
            hook.setPosition(id, b, w, k, 30, 0);
        }
        trade(1 - whiteTeam(), 1e20, address(0xC)); // warms up the pool (first fees); a bid for Black's next move
        uint256 firstBid = gasOf(whiteTeam(), 1e20, address(0xA)); // the pool's first turn: its storage starts at zero
        uint256 outbidding = gasOf(whiteTeam(), 3e20, address(0xB)); // a bigger bid in the same block
        uint256 plain = gasOf(1 - whiteTeam(), 1e20, address(0xC)); // the other team, not 10% more: no new bid, nothing to play
        next(12);
        uint256 playing = gasOf(1 - toMove(), 1e20, address(0xD)); // plays White's move, then bids for Black
        next(12);
        trade(toMove(), 100, address(0)); // Black's team plays its turn (dust: no bid, White to move)
        uint256 bidding = gasOf(toMove(), 1e20, address(0xA)); // a typical bid
        emit log_named_uint("first bid in a new pool", firstBid);
        emit log_named_uint("bidding trade", bidding);
        emit log_named_uint("outbidding trade", outbidding);
        emit log_named_uint("plain trade", plain);
        emit log_named_uint("next block: play the turn and bid", playing);
        assertLt(plain, PLAIN_BUDGET, "plain trade budget");
        assertLt(bidding, BID_BUDGET, "bidding trade budget");
        assertLt(playing, MOVING_BUDGET, "playing trade budget");
    }

    /// The trade that plays a move in a running game, on average: a real v5 game, one trade per block, each 1e20
    /// against pots of 1e22 (a 1% share: 30% strength; full strength, the whole pot and more, costs more), from
    /// half-move 20 (the last-move slot and the repetition ring already hold values, as in any game under way;
    /// test_middlegameGas jumps a fresh pool to a position and pays two first writes a live game never does).
    function test_runningGameGas() public {
        open();
        trade(toMove(), 1e20, address(0xA)); // the first bid
        (uint256 total, uint256 n, uint256 max) = (0, 0, 0);
        for (uint256 i; i < 70; i++) {
            next(12);
            (uint256 ply, uint32 gameNo) = (st().ply, st().gameNo);
            uint256 used = gasOf(1 - toMove(), 1e20, address(uint160(0xA + (i & 1)))); // plays the move, bids for the next
            if (st().gameNo != gameNo) break;
            assertEq(st().ply, ply + 1);
            if (ply >= 20) (total, n, max) = (total + used, n + 1, used > max ? used : max);
        }
        assertGt(n, 30, "enough moves measured");
        emit log_named_uint("running game, moving trades measured", n);
        emit log_named_uint("running game, moving trade average", total / n);
        emit log_named_uint("running game, moving trade max", max);
        assertLt(total / n, RUNNING_BUDGET, "running game moving trade budget");
    }

    /// The hook's own share of moving trades: a recorded game's moves, scripted, each played by a trade in its own
    /// block (so each also finalizes the previous move).
    function test_hookShareOfAMovingTrade() public {
        ScriptedEngine e = new ScriptedEngine();
        deployHook(config(IChessEngine(address(e)), currency0));
        (pool, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        fundPots();
        uint256[] memory moves = gameMoves(3);
        uint256 total;
        uint256 max;
        uint256 n = 40;
        trade(toMove(), 1e20, address(0xA)); // the first turn
        for (uint256 i; i < n; i++) {
            e.script(st().board, uint16(moves[i]));
            next(12);
            uint256 used = gasOf(1 - toMove(), 1e20, address(0xA)); // plays the turn, bids for the next
            assertEq(st().ply, i + 1);
            if (i >= 2) {
                total += used;
                if (used > max) max = used;
            }
        }
        emit log_named_uint("hook share of a moving trade: average", total / (n - 2));
        emit log_named_uint("hook share of a moving trade: max", max);
    }

    /// A side duel's trade books its slice into the main duel's pot (one more pot slot, no swap): a plain trade still.
    function test_aSideDuelsSliceStaysAPlainTrade() public {
        open();
        MockERC20 x = mockToken("X", "X");
        x.mint(address(this), 1e30);
        x.approve(address(swapRouter), type(uint256).max);
        x.approve(address(modifyLiquidityRouter), type(uint256).max);
        Currency xc = Currency.wrap(address(x));
        (Currency c0, Currency c1) = xc < currency0 ? (xc, currency0) : (currency0, xc);
        (pool, id) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(pool);
        trade(1 - whiteTeam(), 1e18, address(0)); // warms up the pool and the main duel's pot slot
        uint256 g = gasOf(1 - whiteTeam(), 1e18, address(0)); // pays its IMD slice into the main duel's IMD pot
        emit log_named_uint("side duel trade with its slice", g);
        assertLt(g, PLAIN_BUDGET, "plain trade budget");
    }
}
