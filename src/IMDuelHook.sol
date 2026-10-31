// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
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
/// `turnBlocks` blocks after the previous one was played; the first trade after that plays it, with the hash of the
/// window's last block as the dice, so a bidder can't know the move while it can still bid. The one exception is
/// whoever builds that last block: it can bid in it and try several versions of it, keeping the hash whose move pays
/// (an accepted risk).
/// Only checkmates pay: a mate takes a quarter of the losing team's pot and pays it to the move that mated, in the
/// loser's token, at most twice what that move's trade paid and at most twice what the game's trading put into the
/// pots (so a game played for dust pays nothing); whatever isn't paid stays in the pot. Rewards are
/// recorded and their owners claim them (withdraw): no reward
/// is ever sent inside a trade, so no recipient runs code while a trader's PoolManager is unlocked. (The one transfer a
/// trade can make is the slice batch's burn of $IMDUEL to 0x...dEaD, an address with no code, of a plain token with no
/// transfer callbacks, in a try/catch that can't revert the trade.) The owner is the address the trade names in
/// hookData, else the wallet that signed the transaction, so a trade through any router earns.
/// Money: 0.75% of every swap. 0.65% goes to the pool's pot (chest) worth less; 0.1% (the protocol slice) is converted
/// into $IMDUEL in batches, half added to the main duel's $IMDUEL pot and half burned. So every duel pairs a token with
/// IMD or $IMDUEL: one with no route to $IMDUEL can't open. A trade must swap its whole order: the fee part taken
/// before the swap counts all of it.
/// Stats: every player (an address) of the main duel has two words of counts (stats), kept for badges and display
/// only: they never pay or limit anything. Side duels count nothing (their empty pots play at the cap for free).
/// It implements only the callbacks its permission bits enable; the pool manager calls no others.
contract IMDuelHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- rules of play
    uint256 public constant TURN_TIMEOUT = 600; // seconds without a move before the side to move plays at 0%
    uint256 public constant RAISE_PCT = 10; // a new top bid pays more than this much over the current one
    uint16 public constant MAX_PLY = Chess.MAX_PLY;
    uint16 public constant MAX_QUIET_PLY = Chess.MAX_QUIET_PLY;
    // the engine's heaviest measured move is ~950k (test/EngineV5Games.t.sol); 3x that bounds what a pathological
    // position can cost: a trade with less gas than the cap needs reverts (NotEnoughGas), one with more gets the fallback
    uint256 internal constant ENGINE_GAS = 3_000_000;
    uint256 internal constant FALLBACK_GAS = 2_000_000;
    // EIP-2935: the last 8,191 block hashes (about a day), beyond the 256 the BLOCKHASH opcode serves
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    // ---------------------------------------------------------------- money
    uint256 public constant CHEST_BPS = 65;
    uint256 public constant SLICE_BPS = 10;
    uint24 public constant HOOK_FEE_PIPS = uint24((CHEST_BPS + SLICE_BPS) * 100); // the hook fee as URC-2 reports it (0.75%)
    uint256 public constant MATE_SHARE_BPS = 2_500; // a mate takes a quarter of the losing team's pot, for the move that mated
    uint256 public constant PAYOUT_CAP = 2; // a mate pays at most twice what its move's trade paid
    uint256 public constant MATE_INFLOW_CAP = 2; // and at most twice what the game's trading put into the pots
    uint256 internal constant IN_MAX = (1 << 112) - 1; // a pot's inflow in a game, as gameIn packs it
    uint256 internal constant CONVERT_GAS = 800_000;
    uint256 internal constant BATCH_SQRT_BPS = 10; // a conversion batch stops 0.1% of the sqrt price away (~0.2%)
    uint256 internal constant BATCH_MINS = 10; // a batch spends at most 10 minimums (_batch), one per block
    uint256 internal constant SAMPLE_BITS = 56; // a sampled sqrt price: 8-bit exponent, 48-bit mantissa (_pack)
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable manager;
    IChessEngine public immutable engine; // chooses each move and plays it by the rules (Rules.sol)
    Currency public immutable imd;
    uint256 internal immutable minImd; // smallest pile worth a conversion batch, per routing currency
    uint256 internal immutable minImduel;
    uint256 public immutable turnBlocks; // how many blocks a move stays open for bids once the previous one is played

    struct Game {
        bool live; // pool initialized with this hook
        uint8 slice; // which currency (0 or 1) the protocol slice is taken in
        uint32 gameNo; // the team of the token people buy (not the slice side) plays White in even games
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

    /// A team's top bid for its next move: owner 0 and size 0 for a timeout move.
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
    uint24 internal mainFee;
    int24 internal mainSpacing;
    PoolId public mainId;
    // The main duel's price samples, one slot (_sample): the block of the latest batch (40 bits), the block of the
    // latest sample (40), and the price at the start of the three latest sampled blocks (56 each, newest lowest).
    // A batch buys within 0.1% (sqrt) of the most hook-favourable of the three, so a price pushed inside a block, or
    // at the end of the block before, can't sell the hook $IMDUEL dear: it must be held through two public blocks.
    // Every trade and batch of the main duel samples it before moving its price.
    uint256 internal samples;
    // Each pool's pot inflow this game, for the mate's inflow cap: the game number in the top 32 bits, then pot 1's
    // and pot 0's inflow in 112 bits each (the pot fee only; donations don't count). A slot left by an earlier game
    // reads as empty, so nothing is cleared between games. Read through gameInflow.
    mapping(PoolId => uint256) internal gameIn;
    mapping(uint256 => uint256) public pile; // protocol slices waiting for conversion, by currency id
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
    event Converted(Currency indexed from, uint256 spent, uint256 bought, uint256 burned);
    event MainDuel(PoolId indexed pool, Currency imduel);
    // URC-2: the hook's own delta of a swap (the hook fee), in pool token order from the swapper's side, so indexers
    // add it to the PoolManager's Swap event and see what the trader really paid
    event HookSwap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint24 swapFee);

    error NotManager();
    error NotSelf();
    error NotLive();
    error BadValue();
    error BadConfig();
    error NotEnoughGas(); // the engine ran out of gas: send the trade with more
    error NoRoute(); // a duel pairs IMD or $IMDUEL, so its slice converts into $IMDUEL
    error PartialFill(); // the trade's price limit stopped it before its whole order traded

    /// Plain arguments, as the IMD launch factory passes them (launch.json): the PoolManager, the engine, IMD (the
    /// currency the main duel pairs with; native ETH for an ETH-paired launch), the smallest pile worth a conversion
    /// batch in IMD and in $IMDUEL (a batch spends at most BATCH_MINS of it), and how many blocks a move stays open
    /// for bids (3 on Ethereum, about 36 seconds; at least 1).
    constructor(IPoolManager manager_, IChessEngine engine_, Currency imd_, uint256 minImd_, uint256 minImduel_,
        uint256 turnBlocks_)
    {
        // the engine is not checked here: the launch's admission tests build the hook on a chain where it has no code
        // (hook job f7f2a606); its address is checked off chain, and a trade with no engine to answer just waits
        // a zero minimum would make every batch spend nothing (_batch), so the slice would never convert
        if (address(engine_) == address(0) || turnBlocks_ == 0 || turnBlocks_ > 1_000 || minImd_ == 0 || minImduel_ == 0) {
            revert BadConfig();
        }
        turnBlocks = turnBlocks_;
        (manager, engine, imd) = (manager_, engine_, imd_);
        (minImd, minImduel) = (minImd_, minImduel_);
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

    /// What trading put into pool `id`'s pots during its game `gameNo` (the pot fee only: donations don't count), in
    /// each pot's own token. A mate in that game pays at most MATE_INFLOW_CAP times both, valued in the loser's token.
    function gameInflow(PoolId id, uint32 gameNo) public view returns (uint256 in0, uint256 in1) {
        uint256 w = gameIn[id];
        if (w >> 224 == gameNo) (in0, in1) = (w & IN_MAX, (w >> 112) & IN_MAX);
    }

    /// The team (0: currency0's, 1: currency1's) playing a side in a game. In game 0 White is the team of the token
    /// people buy, the side the slice isn't taken in (the main duel: $IMDUEL, so buyers move first at launch, when
    /// the pool holds no IMD to sell for); colours alternate every game.
    function teamOf(uint8 slice, uint32 gameNo, bool black) internal pure returns (uint256) {
        return (gameNo & 1) ^ (black ? 1 : 0) ^ (slice ^ 1);
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
            (imduel, mainFee, mainSpacing, mainId) = (token, key.fee, key.tickSpacing, id);
            g.main = true;
            emit MainDuel(id, token);
        }
        // every duel's slice buys $IMDUEL: one side must be IMD or $IMDUEL
        if (!(c0 == imd || c1 == imd || c0 == imduel || c1 == imduel)) revert NoRoute();
        // the slice is taken in the side it converts from most simply: IMD, then $IMDUEL
        g.slice = c1 == imd ? 1 : c0 == imd ? 0 : c1 == imduel ? 1 : 0;
        _newGame(id, g);
        return IHooks.afterInitialize.selector;
    }

    /// Reads the pool's price once for the whole swap (which pot is worth less) and takes the parts of the fee due in
    /// the specified currency. The rest is taken in afterSwap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        (uint160 sqrtPrice,,,) = manager.getSlot0(id);
        if (g.main) _sample(sqrtPrice);
        uint256 chestIdx = _smallerChest(id, sqrtPrice);
        int256 a = params.amountSpecified;
        int128 taken = _takeFee(id, key, _specified(params), uint256(a < 0 ? -a : a), chestIdx, g);
        _stash(chestIdx, taken);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(taken, 0), 0);
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        returns (bytes4, int128)
    {
        _onlyManager();
        PoolId id = key.toId();
        Game storage g = games[id];
        (uint256 chestIdx, int128 taken) = _unstash();
        uint256 specIdx = _specified(params);
        // the whole order, less the fee taken before the swap, must have traded: that fee counted all of it, so a trade
        // its price limit stopped early would pay it on what never traded
        if (int256(specIdx == 0 ? delta.amount0() : delta.amount1()) != params.amountSpecified + taken) revert PartialFill();
        uint256 unspecIdx = 1 - specIdx;
        int128 fee = _takeFee(id, key, unspecIdx, _abs(unspecIdx == 0 ? delta.amount0() : delta.amount1()), chestIdx, g);
        (int128 hook0, int128 hook1) = specIdx == 0 ? (taken, fee) : (fee, taken);
        if (hook0 != 0 || hook1 != 0) emit HookSwap(id, sender, -hook0, -hook1, HOOK_FEE_PIPS); // URC-2: only when the hook took something
        if (!_locked()) {
            _lock(true);
            _play(id, key, g, params.zeroForOne, delta, hookData);
            _lock(false);
        }
        return (IHooks.afterSwap.selector, fee);
    }

    // ---------------------------------------------------------------- fees and chests

    /// Takes the chest share and the slice that fall in currency `idx` of a trade side of `amount`, as balance claims.
    function _takeFee(PoolId id, PoolKey calldata key, uint256 idx, uint256 amount, uint256 chestIdx, Game storage g)
        internal
        returns (int128)
    {
        uint256 toChest = chestIdx == idx ? _addChest(id, idx, amount * CHEST_BPS / 10_000) : 0;
        if (toChest != 0) _addInflow(id, g.gameNo, idx, toChest);
        uint256 toPile = g.slice == idx ? amount * SLICE_BPS / 10_000 : 0;
        uint256 fee = toChest + toPile;
        if (fee == 0) return 0;
        Currency c = idx == 0 ? key.currency0 : key.currency1;
        manager.mint(address(this), c.toId(), fee);
        if (toPile != 0) pile[c.toId()] += toPile;
        return int128(int256(fee));
    }

    /// The chest worth less at the pool's price (0 or 1), so the fee keeps both chests about equal.
    function _smallerChest(PoolId id, uint160 sqrtPrice) internal view returns (uint256) {
        uint256 both = chests[id];
        uint256 value0 = FullMath.mulDiv(FullMath.mulDiv(uint128(both), sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
        return value0 <= both >> 128 ? 0 : 1;
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

    /// Adds `amount` to pot `i`'s inflow of game `gameNo` (gameIn), starting the slot over when it holds an earlier game.
    function _addInflow(PoolId id, uint32 gameNo, uint256 i, uint256 amount) internal {
        uint256 w = gameIn[id];
        if (w >> 224 != gameNo) w = uint256(gameNo) << 224;
        uint256 shift = i * 112;
        uint256 have = (w >> shift) & IN_MAX;
        uint256 n = amount >= IN_MAX - have ? IN_MAX : have + amount;
        gameIn[id] = (w & ~(IN_MAX << shift)) | (n << shift);
    }

    /// What game `gameNo`'s trading put into both pots, in pot `loser`'s token: the other pot's inflow valued at the
    /// pool's price now. It can only lower a prize, never raise it above the quarter, so a pushed price gains nothing.
    function _inflowIn(PoolId id, uint32 gameNo, uint256 loser) internal view returns (uint256) {
        (uint256 in0, uint256 in1) = gameInflow(id, gameNo);
        (uint160 sqrtPrice,,,) = manager.getSlot0(id);
        return loser == 0
            ? in0 + FullMath.mulDiv(FullMath.mulDiv(in1, 1 << 96, sqrtPrice), 1 << 96, sqrtPrice)
            : in1 + FullMath.mulDiv(FullMath.mulDiv(in0, sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
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
    /// `amount` as value; for tokens approve the hook first.
    function fundChest(PoolKey calldata key, bool inCurrency1, uint256 amount) external payable {
        PoolId id = key.toId();
        if (!games[id].live) revert NotLive();
        Currency c = inCurrency1 ? key.currency1 : key.currency0;
        if (msg.value != (c.isAddressZero() ? amount : 0)) revert BadValue();
        uint256 paid = abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(msg.sender, c, amount))), (uint256));
        if (_addChest(id, inCurrency1 ? 1 : 0, paid) != paid) revert BadValue(); // the chest is full
        emit ChestFunded(id, msg.sender, c, paid);
    }

    /// Converts one batch of the protocol slice held in `c` now (it also happens by itself inside trades).
    function convert(Currency c) external {
        manager.unlock(abi.encode(uint8(2), abi.encode(address(0), c, uint256(0))));
    }

    function unlockCallback(bytes calldata data) public virtual returns (bytes memory) {
        _onlyManager();
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        (address who, Currency c, uint256 amount) = abi.decode(body, (address, Currency, uint256));
        if (action == 0) {
            _send(c, who, amount);
            return "";
        }
        if (action == 2) {
            _convert(c);
            return "";
        }
        manager.sync(c);
        uint256 paid;
        if (c.isAddressZero()) {
            paid = manager.settle{value: amount}();
        } else {
            // the return value is not read (some tokens return nothing): settle() credits what actually arrived
            (bool ok,) = Currency.unwrap(c).call(abi.encodeCall(IERC20Min.transferFrom, (who, address(manager), amount)));
            if (!ok) revert BadValue();
            paid = manager.settle();
        }
        manager.mint(address(this), c.toId(), paid);
        return abi.encode(paid);
    }

    // ---------------------------------------------------------------- the protocol slice

    function convertBatch(Currency c) external {
        _onlySelf();
        _convert(c);
    }

    /// One batch of the pile in `c` into $IMDUEL, with balance claims only: IMD buys $IMDUEL in the main duel, up to
    /// a price limit (_swapClaims); what isn't spent stays in the pile. Half the $IMDUEL goes to the main duel's
    /// $IMDUEL chest, half is burned. The hook's own swaps skip its callbacks: they play no move and pay no fee.
    function _convert(Currency c) internal {
        uint256 id = c.toId();
        uint256 amount = pile[id];
        if (amount == 0) return;
        uint256 spent = amount;
        uint256 bought = amount;
        if (c == imd) {
            (spent, bought) = _swapClaims(_mainKey(), imd, _batch(amount, minImd));
        } else if (!(c == imduel)) {
            return; // no slice is taken in it (every duel pairs IMD or $IMDUEL), so there is nothing to convert
        }
        pile[id] = amount - spent;
        uint256 kept = _addChest(mainId, imduel < imd ? 0 : 1, bought - bought / 2);
        uint256 burned = bought - kept; // half, or more if the chest is full
        if (burned != 0) _send(imduel, DEAD, burned);
        emit Converted(c, spent, bought, burned);
    }

    /// The most a batch of a pile of `amount` spends: BATCH_MINS minimums (`min`), or the pile.
    function _batch(uint256 amount, uint256 min) internal pure returns (uint256) {
        if (amount / BATCH_MINS < min) return amount; // under the bound (so too for a `min` too large to multiply)
        uint256 most = BATCH_MINS * min; // fits: it is at most `amount`
        return amount > most ? most : amount;
    }

    /// Swaps `amountIn` of `input` in the main duel (`key`) up to the batch price limit, paying and receiving as
    /// balance claims. The limit is 0.1% (sqrt) past the pool's reference price (_reference: the limit is a band, and
    /// an attacker could fill a band past a price it pushed with its own liquidity). Nothing is bought once the price
    /// is past the limit, while fewer than three blocks are sampled, or when a batch already swapped this block (one
    /// per block: a pushed price must not sell the pile batch after batch).
    function _swapClaims(PoolKey memory key, Currency input, uint256 amountIn)
        internal
        returns (uint256 spent, uint256 got)
    {
        bool zeroForOne = input == key.currency0;
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint256 s = _sample(sqrtPrice);
        uint256 from = _reference(s, zeroForOne);
        if (from == 0 || amountIn == 0) return (0, 0);
        uint160 limit = uint160(
            zeroForOne ? from * (10_000 - BATCH_SQRT_BPS) / 10_000 : from * (10_000 + BATCH_SQRT_BPS) / 10_000
        );
        if (zeroForOne ? limit >= sqrtPrice : limit <= sqrtPrice) return (0, 0);
        BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        (int128 inDelta, int128 outDelta) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        spent = uint256(uint128(-inDelta));
        got = uint256(uint128(outDelta));
        manager.burn(address(this), input.toId(), spent);
        manager.mint(address(this), (zeroForOne ? key.currency1 : key.currency0).toId(), got);
        samples = (s & ((1 << 208) - 1)) | (block.number << 208); // this block's batch
    }

    /// Records `sqrtPrice` as the main duel's price at the start of this block, once per block (the first observation
    /// of a block comes before any swap of it has moved the price), and returns the samples word.
    function _sample(uint160 sqrtPrice) internal returns (uint256 s) {
        s = samples;
        if ((s >> 168) & 0xffffffffff == block.number) return s;
        s = (s & (0xffffffffff << 208)) | (block.number << 168) | ((s << SAMPLE_BITS) & ((1 << 168) - 1)) | _pack(sqrtPrice);
        samples = s;
    }

    /// The reference price of a batch from the samples in `s`: the most hook-favourable of the three latest sampled
    /// blocks' start prices (selling currency0 the price falls: the highest; else the lowest). 0 while fewer than three
    /// blocks are sampled or a batch already swapped there this block.
    function _reference(uint256 s, bool zeroForOne) internal view returns (uint256 from) {
        if (s >> 208 == block.number || (s >> (2 * SAMPLE_BITS)) & ((1 << SAMPLE_BITS) - 1) == 0) return 0;
        for (uint256 i; i < 3; i++) {
            uint256 p = _unpack((s >> (i * SAMPLE_BITS)) & ((1 << SAMPLE_BITS) - 1));
            if (i == 0 || (zeroForOne ? p > from : p < from)) from = p;
        }
    }

    /// A sqrt price as an 8-bit exponent and a 48-bit mantissa (a rounding of 2^-47, nothing next to the 0.1% band).
    function _pack(uint160 p) internal pure returns (uint256) {
        uint256 v = p;
        uint256 e;
        if (v >= 1 << 112) (v, e) = (v >> 64, 64);
        if (v >= 1 << 80) (v, e) = (v >> 32, e + 32);
        if (v >= 1 << 64) (v, e) = (v >> 16, e + 16);
        if (v >= 1 << 56) (v, e) = (v >> 8, e + 8);
        if (v >= 1 << 52) (v, e) = (v >> 4, e + 4);
        if (v >= 1 << 50) (v, e) = (v >> 2, e + 2);
        if (v >= 1 << 49) (v, e) = (v >> 1, e + 1);
        if (v >= 1 << 48) (v, e) = (v >> 1, e + 1);
        return e << 48 | v;
    }

    function _unpack(uint256 packed) internal pure returns (uint256) {
        return (packed & ((1 << 48) - 1)) << (packed >> 48);
    }

    function _mainKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = imd < imduel ? (imd, imduel) : (imduel, imd);
        return PoolKey(c0, c1, mainFee, mainSpacing, IHooks(address(this)));
    }

    function _minBatch(Currency c) internal view returns (uint256) {
        return c == imd ? minImd : c == imduel ? minImduel : type(uint256).max;
    }

    // ---------------------------------------------------------------- moves: every buy bids

    /// The game side of a swap: a move whose window has closed is played first; then this trade bids for its team's
    /// next move (the move being bid for now, if its team is to move) and takes the top spot if it pays more than
    /// RAISE_PCT over the current top; a trade of the other team after TURN_TIMEOUT of silence opens the silent side's
    /// move at 0%; then a slice batch converts if this pool's pile is ready.
    function _play(PoolId id, PoolKey calldata key, Game storage g, bool zeroForOne, BalanceDelta delta,
        bytes calldata hookData) internal
    {
        uint256 mover = teamOf(g.slice, g.gameNo, g.ply & 1 == 1);
        if (g.bids[mover].open && block.number > g.closeBlock) {
            _resolve(id, key, g, mover);
            mover = teamOf(g.slice, g.gameNo, g.ply & 1 == 1);
        }
        uint256 team = zeroForOne ? 1 : 0; // the token bought
        TopBid storage b = g.bids[team];
        (uint256 paid, uint256 got) = team == 1
            ? (_abs(delta.amount0()), _abs(delta.amount1()))
            : (_abs(delta.amount1()), _abs(delta.amount0()));
        if (team == mover) {
            bool late = block.number > g.closeBlock;
            // a move whose window closed but that couldn't be played (the engine failed twice; it shouldn't) takes
            // no more bids
            if (!(late && b.open) && _beats(paid, b)) {
                if (late) g.closeBlock = uint40(block.number); // the window passed without a bid: this block is it
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
        Currency s = g.slice == 0 ? key.currency0 : key.currency1;
        if (pile[s.toId()] >= _minBatch(s)) {
            try this.convertBatch{gas: CONVERT_GAS}(s) {} catch {}
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

    /// Who a trade bids for: the address in its hookData, 20 bytes packed or 32 bytes ABI-encoded (a zero address
    /// counts as none), else the wallet that signed the transaction, so a trade through any router or aggregator
    /// earns. Known and accepted: a trade relayed for a smart-contract wallet without hookData credits the relayer.
    function _owner(bytes calldata hookData) internal view returns (address owner) {
        if (hookData.length == 20) owner = address(bytes20(hookData));
        else if (hookData.length == 32 && uint256(bytes32(hookData)) <= type(uint160).max) owner = address(uint160(uint256(bytes32(hookData))));
        if (owner == address(0)) owner = tx.origin;
    }

    /// Whether a trade that paid `paid` takes the top spot from bid `b`: there is none, or it pays more than RAISE_PCT over it.
    function _beats(uint256 paid, TopBid storage b) internal view returns (bool) {
        return !b.open || paid * 100 > uint256(b.size) * (100 + RAISE_PCT);
    }

    /// Makes `t` team `team`'s top bid for half-move `ply`.
    function _bid(PoolId id, Game storage g, uint256 team, uint16 ply, Trade memory t) internal {
        TopBid storage b = g.bids[team];
        (b.owner, b.strength, b.open, b.size) = (t.owner, t.strength, true, uint128(t.size));
        emit Bid(id, g.gameNo, ply, t.owner, t.size, t.strength);
    }

    /// Plays the side to move's move (team `mover`) at its top bid's strength. The dice are the hash of the window's
    /// last block, which didn't exist while anyone could still bid, except for that block's builder (see the contract
    /// notes). A move whose block hash the chain no longer serves
    /// (after 8,191 blocks, about a day) becomes a timeout move in this block. If the engine fails (it shouldn't), a
    /// seeded legal move is played at 0%; if that fails too, the game ends as a draw. An engine starved by the trade's
    /// gas limit reverts the trade, so gas estimates include the move.
    function _resolve(PoolId id, PoolKey calldata key, Game storage g, uint256 mover) internal {
        bytes32 h = _hashOf(g.closeBlock);
        if (h == 0) {
            g.closeBlock = uint40(block.number);
            return _bid(id, g, mover, g.ply, Trade(0, address(0), 0));
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
        (ok, m, r) = _engine(ENGINE_GAS, abi.encodeCall(IChessEngine.play,
            (g.board, own, other, black, uint256(t.strength), seed, _history(id, g.ply, g.quiet), g.gameNo, g.quiet)));
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
    /// a later trade in that block can still change (it can still take the top bid).
    function previewMove(PoolId id, bytes32 h) external view returns (bool ready, uint16 move) {
        Game storage g = games[id];
        TopBid memory b = g.bids[teamOf(g.slice, g.gameNo, g.ply & 1 == 1)];
        if (!b.open || block.number < g.closeBlock) return (false, 0);
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
        for (uint256 i; i < 8; i++) previous[i] = _key(lo, hi, ((ply + 14 - i * 2) % 16) >> 1);
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
        // could be farmed for gas (audit 2026-10-31)
        if (t.owner != address(0) && g.main) _count(id, g, t, move, board, piece, captured, r.check, result == (black ? 2 : 1));
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
    /// game's trading put into the pots (a game played for dust pays nothing: the pot can't be harvested by fast
    /// games); the rest stays in the pot. A move for nobody (a timeout) pays nobody. Recorded to claim (withdraw),
    /// never sent inside the trade.
    function _payMate(PoolId id, PoolKey calldata key, Game storage g, Trade memory t, uint256 team) internal {
        if (t.owner == address(0)) return;
        uint256 loser = 1 - team;
        uint256 amount = _min(chest(id, loser) * MATE_SHARE_BPS / 10_000, t.size * PAYOUT_CAP);
        amount = _min(amount, _inflowIn(id, g.moveGameNo, loser) * MATE_INFLOW_CAP);
        if (amount == 0) return;
        _takeChest(id, loser, amount);
        Currency c = loser == 0 ? key.currency0 : key.currency1;
        owed[t.owner][c.toId()] += amount;
        if (g.main) _countWon(t.owner, c, amount);
        emit MatePaid(id, g.moveGameNo, t.owner, c, amount);
    }

    // ---------------------------------------------------------------- player counts (badges and display only)

    /// Adds a played move to its owner's counts (the first one also lists the owner in players).
    function _count(PoolId id, Game storage g, Trade memory t, uint16 move, uint256 board, uint8 piece, uint8 captured,
        bool check, bool mate) internal
    {
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

    /// Adds what a mate won to its owner's counts: the amount in IMD or in $IMDUEL (other tokens are not counted).
    function _countWon(address o, Currency c, uint256 amount) internal {
        uint256 shift = c == imd ? 140 : c == imduel ? 180 : 0;
        if (shift != 0) counts[o][1] = _add(counts[o][1], shift, 40, amount / 1e15);
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

    function _repeated(PoolId id, Game storage g) internal view returns (bool) {
        // A position needs at least four reversible half-moves to recur (each side out and back), and nothing before
        // the last capture or pawn move can recur; skips the reads on most swaps.
        if (g.quiet < 4) return false;
        uint64 k = Chess.positionKey(g.board, g.whiteState, g.blackState, g.ply & 1 == 1, g.gameNo);
        uint256 seen;
        if (g.board == Chess.START_BOARD && g.whiteState == Chess.START_WHITE && g.blackState == Chess.START_BLACK
            && g.ply & 1 == 0) seen = 1;
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

    function _onlySelf() internal view {
        if (msg.sender != address(this)) revert NotSelf();
    }

    // transient storage: 0 the re-entry lock, 1 what beforeSwap hands afterSwap

    function _locked() internal view returns (bool l) {
        assembly ("memory-safe") {
            l := tload(0)
        }
    }

    function _lock(bool on) internal {
        assembly ("memory-safe") {
            tstore(0, on)
        }
    }

    /// Which pot the fee goes to and the fee taken before the swap, for afterSwap (`taken` is never negative).
    function _stash(uint256 chestIdx, int128 taken) internal {
        uint256 fee = uint128(taken);
        assembly ("memory-safe") {
            tstore(1, or(fee, shl(128, chestIdx)))
        }
    }

    function _unstash() internal view returns (uint256 chestIdx, int128 taken) {
        assembly ("memory-safe") {
            let w := tload(1)
            taken := and(w, 0xffffffffffffffffffffffffffffffff)
            chestIdx := shr(128, w)
        }
    }
}
