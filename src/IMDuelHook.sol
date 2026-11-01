// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Chess} from "./Chess.sol";
import {Strength} from "./Strength.sol";
import {Rules} from "./Rules.sol";
import {IChessEngine} from "./IChessEngine.sol";

// The hook's permission bits; its address must carry them.
uint160 constant IMDUEL_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// IMDuel: chess played by your trades. One open hook that works the same in every pool: each pool plays an
/// endless series of games between its two tokens. Buying a token plays for its team; the teams swap colours every
/// game. Every buy bids for its team's next move, at a strength set by what it received as a share of its team's pot;
/// the biggest owns the move, and a new top bid must beat the old one by more than 10%. A move stays open for
/// `turnBlocks` blocks after the previous one was played (one whose first bid comes only in its last block or later
/// stays open `turnBlocks` blocks from that bid); the first trade after that plays it, with the hash of the
/// window's last block as the dice, so a bidder can't know the move while it can still bid. The one exception is
/// whoever builds that last block: it can bid in it and try several versions of it, keeping the hash whose move pays
/// (an accepted risk).
/// Only checkmates pay: a mate takes a quarter of the losing team's pot and pays it to the move that mated, in the
/// loser's token, at most twice what that move's trade paid and at most what the game's trades paid into that pot
/// (so a game played for dust pays nothing, and nobody wins back more than a game put in); whatever
/// isn't paid stays in the pot. Rewards are recorded and their owners claim them (withdraw): no reward is ever sent
/// inside a trade, so no recipient runs code while a trader's PoolManager is unlocked (a recipient may trade inside
/// its own withdraw's unlock: nothing is pending then, the books are exact). The owner is the address the
/// trade names in hookData, else the wallet that signed the transaction, so a trade through any router earns.
/// Money: 0.75% of every swap. 0.65% fills the pots, half from each side of the trade into that token's pot, so every
/// trade feeds both by about the same value and they stay balanced; 0.1% (the protocol slice) is taken in $IMDUEL
/// where the pool holds it and burned (owed to 0x...dEaD, sent by anyone's withdraw), and else in IMD, into the main
/// duel's IMD pot. So every duel pairs a token with IMD or $IMDUEL. The hook reads no prices: nothing it does depends on where a trade can push one
/// (audits 2026-11-01). A trade must swap its whole order: the fee part taken before the swap counts all of it.
/// Stats: every player (an address) of the main duel has two words of counts (stats), kept for badges and display
/// only: they never pay or limit anything. Every move a trade's bid plays counts for its owner, mates included; side
/// duels count nothing (their empty pots play at the cap for free).
/// It implements only the callbacks its permission bits enable; the pool manager calls no others.
contract IMDuelHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------- rules of play
    uint256 public constant TURN_TIMEOUT = 600; // seconds without a move before the side to move plays at 0%
    uint256 public constant RAISE_PCT = 10; // a new top bid pays more than this much over the current one
    uint16 public constant MAX_PLY = Chess.MAX_PLY;
    uint16 public constant MAX_QUIET_PLY = Chess.MAX_QUIET_PLY;
    // the engine's heaviest measured move is ~950k (test/EngineV5Games.t.sol); 3x that bounds what a pathological
    // position can cost: a trade with less gas than the cap needs reverts (NotEnoughGas), one with more gets the fallback
    uint256 internal constant ENGINE_GAS = 3_000_000;
    uint256 internal constant FALLBACK_GAS = 2_000_000;
    // Reserve gas before calling the engine: recording the move, stats, payout and next bid must still fit,
    // and an underfunded call must report NotEnoughGas instead of losing that error to the 63/64 rule.
    uint256 internal constant ENGINE_RETURN_GAS = 300_000;
    // EIP-2935: the last 8,191 block hashes (about a day), beyond the 256 the BLOCKHASH opcode serves
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    // ---------------------------------------------------------------- money
    uint256 public constant CHEST_BPS = 65; // the pot fee in all: half of it from each side of a trade
    uint256 public constant SLICE_BPS = 10;
    uint24 public constant HOOK_FEE_PIPS = uint24((CHEST_BPS + SLICE_BPS) * 100); // the hook fee as URC-2 reports it (0.75%)
    uint256 public constant MATE_SHARE_BPS = 2_500; // a mate takes a quarter of the losing team's pot, for the move that mated
    uint256 public constant PAYOUT_CAP = 2; // a mate pays at most twice what its move's trade paid
    uint256 public constant MATE_INFLOW_CAP = 1; // and at most what the game's trades paid into the losing pot
    uint256 internal constant IN_MAX = (1 << 112) - 1; // a pot's inflow in a game, as gameIn packs it
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable manager;
    IChessEngine public immutable engine; // chooses each move and plays it by the rules (Rules.sol)
    Currency public immutable imd;
    uint256 public immutable turnBlocks; // how many blocks a move stays open for bids once the previous one is played

    struct Game {
        bool live; // pool initialized with this hook
        uint8 base; // which currency (0 or 1) is IMD (else $IMDUEL): its team plays Black in game 0 (teamOf)
        uint8 slice; // which currency (0 or 1) the protocol slice is taken in: $IMDUEL where the pool has it, else IMD
        uint32 gameNo; // the team of the token people buy (not the base) plays White in even games
        uint16 ply; // half-moves played in this game; odd = Black to move
        uint16 quiet; // half-moves since the last capture or pawn move
        uint32 whiteState;
        uint32 blackState;
        uint32 turnStart; // when the side to move got the turn
        uint40 closeBlock; // the last block the side to move's move can be bid for in: the dice are its hash
        bool main; // the main duel
        // each team's top bid for its next move (by team: 0 currency0's, 1 currency1's); the side to move's is the
        // move being bid for now. Played bids keep their fields (a flag, not zeroes, so the next bid rewrites warm
        // storage)
        TopBid[2] bids;
        // the last move played
        uint16 movePly;
        uint32 moveGameNo;
        address moveOwner;
        uint16 moveStrength;
        uint8 moveCaptured; // piece type taken, 0 none
        bool moveCheck;
        bool moveBlack;
        uint8 moveResult; // game result if the move ended the game: 1 white, 2 black, 3 draw
        uint256 board;
    }

    /// A team's top bid for its next move. Owner 0 is a move for nobody: a timeout's (size 0) or one whose dice hash
    /// expired (its paid size and strength kept, _resolve).
    struct TopBid {
        address owner;
        uint16 strength;
        bool open; // a bid is waiting for its move
        uint128 size; // what it paid, in the other team's token
    }

    /// A bid for a turn (all zero for a timeout turn).
    struct Trade {
        uint256 size; // what it paid, in the other team's token
        address owner;
        uint16 strength;
    }

    mapping(PoolId => Game) internal games; // read through game(id)
    // The last 16 final positions as 64-bit keys, four to a slot: lane (ply % 16) holds the position after that
    // half-move, even lanes in slots 0-1 and odd lanes in slots 2-3, so each side's eight are two reads.
    // Provisional or replaced positions never enter this ring.
    mapping(PoolId => uint256[4]) internal recentPositions;
    // war chests per pool: currency0's team in the low 128 bits, currency1's team in the high 128 (read: chest)
    mapping(PoolId => uint256) internal chests;
    // The main duel, $IMDUEL / IMD: the first pool opened on this hook. The IMD launch factory deploys the hook, mints
    // $IMDUEL and opens this pool in one transaction, so $IMDUEL's address isn't known at construction.
    Currency public imduel;
    PoolId public mainId;
    // Each pool's pot inflow this game, for the mate's inflow cap: the game number in the top 32 bits, then pot 1's
    // and pot 0's inflow in 112 bits each (the pot fee only, half of every trade's into each; donations and slices
    // don't count), recorded after the trade's move for the game then in progress, so a trade that ends a game counts
    // for the next one. A slot left by an earlier game reads as empty, so nothing is cleared between games. Read
    // through gameInflow.
    mapping(PoolId => uint256) internal gameIn;
    mapping(address => mapping(uint256 => uint256)) public owed; // rewards to claim (withdraw), by currency id
    // Per player: [0] counts per move, [1] rarer counts (layout at stats()); never read by any rule of the game
    mapping(address => uint256[2]) internal counts;
    address[] public players; // every address that has owned a played move in the main duel, in order of its first

    event GameStarted(PoolId indexed pool, uint32 gameNo);
    event Moved(
        PoolId indexed pool,
        uint32 gameNo,
        uint16 ply,
        uint16 move,
        address owner,
        uint256 size,
        uint16 strengthBps,
        uint8 captured, // piece type taken (1 pawn .. 5 queen), 0 none
        bool check
    );
    event Bid(PoolId indexed pool, uint32 gameNo, uint16 ply, address owner, uint256 size, uint16 strengthBps); // the top bid for half-move `ply` so far
    event GameOver(PoolId indexed pool, uint32 gameNo, uint8 result, uint16 plies); // 1 white, 2 black, 3 draw
    event DrawTriggered(PoolId indexed pool, uint32 gameNo, uint8 reason, uint16 plies); // 1 stalemate, 2 material, 3 repetition, 4 quiet, 5 cap, 6 engine
    event EngineFailed(PoolId indexed pool, uint32 gameNo, uint16 ply);
    // a mate's payout, recorded for the mating move's owner to claim, in the loser's currency
    event MatePaid(PoolId indexed pool, uint32 gameNo, address owner, Currency currency, uint256 amount);
    event Withdrawn(address indexed who, Currency currency, uint256 amount);
    event ChestFunded(PoolId indexed pool, address indexed from, Currency currency, uint256 amount);
    event MainDuel(PoolId indexed pool, Currency imduel);
    // URC-2: the hook's own delta of a swap (the hook fee), in pool token order from the swapper's side, so indexers
    // add it to the PoolManager's Swap event and see what the trader really paid
    event HookSwap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint24 swapFee);

    error NotManager();
    error NotLive();
    error BadValue();
    error BadConfig();
    error NotEnoughGas(); // the engine ran out of gas: send the trade with more
    error NoRoute(); // a duel pairs IMD or $IMDUEL, so its slice has a main duel pot to go to
    error PartialFill(); // the trade's price limit stopped it before its whole order traded

    /// Plain arguments, as the IMD launch factory passes them (launch.json): the PoolManager, the engine, IMD (the
    /// currency the main duel pairs with; native ETH for an ETH-paired launch) and how many blocks a move stays open
    /// for bids (3 on Ethereum, about 36 seconds; at least 1).
    constructor(IPoolManager manager_, IChessEngine engine_, Currency imd_, uint256 turnBlocks_) {
        // the engine is not checked here: the launch's admission tests build the hook on a chain where it has no code
        // (hook job f7f2a606); its address is checked off chain (with no engine there every game ends as a draw at its
        // first move: _endByEngine)
        if (address(engine_) == address(0) || turnBlocks_ == 0 || turnBlocks_ > 1_000) revert BadConfig();
        turnBlocks = turnBlocks_;
        (manager, engine, imd) = (manager_, engine_, imd_);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------- views

    /// The callbacks this hook uses, which its address carries (v4's BaseHook convention: the IMD launch reads it).
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        (p.afterInitialize, p.beforeSwap, p.afterSwap, p.beforeSwapReturnDelta, p.afterSwapReturnDelta) =
        (true, true, true, true, true);
    }

    function game(PoolId id) external view returns (Game memory) {
        return games[id];
    }

    /// The war chest of a pool's team `i` (0: currency0's, 1: currency1's), in balance claims.
    function chest(PoolId id, uint256 i) public view returns (uint256) {
        return i == 0 ? uint128(chests[id]) : chests[id] >> 128;
    }

    /// A player's counts, two words of fixed-width fields (each stops at its maximum, never wraps). `moves`, from bit
    /// 0: moves played with each piece (pawn, bishop, knight, rook, queen, king; 20 bits each), pieces taken by type
    /// (pawn, bishop, knight, rook, queen; 16 bits each, from bit 120), checks (20 bits, from 200), promotions (12,
    /// 220), castles (12, 232), moves at full strength (12, 244). `rare`: mating moves (16, bit 0), en passant
    /// captures (12, 16), a pawn taking a queen (12, 28), the king taking a piece (12, 40), games played in (24, 52),
    /// the last game played in (32, 76: a tag), the first main-duel game played in plus one (32, 108), IMD won and
    /// $IMDUEL won in units of 10^15 wei (40 bits each, 140 and 180). Moves count for the owner of the bid that played
    /// them, in the main duel only; timeout moves count for nobody.
    function stats(address who) external view returns (uint256 moves, uint256 rare) {
        (moves, rare) = (counts[who][0], counts[who][1]);
    }

    function playerCount() external view returns (uint256) {
        return players.length;
    }

    /// What trading put into pool `id`'s pots during its game `gameNo` (the pot fee, half of every trade's into each:
    /// donations and slices don't count), in each pot's own token. A mate in that game pays at most MATE_INFLOW_CAP
    /// times the loser's.
    function gameInflow(PoolId id, uint32 gameNo) public view returns (uint256 in0, uint256 in1) {
        uint256 w = gameIn[id];
        if (w >> 224 == gameNo) (in0, in1) = (w & IN_MAX, (w >> 112) & IN_MAX);
    }

    /// The team (0: currency0's, 1: currency1's) playing a side in a game. In game 0 White is the team of the token
    /// people buy, the side that isn't the base (the main duel: $IMDUEL, so buyers move first at launch, when the pool
    /// holds no IMD to sell for); colours alternate every game.
    function teamOf(uint8 base, uint32 gameNo, bool black) internal pure returns (uint256) {
        return (gameNo & 1) ^ (black ? 1 : 0) ^ (base ^ 1);
    }

    // ---------------------------------------------------------------- hook callbacks

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external returns (bytes4) {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        g.live = true;
        (Currency c0, Currency c1) = (key.currency0, key.currency1);
        if (imduel.isAddressZero()) {
            // the first pool is the main duel: it must pair IMD with a token, $IMDUEL (else the opening reverts)
            Currency token = c0 == imd ? c1 : c0;
            if (!(c0 == imd || c1 == imd) || token.isAddressZero()) revert BadConfig();
            (imduel, mainId) = (token, id);
            g.main = true;
            emit MainDuel(id, token);
        }
        // every duel's slice goes to a main duel pot: one side must be IMD or $IMDUEL
        if (!(c0 == imd || c1 == imd || c0 == imduel || c1 == imduel)) revert NoRoute();
        g.base = c1 == imd ? 1 : c0 == imd ? 0 : c1 == imduel ? 1 : 0;
        g.slice = c1 == imduel ? 1 : c0 == imduel ? 0 : g.base;
        _newGame(id, g);
        return IHooks.afterInitialize.selector;
    }

    /// Takes the parts of the fee due in the specified currency; the rest is taken in afterSwap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyManager();
        PoolId id = key.toId();
        int256 a = params.amountSpecified;
        int128 taken = _takeFee(id, key, _specified(params), uint256(a < 0 ? -a : a), games[id]);
        _stash(taken);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(taken, 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        int128 taken = _unstash();
        uint256 specIdx = _specified(params);
        // the whole order, less the fee taken before the swap, must have traded: that fee counted all of it, so a trade
        // its price limit stopped early would pay it on what never traded
        if (int256(specIdx == 0 ? delta.amount0() : delta.amount1()) != params.amountSpecified + taken) {
            revert PartialFill();
        }
        uint256 unspecIdx = 1 - specIdx;
        int128 fee = _takeFee(id, key, unspecIdx, _abs(unspecIdx == 0 ? delta.amount0() : delta.amount1()), g);
        (int128 hook0, int128 hook1) = specIdx == 0 ? (taken, fee) : (fee, taken);
        if (hook0 != 0 || hook1 != 0) emit HookSwap(id, sender, -hook0, -hook1, HOOK_FEE_PIPS); // URC-2: only when the hook took something
        _play(id, key, g, params.zeroForOne, delta, hookData);
        (uint256 in0, uint256 in1) = _unpend();
        if (in0 | in1 != 0) _addInflow(id, g.gameNo, in0, in1);
        return (IHooks.afterSwap.selector, fee);
    }

    // ---------------------------------------------------------------- fees and chests

    /// Takes the pot fee and the slice that fall in currency `idx` of a trade side of `amount`, as balance claims: half
    /// the pot fee from each side into that side's token's pot, so every trade feeds both pots by about the same value
    /// and they stay balanced with no price read; the slice on the pool's slice side (_slice).
    function _takeFee(PoolId id, PoolKey calldata key, uint256 idx, uint256 amount, Game storage g)
        internal
        returns (int128)
    {
        uint256 toChest = _addChest(id, idx, amount * CHEST_BPS / 20_000); // half the pot fee, from this side
        if (toChest != 0) _pend(idx, toChest); // the game's inflow, counted after the trade's move (afterSwap)
        Currency c = idx == 0 ? key.currency0 : key.currency1;
        uint256 fee = toChest + (g.slice == idx ? _slice(c, amount * SLICE_BPS / 10_000) : 0);
        if (fee == 0) return 0;
        manager.mint(address(this), c.toId(), fee);
        // fee is under 1% of a v4 swap amount, which fits int128
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(int256(fee));
    }

    /// Books a protocol slice of `amount` in `c` (the caller mints it) and returns what was taken: $IMDUEL is burned,
    /// owed to 0x...dEaD (anyone's withdraw sends it); IMD (a duel without $IMDUEL) goes to the main duel's IMD pot,
    /// what fits.
    function _slice(Currency c, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        if (c == imd) return _addChest(mainId, imd < imduel ? 0 : 1, amount);
        owed[DEAD][c.toId()] += amount;
        return amount;
    }

    /// Adds up to `amount` to chest `i` and returns what fit: a chest holds at most 2^128 - 1 (a token with more
    /// than ~3.4e20 whole tokens of supply), past that the chest share is simply not taken.
    function _addChest(PoolId id, uint256 i, uint256 amount) internal returns (uint256) {
        uint256 both = chests[id];
        uint256 have = i == 0 ? uint128(both) : both >> 128;
        uint256 room = type(uint128).max - have;
        if (amount > room) amount = room;
        if (amount != 0) chests[id] = both + (i == 0 ? amount : amount << 128);
        return amount;
    }

    function _takeChest(PoolId id, uint256 i, uint256 amount) internal {
        chests[id] -= i == 0 ? amount : amount << 128;
    }

    /// Adds `in0` and `in1` to the pots' inflow of game `gameNo` (gameIn) in one write, starting the slot over when it
    /// holds an earlier game; each saturates at IN_MAX.
    function _addInflow(PoolId id, uint32 gameNo, uint256 in0, uint256 in1) internal {
        uint256 w = gameIn[id];
        (uint256 have0, uint256 have1) = w >> 224 == gameNo ? (w & IN_MAX, (w >> 112) & IN_MAX) : (0, 0);
        uint256 n0 = in0 >= IN_MAX - have0 ? IN_MAX : have0 + in0;
        uint256 n1 = in1 >= IN_MAX - have1 ? IN_MAX : have1 + in1;
        gameIn[id] = (uint256(gameNo) << 224) | (n1 << 112) | n0;
    }

    function _send(Currency c, address to, uint256 amount) internal {
        manager.burn(address(this), c.toId(), amount);
        manager.take(c, to, amount);
    }

    /// Sends `who` their rewards in `c`. Anyone can call it; the tokens only ever go to `who`.
    function withdraw(address who, Currency c) external {
        _withdraw(who, c, who);
    }

    /// The same for the caller's own rewards, sent to `to`: for an owner that can't receive them itself (a contract
    /// without receive(), an address the token blocks).
    function withdrawTo(Currency c, address to) external {
        // address 0 would burn native ETH where a token reverts; the hook or the manager would lose it in their books
        if (to == address(0) || to == address(this) || to == address(manager)) revert BadValue();
        _withdraw(msg.sender, c, to);
    }

    /// Sends all but 1 wei: the 1 wei stays owed, so the owner's next reward updates a slot instead of creating one.
    function _withdraw(address who, Currency c, address to) internal {
        uint256 amount = owed[who][c.toId()];
        if (amount <= 1) return;
        owed[who][c.toId()] = 1;
        manager.unlock(abi.encode(uint8(0), abi.encode(to, c, amount - 1)));
        emit Withdrawn(who, c, amount - 1);
    }

    /// Adds to a team's war chest. Anyone can; the chest records what actually arrived. For native ETH send exactly
    /// `amount` as value; for tokens approve the hook first. A bigger pot makes its team's buys weaker (strength is a
    /// buy's share of its own pot), and a donation never counts as a game's inflow.
    function fundChest(PoolKey calldata key, bool inCurrency1, uint256 amount) external payable {
        PoolId id = key.toId();
        if (!games[id].live) revert NotLive();
        Currency c = inCurrency1 ? key.currency1 : key.currency0;
        if (msg.value != (c.isAddressZero() ? amount : 0)) revert BadValue();
        uint256 paid = abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(msg.sender, c, amount))), (uint256));
        if (_addChest(id, inCurrency1 ? 1 : 0, paid) != paid) revert BadValue(); // the chest is full
        emit ChestFunded(id, msg.sender, c, paid);
    }

    function unlockCallback(bytes calldata data) public virtual returns (bytes memory) {
        _onlyManager();
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        (address who, Currency c, uint256 amount) = abi.decode(body, (address, Currency, uint256));
        if (action == 0) {
            _send(c, who, amount);
            return "";
        }
        manager.sync(c);
        uint256 paid;
        if (c.isAddressZero()) {
            paid = manager.settle{value: amount}();
        } else {
            // the return value is not read (some tokens return nothing): settle() credits what actually arrived
            (bool ok,) =
                Currency.unwrap(c).call(abi.encodeCall(IERC20Min.transferFrom, (who, address(manager), amount)));
            if (!ok) revert BadValue();
            paid = manager.settle();
        }
        manager.mint(address(this), c.toId(), paid);
        return abi.encode(paid);
    }

    // ---------------------------------------------------------------- moves: every buy bids

    /// The game side of a swap: a move whose window has closed is played first; then this trade bids for its team's
    /// next move (the move being bid for now, if its team is to move) and takes the top spot if it pays more than
    /// RAISE_PCT over the current top; a trade of the other team after TURN_TIMEOUT of silence opens the silent side's
    /// move at 0%.
    function _play(
        PoolId id,
        PoolKey calldata key,
        Game storage g,
        bool zeroForOne,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal {
        uint256 mover = teamOf(g.base, g.gameNo, g.ply & 1 == 1);
        if (g.bids[mover].open && block.number > g.closeBlock) {
            _resolve(id, key, g, mover);
            mover = teamOf(g.base, g.gameNo, g.ply & 1 == 1);
        }
        uint256 team = zeroForOne ? 1 : 0; // the token bought
        TopBid storage b = g.bids[team];
        (uint256 paid, uint256 got) =
            team == 1 ? (_abs(delta.amount0()), _abs(delta.amount1())) : (_abs(delta.amount1()), _abs(delta.amount0()));
        if (team == mover) {
            if (_beats(paid, b)) {
                // the move's first bid in its window's last block or after it (the window passed without a bid, else
                // _resolve just played or reopened it): a full window from this block, so the team can answer it
                // (swarm audit 74895075, L-1: a dust bid there played a silent team's move at 0% with no answer)
                if (!b.open && block.number >= g.closeBlock) g.closeBlock = uint40(block.number + turnBlocks - 1);
                _bid(id, g, team, g.ply, _trade(id, team, paid, got, hookData));
            }
        } else {
            if (_beats(paid, b)) _bid(id, g, team, g.ply + 1, _trade(id, team, paid, got, hookData));
            if (!g.bids[mover].open && block.timestamp >= g.turnStart + TURN_TIMEOUT) {
                // the silent side's move, at 0% for nobody; a real bid in this block takes it
                g.closeBlock = uint40(block.number);
                _bid(id, g, mover, g.ply, Trade(0, address(0), 0));
            }
        }
    }

    /// The trade a bid is made with: its owner (_owner) and its strength from what it received as a share of its own
    /// team's pot, read now (after any move this trade played has been paid), so only money given to the game moves it.
    function _trade(PoolId id, uint256 team, uint256 paid, uint256 got, bytes calldata hookData)
        internal
        view
        returns (Trade memory)
    {
        return Trade(paid, _owner(hookData), Strength.fromShare(got, chest(id, team)));
    }

    /// Who a trade bids for: the address in its hookData, 20 bytes packed or 32 bytes ABI-encoded (a zero address,
    /// the hook or the PoolManager counts as none: rewards owed to those could never be claimed; so does 0x...dEaD,
    /// whose owed balance is the burn and which must not play or list), else the wallet
    /// that signed the transaction, so a trade through any router or aggregator earns. Known and accepted: a trade
    /// relayed for a smart-contract wallet without hookData credits the relayer.
    function _owner(bytes calldata hookData) internal view returns (address owner) {
        if (hookData.length == 20) {
            owner = address(bytes20(hookData));
        } else if (hookData.length == 32 && uint256(bytes32(hookData)) <= type(uint160).max) {
            owner = address(uint160(uint256(bytes32(hookData))));
        }
        if (owner == address(0) || owner == address(this) || owner == address(manager) || owner == DEAD) {
            owner = tx.origin;
        }
    }

    /// Whether a trade that paid `paid` takes the top spot from bid `b`: there is none, or it pays more than RAISE_PCT over it.
    function _beats(uint256 paid, TopBid storage b) internal view returns (bool) {
        return !b.open || paid * 100 > uint256(b.size) * (100 + RAISE_PCT);
    }

    /// Makes `t` team `team`'s top bid for half-move `ply`.
    function _bid(PoolId id, Game storage g, uint256 team, uint16 ply, Trade memory t) internal {
        TopBid storage b = g.bids[team];
        // a bid's size is a swap amount (an int128's magnitude) or a kept bid's size: it fits
        // forge-lint: disable-next-line(unsafe-typecast)
        (b.owner, b.strength, b.open, b.size) = (t.owner, t.strength, true, uint128(t.size));
        emit Bid(id, g.gameNo, ply, t.owner, t.size, t.strength);
    }

    /// Plays the side to move's move (team `mover`) at its top bid's strength. The dice are the hash of the window's
    /// last block, which didn't exist while anyone could still bid, except for that block's builder (see the contract
    /// notes). A move whose block hash the chain no longer serves (after 8,191 blocks, about a day) keeps its bid's
    /// strength and size but is played for nobody, its window this block (its hash the dice): the board still gets
    /// the paid strength, and letting a seen move expire to draw it again can never pay (audit 2026-11-01). If the
    /// engine fails (it shouldn't), a seeded legal move is played at 0%; if that fails too, the game ends as a draw. An engine starved by the trade's
    /// gas limit reverts the trade, so gas estimates include the move.
    function _resolve(PoolId id, PoolKey calldata key, Game storage g, uint256 mover) internal {
        bytes32 h = _hashOf(g.closeBlock);
        if (h == 0) {
            g.closeBlock = uint40(block.number);
            TopBid memory kept = g.bids[mover];
            return _bid(id, g, mover, g.ply, Trade(kept.size, address(0), kept.strength));
        }
        TopBid memory b = g.bids[mover];
        Trade memory t = Trade(b.size, b.owner, b.strength);
        (bool ok, bool fell, uint16 m, Rules.Played memory r) = _choose(id, g, t, h);
        if (fell) emit EngineFailed(id, g.gameNo, g.ply);
        if (!ok) return _endByEngine(id, g, mover); // both calls failed: the game ends as a draw
        if (fell) t.strength = 0;
        _apply(id, g, m, r, t, mover);
        if (g.moveResult == (g.moveBlack ? 2 : 1)) _payMate(id, key, g, t, mover);
    }

    /// The move a bid plays: the engine's at the bid's strength with dice from `h`; if the engine fails (it shouldn't),
    /// a seeded legal move (`fell`); if that fails too, none (`ok` false: the game ends as a draw, _endByEngine). An
    /// engine starved by the trade's gas limit reverts the trade, so a failure seen here is the position's, not the gas.
    function _choose(PoolId id, Game storage g, Trade memory t, bytes32 h)
        internal
        view
        returns (bool ok, bool fell, uint16 m, Rules.Played memory r)
    {
        uint256 seed = uint256(keccak256(abi.encode(h, id, g.gameNo, g.ply, t.owner, t.size)));
        bool black = g.ply & 1 == 1;
        (uint32 own, uint32 other) = black ? (g.blackState, g.whiteState) : (g.whiteState, g.blackState);
        (ok, m, r) = _engine(
            ENGINE_GAS,
            abi.encodeCall(
                IChessEngine.play,
                (g.board, own, other, black, uint256(t.strength), seed, _history(id, g.ply, g.quiet), g.gameNo, g.quiet)
            )
        );
        if (ok) return (ok, false, m, r);
        _enoughGas(ENGINE_GAS);
        (ok, m, r) = _engine(FALLBACK_GAS, abi.encodeCall(IChessEngine.playAny, (g.board, own, other, black, seed)));
        if (!ok) _enoughGas(FALLBACK_GAS);
        return (ok, true, m, r);
    }

    /// The move the side to move will play, exactly as the next trade will play it, given the hash `h` of its window's
    /// last block: fixed as soon as that block is complete, which is before the chain can read the hash itself (false
    /// before that block, or without a bid). A view for the site to show each move as soon as it is fixed: called at the
    /// latest block, it runs after all of that block's trades. A caller inside the closing block itself gets an answer
    /// a later trade in that block can still change (it can still take the top bid). Once the chain serves that hash
    /// it is read here instead of `h`, and a hash it no longer serves means the next trade reopens the window: false.
    function previewMove(PoolId id, bytes32 h) external view returns (bool ready, uint16 move) {
        Game storage g = games[id];
        TopBid memory b = g.bids[teamOf(g.base, g.gameNo, g.ply & 1 == 1)];
        if (!b.open || block.number < g.closeBlock) return (false, 0);
        if (block.number > g.closeBlock && (h = _hashOf(g.closeBlock)) == 0) return (false, 0);
        (bool ok,, uint16 m,) = _choose(id, g, Trade(b.size, b.owner, b.strength), h);
        return (ok, m);
    }

    /// Both engine calls failed on this position (an engine bug: a starved call reverts the trade instead), so the
    /// move can never be played: the game ends as a draw (reason 6) and the next starts from a fresh position, so the
    /// pool's pots stay reachable and nothing is paid. Without this the pool would freeze for good (audit 2026-10-31).
    function _endByEngine(PoolId id, Game storage g, uint256 mover) internal {
        g.bids[mover].open = false;
        emit DrawTriggered(id, g.gameNo, 6, g.ply);
        emit GameOver(id, g.gameNo, 3, g.ply);
        g.gameNo++;
        _newGame(id, g);
    }

    /// The hash of block `n` (an earlier block), or 0 once the chain no longer serves it.
    function _hashOf(uint256 n) internal view returns (bytes32 h) {
        if (block.number - n <= 256) return blockhash(n);
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(n));
        if (ok && out.length == 32) h = abi.decode(out, (bytes32));
    }

    /// After a failed engine call: if it failed because the trade's gas limit starved it (63/64 rule), revert.
    function _enoughGas(uint256 cap) internal view {
        if (gasleft() < cap / 63) revert NotEnoughGas();
    }

    /// Calls the engine with a gas cap; ok only for a well-formed answer.
    function _engine(uint256 gasCap, bytes memory data) internal view returns (bool, uint16, Rules.Played memory r) {
        if (gasleft() < gasCap + gasCap / 63 + ENGINE_RETURN_GAS) revert NotEnoughGas();
        (bool ok, bytes memory result) = address(engine).staticcall{gas: gasCap}(data);
        if (!ok || result.length != 224) return (false, 0, r);
        uint16 m;
        (m, r) = abi.decode(result, (uint16, Rules.Played));
        return (m < 4096, m, r);
    }

    /// This side's last eight positions, most recent first. None can repeat until four reversible half-moves have
    /// passed (the position after this move needs quiet >= 4), so they are skipped before that.
    function _history(PoolId id, uint16 ply, uint16 quiet) internal view returns (uint64[8] memory previous) {
        if (quiet < 3) return previous;
        (uint256 lo, uint256 hi) = _lanes(id, ply);
        for (uint256 i; i < 8; i++) {
            previous[i] = _key(lo, hi, ((ply + 14 - i * 2) % 16) >> 1);
        }
    }

    /// Records a move played by the rules (`r`: the new position and how the game stands), clears its bid and opens
    /// the next move's window.
    function _apply(PoolId id, Game storage g, uint16 move, Rules.Played memory r, Trade memory t, uint256 team)
        internal
    {
        bool black = g.ply & 1 == 1;
        g.bids[team].open = false;
        uint256 board = g.board;
        uint8 captured = _captured(board, move);
        uint8 piece = Chess.typeAt(board, move >> 6);
        bool pawn = piece == 1;
        g.board = r.board;
        (g.whiteState, g.blackState) = black ? (r.other, r.mover) : (r.mover, r.other);
        g.quiet = (captured != 0 || pawn) ? 0 : g.quiet + 1;
        (g.movePly, g.moveGameNo, g.moveOwner, g.moveStrength) = (g.ply, g.gameNo, t.owner, t.strength);
        (g.moveCaptured, g.moveCheck, g.moveBlack, g.moveResult) = (captured, r.check, black, 0);
        emit Moved(id, g.gameNo, g.ply, move, t.owner, t.size, t.strength, captured, r.check);
        g.ply++;
        _openTurn(g);

        // game end: the side now to move has no legal move, or a draw rule applies
        uint8 result;
        if (r.status == 2) {
            result = black ? 2 : 1;
        } else {
            uint8 reason;
            if (r.status == 1) reason = 1;
            else if (r.insufficient) reason = 2;
            else if (_repeated(id, g)) reason = 3;
            else if (g.quiet >= MAX_QUIET_PLY) reason = 4;
            else if (g.ply >= MAX_PLY) reason = 5;
            if (reason != 0) {
                result = 3;
                emit DrawTriggered(id, g.gameNo, reason, g.ply);
            }
        }
        // the main duel only: a side duel costs its creator nothing and its empty pots play at the cap, so its counts
        // could be farmed for gas (audit 2026-10-31). Every trade bids, and every move it plays counts (user, 2026-11-02:
        // a move of yours always counts; farming one costs the move's gas, ~330k)
        if (t.owner != address(0) && g.main) {
            _count(id, g, t, move, board, piece, captured, r.check, result == (black ? 2 : 1));
        }
        if (result != 0) {
            g.moveResult = result;
            emit GameOver(id, g.gameNo, result, g.ply);
            g.gameNo++;
            _newGame(id, g);
        } else {
            // the position after this move joins the repetition memory, in the lane of its half-move
            (uint256 slot, uint256 shift) = _laneAt(g.ply - 1);
            uint256 w = recentPositions[id][slot];
            uint64 k = Chess.positionKey(g.board, g.whiteState, g.blackState, g.ply & 1 == 1, g.gameNo);
            recentPositions[id][slot] = (w & ~(uint256(type(uint64).max) << shift)) | (uint256(k) << shift);
        }
    }

    /// Pays a mate by `team`'s move `t`: a quarter of the losing team's pot to the move's owner, in the loser's token,
    /// at most PAYOUT_CAP times what its trade paid (in that same token) and at most MATE_INFLOW_CAP times what the
    /// game's trades paid into that pot (a game played for dust pays nothing, and a game a player trades alone pays
    /// back at most its own 0.325% into that pot, under the 0.75% it was charged); all in one token, no price.
    /// The rest stays in the pot. A move for nobody (a timeout) pays nobody. Recorded to claim (withdraw), never sent
    /// inside the trade; in the main duel what it paid counts for its owner.
    function _payMate(PoolId id, PoolKey calldata key, Game storage g, Trade memory t, uint256 team) internal {
        if (t.owner == address(0)) return;
        uint256 loser = 1 - team;
        (uint256 in0, uint256 in1) = gameInflow(id, g.moveGameNo);
        uint256 amount = _min(chest(id, loser) * MATE_SHARE_BPS / 10_000, t.size * PAYOUT_CAP);
        amount = _min(amount, (loser == 0 ? in0 : in1) * MATE_INFLOW_CAP);
        if (amount == 0) return;
        _takeChest(id, loser, amount);
        Currency c = loser == 0 ? key.currency0 : key.currency1;
        owed[t.owner][c.toId()] += amount;
        if (g.main) _countWon(t.owner, c, amount);
        emit MatePaid(id, g.moveGameNo, t.owner, c, amount);
    }

    // ---------------------------------------------------------------- player counts (badges and display only)

    /// Adds a played move to its owner's counts (the first one also lists the owner in players).
    function _count(
        PoolId id,
        Game storage g,
        Trade memory t,
        uint16 move,
        uint256 board,
        uint8 piece,
        uint8 captured,
        bool check,
        bool mate
    ) internal {
        uint256[2] storage w = counts[t.owner];
        (uint256 a, uint256 b) = (w[0], w[1]);
        if (a == 0 && b == 0) players.push(t.owner);
        uint256 from = move >> 6;
        uint256 to = move & 63;
        a = _add(a, (uint256(piece) - 1) * 20, 20, 1);
        if (captured != 0) a = _add(a, 120 + (uint256(captured) - 1) * 16, 16, 1);
        if (check) a = _add(a, 200, 20, 1);
        if (piece == 1 && (to >> 3 == 7 || to >> 3 == 0)) a = _add(a, 220, 12, 1);
        if (piece == 6 && ((from & 7) + 2 == (to & 7) || (to & 7) + 2 == (from & 7))) a = _add(a, 232, 12, 1); // castling
        if (t.strength >= Strength.MAX_BPS) a = _add(a, 244, 12, 1);
        uint256 b0 = b;
        if (mate) b = _add(b, 0, 16, 1);
        if (piece == 1 && captured == 1 && Chess.typeAt(board, to) == 0) b = _add(b, 16, 12, 1); // en passant
        if (piece == 1 && captured == 5) b = _add(b, 28, 12, 1);
        if (piece == 6 && captured != 0) b = _add(b, 40, 12, 1);
        uint256 tag = uint32(uint256(keccak256(abi.encode(id, g.gameNo))));
        if ((b >> 76) & 0xffffffff != tag) b = _add((b & ~(uint256(0xffffffff) << 76)) | (tag << 76), 52, 24, 1);
        if (g.main && (b >> 108) & 0xffffffff == 0) b |= (uint256(g.gameNo) + 1) << 108;
        w[0] = a;
        if (b != b0) w[1] = b;
    }

    /// Adds what a mate won to its owner's counts: the amount in IMD or in $IMDUEL.
    function _countWon(address o, Currency c, uint256 amount) internal {
        counts[o][1] = _add(counts[o][1], c == imd ? 140 : 180, 40, amount / 1e15);
    }

    /// Adds `by` to the `bits`-wide field at `shift` of `w`, stopping at the field's maximum (whatever `by` is).
    function _add(uint256 w, uint256 shift, uint256 bits, uint256 by) internal pure returns (uint256) {
        uint256 max = (1 << bits) - 1;
        uint256 v = (w >> shift) & max;
        uint256 n = by >= max - v ? max : v + by;
        return (w & ~(max << shift)) | (n << shift);
    }

    // ---------------------------------------------------------------- position memory

    /// Ring slot and bit offset of the lane for half-move `ply`.
    function _laneAt(uint256 ply) internal pure returns (uint256 slot, uint256 shift) {
        uint256 l = ply % 16;
        uint256 k = l >> 1;
        (slot, shift) = ((l & 1) * 2 + (k >> 2), (k & 3) * 64);
    }

    /// The two ring slots holding the lanes with the same parity as `ply`.
    function _lanes(PoolId id, uint256 ply) internal view returns (uint256 lo, uint256 hi) {
        uint256 s = (ply & 1) * 2;
        (lo, hi) = (recentPositions[id][s], recentPositions[id][s + 1]);
    }

    /// The k-th (0-7) key of one parity: half-move index k of that parity's lanes.
    function _key(uint256 lo, uint256 hi, uint256 k) internal pure returns (uint64) {
        return uint64((k < 4 ? lo : hi) >> ((k & 3) * 64));
    }

    /// Whether the position just reached is there for the third time, counting itself and the positions up to sixteen
    /// half-moves earlier (the ring's eight of this side to move, the oldest written over only after this check), and
    /// the start position from any distance.
    function _repeated(PoolId id, Game storage g) internal view returns (bool) {
        // A position needs at least four reversible half-moves to recur (each side out and back), and nothing before
        // the last capture or pawn move can recur; skips the reads on most swaps.
        if (g.quiet < 4) return false;
        uint64 k = Chess.positionKey(g.board, g.whiteState, g.blackState, g.ply & 1 == 1, g.gameNo);
        uint256 seen;
        if (
            g.board == Chess.START_BOARD && g.whiteState == Chess.START_WHITE && g.blackState == Chess.START_BLACK
                && g.ply & 1 == 0
        ) seen = 1;
        // the key's side to move is g.ply's; those positions were made by half-moves of the other parity
        (uint256 lo, uint256 hi) = _lanes(id, g.ply + 1);
        for (uint256 i; i < 8; i++) {
            if (_key(lo, hi, i) == k && ++seen == 2) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- small helpers

    /// Which currency (0 or 1) the swap specified: the input for exact input, the output for exact output.
    function _specified(SwapParams calldata params) internal pure returns (uint256) {
        return params.zeroForOne == (params.amountSpecified < 0) ? 0 : 1;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    /// Piece type captured by `move` on `board`: the piece on the target square, or a pawn taken en passant.
    function _captured(uint256 board, uint16 move) internal pure returns (uint8) {
        uint256 from = move >> 6;
        uint256 to = move & 63;
        uint8 target = Chess.typeAt(board, to);
        if (target != 0) return target;
        if (Chess.typeAt(board, from) == 1 && (from & 7) != (to & 7)) return 1; // diagonal pawn move to an empty square
        return 0;
    }

    function _newGame(PoolId id, Game storage g) internal {
        g.board = Chess.START_BOARD;
        g.whiteState = Chess.START_WHITE;
        g.blackState = Chess.START_BLACK;
        g.ply = 0;
        g.quiet = 0;
        _openTurn(g);
        emit GameStarted(id, g.gameNo);
    }

    /// The side to move's move takes bids from this block through `turnBlocks` blocks.
    function _openTurn(Game storage g) internal {
        (g.turnStart, g.closeBlock) = (uint32(block.timestamp), uint40(block.number + turnBlocks - 1));
    }

    function _onlyManager() internal view {
        if (msg.sender != address(manager)) revert NotManager();
    }

    // transient storage: 1 the fee beforeSwap took, for afterSwap; 2 the swap's pot fee, for the game's inflow

    /// The fee taken before the swap (never negative), for afterSwap.
    function _stash(int128 taken) internal {
        assembly ("memory-safe") {
            tstore(1, taken)
        }
    }

    function _unstash() internal view returns (int128 taken) {
        assembly ("memory-safe") {
            taken := tload(1)
        }
    }

    /// A swap's pot fee into pot `i`, held until afterSwap counts it as the game's inflow: pot 0's in the low 128 bits,
    /// pot 1's in the high (a pot holds under 2^128, so neither spills).
    function _pend(uint256 i, uint256 toChest) internal {
        assembly ("memory-safe") {
            tstore(2, add(tload(2), shl(mul(i, 128), toChest)))
        }
    }

    function _unpend() internal returns (uint256 in0, uint256 in1) {
        assembly ("memory-safe") {
            let w := tload(2)
            in0 := and(w, 0xffffffffffffffffffffffffffffffff)
            in1 := shr(128, w)
            tstore(2, 0)
        }
    }
}
