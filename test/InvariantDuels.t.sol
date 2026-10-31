// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
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
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DebtOwner} from "./Tokens.sol";

/// Takes no ETH: its ETH rewards stay owed.
contract NoEth {}

/// A property check every fuzzer understands (Echidna and Medusa have no message-carrying asserts): reverts with `why`.
function need(bool ok, string memory why) pure {
    if (!ok) revert(why);
}

/// Random actions across several duels on one hook, the protocol slice converting through every route. Every action
/// must succeed (fail_on_revert), and each checks the properties of what it just did (SP-01..06; the global ones are
/// GL-01..05 below). Runs under Foundry, Echidna and Medusa (test/fuzz/): only cheatcodes all support, except the event
/// checks, which only Foundry records (`withEvents`).
contract DuelsHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 constant CONVERTED = keccak256("Converted(address,uint256,uint256,uint256)");

    IMDuelHook public hook;
    bool immutable withEvents; // Foundry: check the batches inside trades from their events
    uint256 startBlock;
    uint160 startSqrt; // the main duel's price when the current block began (pools[0] is the main duel)
    uint160 prevStartSqrt; // and when the previous block with an action began: a price older than this block
    PoolSwapTest router;
    PoolModifyLiquidityTest lpRouter;
    mapping(uint256 => uint256) public added; // liquidity this handler holds per pool (salt 1, full range)
    PoolKey[] public pools;
    Currency[] public currencies;
    address[] public owners;
    mapping(address => bool) listed; // every address a reward can be recorded for (the books count them)
    uint256 public swaps;
    uint256 public moves;

    constructor(IMDuelHook hook_, PoolSwapTest router_, PoolModifyLiquidityTest lpRouter_, PoolKey[] memory pools_,
        Currency[] memory currencies_, bool events_)
    {
        (hook, router, lpRouter, withEvents) = (hook_, router_, lpRouter_, events_);
        for (uint256 i; i < pools_.length; i++) pools.push(pools_[i]);
        for (uint256 i; i < currencies_.length; i++) {
            currencies.push(currencies_[i]);
            if (currencies_[i].isAddressZero()) continue;
            MockERC20 t = MockERC20(Currency.unwrap(currencies_[i]));
            t.mint(address(this), 1e36);
            t.approve(address(router), type(uint256).max);
            t.approve(address(lpRouter), type(uint256).max);
            t.approve(address(hook), type(uint256).max);
        }
        vm.deal(address(this), 1e30);
        _noteOwner(address(0xA11CE)); // not 0xA / 0xB: those are precompiles and refuse ETH
        _noteOwner(address(0xB0B));
        _noteOwner(address(new NoEth()));
        // paid in ETH, it takes 1 wei of IMD from the PoolManager and leaves the debt: its reward must be refused and
        // owed, never let it revert the trade
        _noteOwner(address(new DebtOwner(hook_.manager(), currencies_[0])));
        _noteOwner(tx.origin);
    }

    /// The chain's block and time, read in a fresh call: with via_ir a function that rolled may reuse stale values.
    function chainNow() external view returns (uint256, uint256) {
        return (block.number, block.timestamp);
    }

    /// Notes the main duel's price at the first action of each block (only swaps move it, and every action starts
    /// here before any swap).
    function _blockStarts() internal {
        (uint256 n,) = this.chainNow();
        if (n == startBlock && startSqrt != 0) return;
        if (startSqrt != 0) prevStartSqrt = startSqrt;
        startBlock = n;
        (startSqrt,,,) = hook.manager().getSlot0(pools[0].toId());
    }

    function _gameHash(uint256 i) internal view returns (bytes32) {
        return keccak256(abi.encode(hook.game(pools[i].toId())));
    }

    /// SP-05: an IMD batch that bought `bought` $IMDUEL for `spent` IMD paid at most ~0.5% (0.2% band, 0.3% pool fee)
    /// over the better of the block-start price and the previous block's start price: a price pushed at the end of
    /// the previous block is never its reference (an attacker owning the last transaction of one block and the first
    /// of the next).
    function _checkBatch(uint256 spent, uint256 bought) internal view {
        bool imdFirst = hook.imd() == pools[0].currency0;
        uint160 ref = startSqrt;
        if (prevStartSqrt != 0 && (imdFirst ? prevStartSqrt > ref : prevStartSqrt < ref)) ref = prevStartSqrt;
        uint256 worth = imdFirst // `bought` $IMDUEL in IMD at the reference price
            ? FullMath.mulDiv(FullMath.mulDiv(bought, 1 << 96, ref), 1 << 96, ref)
            : FullMath.mulDiv(FullMath.mulDiv(bought, ref, 1 << 96), ref, 1 << 96);
        need(spent <= worth * 10_055 / 10_000 + 2, "SP-05 a batch within 0.5% of a price older than this block");
    }

    function _checkBatches(Vm.Log[] memory entries) internal view {
        bytes32 imd = bytes32(uint256(uint160(Currency.unwrap(hook.imd()))));
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] != CONVERTED || entries[i].topics[1] != imd) continue;
            (uint256 spent, uint256 bought,) = abi.decode(entries[i].data, (uint256, uint256, uint256));
            _checkBatch(spent, bought);
        }
    }

    /// The team whose move is being bid for now.
    function _mover(IMDuelHook.Game memory g) internal pure returns (uint256) {
        return (g.gameNo & 1) ^ (g.slice ^ 1) ^ (g.ply & 1);
    }

    /// SP-01, SP-03, SP-04, SP-06 for the pool a trade went through.
    function _checkTurn(IMDuelHook.Game memory a, IMDuelHook.Game memory b) internal view {
        (uint256 now_, uint256 time) = this.chainNow();
        if (b.gameNo == a.gameNo) need(b.ply == a.ply || b.ply == a.ply + 1, "SP-01 one move at most");
        else need(b.gameNo == a.gameNo + 1 && b.ply == 0, "SP-01 one game end at most");
        bool played = b.gameNo != a.gameNo || b.ply != a.ply;
        uint256 mover = _mover(a);
        bool expired = a.bids[mover].open && now_ > a.closeBlock + 256; // this suite has no history contract
        // SP-03: a team's top bid only changes to one paying more than 10% more. Exceptions: the bid of a move just
        // played is cleared (a new one may follow), and a move whose block hash expired becomes a timeout that any
        // bid in this block can take
        for (uint256 t; t < 2; t++) {
            (IMDuelHook.TopBid memory x, IMDuelHook.TopBid memory y) = (a.bids[t], b.bids[t]);
            if ((t == mover && (played || expired)) || !x.open || !y.open || (y.owner == x.owner && y.size == x.size)) continue;
            need(uint256(y.size) * 100 > uint256(x.size) * 110, "SP-03 only a bid 10% bigger takes the top spot");
        }
        if (played) return;
        (IMDuelHook.TopBid memory was, IMDuelHook.TopBid memory cur) = (a.bids[mover], b.bids[mover]);
        bool opened = cur.open && cur.owner == address(0) && cur.size == 0 && !(was.open && was.owner == address(0) && was.size == 0);
        if (opened) need(time >= a.turnStart + hook.TURN_TIMEOUT() || expired, "SP-04 a timeout only after silence or an expired hash");
        // SP-06: a move's window closes: past it, its bid is final; it only moves to the block a first bid lands in
        if (was.open && now_ > a.closeBlock && !expired) need(cur.owner == was.owner && cur.size == was.size, "SP-06 a closed window takes no bids");
        need(b.closeBlock == a.closeBlock || b.closeBlock == now_, "SP-06 a window only moves to this block");
    }

    receive() external payable {}

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function currencyCount() external view returns (uint256) {
        return currencies.length;
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

    function poolAt(uint256 i) external view returns (PoolKey memory) {
        return pools[i];
    }

    /// Exact input; native ETH in is sent as value. Exact output only when the input is a token, on the deep pools.
    function trade(uint8 p, bool zeroForOne, uint256 size, uint8 owner, bool exactOut) public {
        _trade(p, zeroForOne, bound(size, 1e9, 20e18), owner, exactOut);
    }

    /// An attacker who owns the last transaction of a block and the first of the next: a trade big enough to move
    /// the price (up to 200 on the thin main duel), then the next block begins.
    function pushThenNextBlock(uint8 p, bool zeroForOne, uint256 size, uint8 owner) external {
        _trade(p, zeroForOne, bound(size, 20e18, 200e18), owner, false);
        nextBlock(12);
    }

    function _trade(uint8 p, bool zeroForOne, uint256 size, uint8 owner, bool exactOut) internal {
        PoolKey memory k = pools[p % pools.length];
        bool ethIn = zeroForOne && k.currency0.isAddressZero();
        // no exact output on the thin main duel: at the routers' extreme price limit the input it needs passes
        // 2^127 and the PoolManager itself rejects the swap (hook or not)
        if (ethIn || p % pools.length == 0) exactOut = false;
        _blockStarts();
        IMDuelHook.Game memory before = hook.game(k.toId());
        bytes32[] memory others = new bytes32[](pools.length);
        for (uint256 i; i < pools.length; i++) others[i] = _gameHash(i);
        bytes memory data = owner % 5 == 4 ? bytes("") : abi.encodePacked(owners[owner % 4]);
        if (owner % 5 == 4) _noteOwner(tx.origin); // the owner of a trade naming none: here the random sender
        if (withEvents) vm.recordLogs();
        router.swap{value: ethIn ? size : 0}(
            k,
            SwapParams(zeroForOne, exactOut ? int256(size) : -int256(size), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
        if (withEvents) _checkBatches(vm.getRecordedLogs());
        IMDuelHook.Game memory after_ = hook.game(k.toId());
        _checkTurn(before, after_);
        for (uint256 i; i < pools.length; i++) {
            if (i != p % pools.length) need(_gameHash(i) == others[i], "SP-02 another pool's game is untouched");
        }
        swaps++;
        if (after_.ply != before.ply || after_.gameNo != before.gameNo) moves++;
    }

    /// SP-06: buy, then sell exactly what was bought, in one block: never more back than paid (rewards go elsewhere).
    function roundTrip(uint8 p, bool zeroForOne, uint256 size) external {
        PoolKey memory k = pools[p % pools.length];
        if (k.currency0.isAddressZero()) return;
        size = bound(size, 1e9, 5e18);
        _blockStarts(); // before its swaps, as every action (a round trip first in a block moves the start price)
        (Currency a, Currency b) = zeroForOne ? (k.currency0, k.currency1) : (k.currency1, k.currency0);
        (uint256 a0, uint256 b0) = (a.balanceOfSelf(), b.balanceOfSelf());
        bytes memory data = abi.encodePacked(owners[1]);
        router.swap(k, SwapParams(zeroForOne, -int256(size), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), data);
        uint256 got = b.balanceOfSelf() - b0;
        if (got == 0) return;
        router.swap(k, SwapParams(!zeroForOne, -int256(got), zeroForOne ? TickMath.MAX_SQRT_PRICE - 1
            : TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), data);
        need(a.balanceOfSelf() <= a0, "SP-06 no round-trip profit");
        need(b.balanceOfSelf() <= b0, "SP-06 no round-trip profit");
    }

    /// Listed again so trading is picked more often than the other actions.
    function tradeAgain(uint8 p, bool zeroForOne, uint256 size, uint8 owner) external {
        trade(p, zeroForOne, size, owner, false);
    }

    function tradeNextBlock(uint8 p, bool zeroForOne, uint256 size, uint8 owner) external {
        nextBlock(12);
        trade(p, zeroForOne, size, owner, false);
    }

    /// A liquidity provider stepping in and out (full range, its own salt): strengths and chest values move with it.
    /// Fees earned so far are collected first (v4's test router asserts an addition only owes).
    function addLiquidity(uint8 p, uint256 liquidity) external {
        PoolKey memory k = pools[p % pools.length];
        liquidity = bound(liquidity, 1e15, 1e22);
        _blockStarts();
        if (added[p % pools.length] != 0) _lp(k, 0);
        _lp(k, int256(liquidity));
        added[p % pools.length] += liquidity;
    }

    function removeLiquidity(uint8 p, uint256 liquidity) external {
        PoolKey memory k = pools[p % pools.length];
        uint256 have = added[p % pools.length];
        if (have == 0) return;
        liquidity = bound(liquidity, have < 1e15 ? have : 1e15, have);
        _blockStarts();
        _lp(k, -int256(liquidity));
        added[p % pools.length] -= liquidity;
    }

    function _lp(PoolKey memory k, int256 liquidity) internal {
        lpRouter.modifyLiquidity{value: k.currency0.isAddressZero() && liquidity > 0 ? 1e28 : 0}(
            k, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(uint256(1))), "");
    }

    /// A batch at the start of the next block, as the first observer of the main duel.
    function convertNextBlock(uint8 c) external {
        nextBlock(12);
        this.convert(c);
    }

    function nextBlock(uint256 secs) public {
        (uint256 n, uint256 t) = this.chainNow();
        vm.warp(t + bound(secs, 1, 120));
        vm.roll(n + 1);
    }

    function longPause() external {
        (uint256 n, uint256 t) = this.chainNow();
        vm.warp(t + hook.TURN_TIMEOUT() + 1);
        vm.roll(n + 50);
    }

    function fund(uint8 p, bool inCurrency1, uint256 amount) external {
        PoolKey memory k = pools[p % pools.length];
        amount = bound(amount, 1, 50e18);
        Currency c = inCurrency1 ? k.currency1 : k.currency0;
        hook.fundChest{value: c.isAddressZero() ? amount : 0}(k, inCurrency1, amount);
    }

    /// The ETH-refusing owner can't withdraw ETH (its reward stays owed); everyone else always can.
    function withdrawReward(uint8 owner, uint8 c) external {
        address who = owners[owner % owners.length];
        Currency cur = currencies[c % currencies.length];
        if ((who.code.length != 0 || uint160(who) < 0x100) && cur.isAddressZero()) return; // contracts and precompiles
        hook.withdraw(who, cur);
    }

    /// SP-05 from balances (works without event recording): what the IMD pile lost bought what the main $IMDUEL chest
    /// and the dead address gained.
    function convert(uint8 c) external {
        Currency cur = currencies[c % currencies.length];
        _blockStarts();
        Currency imduel = hook.imduel();
        uint256 side = imduel < hook.imd() ? 0 : 1;
        (uint256 pile0, uint256 chest0, uint256 dead0) = (hook.pile(cur.toId()), hook.chest(hook.mainId(), side),
            imduel.balanceOf(address(0xdEaD)));
        hook.convert(cur);
        if (cur == hook.imd() && hook.pile(cur.toId()) < pile0) {
            uint256 bought = hook.chest(hook.mainId(), side) - chest0 + imduel.balanceOf(address(0xdEaD)) - dead0;
            _checkBatch(pile0 - hook.pile(cur.toId()), bought);
        }
    }
}

/// Four duels on one hook (the main $IMDUEL / IMD duel first and thin, a token against IMD, ETH against a token, a
/// token against $IMDUEL) plus the hookless IMD / ETH route, with conversions on: every action succeeds, every currency's
/// claims equal its chests, its pile and what is owed, and every board stays sound.
contract InvariantDuelsTest is Base {
    /// The launch value: the invariants hold for moves open over several blocks.
    function turnBlocks() internal pure override returns (uint256) {
        return 3;
    }

    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    DuelsHandler handler;
    Currency imdC;
    Currency duelC;
    Currency xC;
    PoolKey[] keys;

    function token(string memory s) internal returns (Currency) {
        return Currency.wrap(address(mockToken(s, s)));
    }

    function sorted(Currency a, Currency b) internal pure returns (Currency, Currency) {
        return a < b ? (a, b) : (b, a);
    }

    function open(Currency a, Currency b, IHooks h, int256 liquidity) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = sorted(a, b);
        (k,) = initPool(c0, c1, h, 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: c0.isAddressZero() ? 1e27 : 0}(
            k, ModifyLiquidityParams(-887220, 887220, liquidity, 0), "");
    }

    function setUp() public {
        if (address(handler) != address(0)) return; // Echidna calls setUp after the tester's constructor did
        deployV4();
        (imdC, duelC, xC) = (token("IMD"), token("IMDUEL"), token("X"));
        Currency[3] memory ts = [imdC, duelC, xC];
        for (uint256 i; i < 3; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(ts[i]));
            t.mint(address(this), 1e36);
            t.approve(address(modifyLiquidityRouter), type(uint256).max);
        }
        vm.deal(address(this), 1e30);
        HookConfig memory c = config(v5(), imdC);
        (c.minImd, c.minImduel) = (imdMinimum(), 1e15);
        deployHook(c);
        keys.push(open(imdC, duelC, IHooks(address(hook)), 1e20)); // the main duel, first on the hook, thin as at launch
        keys.push(open(xC, imdC, IHooks(address(hook)), 1e24));
        keys.push(open(CurrencyLibrary.ADDRESS_ZERO, imdC, IHooks(address(hook)), 1e24)); // an ETH duel: its slice in IMD
        keys.push(open(xC, duelC, IHooks(address(hook)), 1e24));
        (pool, id) = (keys[0], keys[0].toId());
        Currency[] memory cs = new Currency[](4);
        (cs[0], cs[1], cs[2], cs[3]) = (imdC, duelC, xC, CurrencyLibrary.ADDRESS_ZERO);
        handler = new DuelsHandler(hook, swapRouter, modifyLiquidityRouter, keys, cs, logsRecorded());
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyCurrencyBalances() public view {
        address[] memory who = new address[](handler.ownersLength());
        for (uint256 j; j < who.length; j++) who[j] = handler.owners(j);
        Currency[4] memory cs = [imdC, duelC, xC, CurrencyLibrary.ADDRESS_ZERO];
        for (uint256 i; i < 4; i++) {
            (uint256 held, uint256 total) = books(cs[i], keys, who);
            need(held == total, "GL-01 held = chests + pile + owed");
        }
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyBoardIsSound() public view {
        for (uint256 i; i < keys.length; i++) {
            IMDuelHook.Game memory g = hook.game(keys[i].toId());
            uint256 wk;
            uint256 bk;
            for (uint256 s; s < 64; s++) {
                uint256 p = (g.board >> (s << 2)) & 0xF;
                if (p == 6) wk++;
                if (p == 14) bk++;
            }
            need(wk == 1, "GL-02 one white king");
            need(bk == 1, "GL-02 one black king");
            need(g.ply < hook.MAX_PLY(), "GL-02 ply under the cap");
            need(g.quiet < hook.MAX_QUIET_PLY(), "GL-02 quiet under the cap");
        }
    }

    /// GL-03, GL-04: castling rights and en passant squares agree with the board.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_rightsMatchTheBoard() public view {
        for (uint256 i; i < keys.length; i++) {
            IMDuelHook.Game memory g = hook.game(keys[i].toId());
            sideMatches(g.board, g.whiteState, false);
            sideMatches(g.board, g.blackState, true);
        }
    }

    function sideMatches(uint256 board, uint32 state, bool black) internal pure {
        uint256 colour = black ? 8 : 0;
        uint256 back = black ? 56 : 0;
        uint256 kingSq = uint8(state >> 8);
        need((board >> (kingSq << 2)) & 0xF == 6 + colour, "GL-03 the state's king square holds its king");
        for (uint256 r; r < 2; r++) {
            uint256 rook = uint8(state >> (r == 0 ? 16 : 24));
            if (rook >= 64) continue;
            need(kingSq == back + 4, "GL-03 a castling right: the king is home");
            need(rook == back + (r == 0 ? 7 : 0), "GL-03 a castling right: the rook's home square");
            need((board >> (rook << 2)) & 0xF == 4 + colour, "GL-03 a castling right: its rook stands there");
        }
        uint256 ep = uint8(state);
        if (ep < 64) {
            need(ep >> 3 == (black ? 5 : 2), "GL-04 en passant on the third or sixth rank");
            need((board >> (ep << 2)) & 0xF == 0, "GL-04 en passant square empty");
        }
    }

    /// GL-05: turns are well formed.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_turnsAreWellFormed() public view {
        for (uint256 i; i < keys.length; i++) {
            IMDuelHook.Game memory g = hook.game(keys[i].toId());
            need(g.closeBlock < block.number + hook.turnBlocks(), "GL-05 a window ends at most turnBlocks ahead");
            for (uint256 t; t < 2; t++) {
                IMDuelHook.TopBid memory b = g.bids[t];
                if (b.owner == address(0)) need(b.size == 0 && b.strength == 0, "GL-05 a move for nobody is empty");
                need(b.strength <= 9_000, "GL-05 strength at most 90%");
            }
            need(g.moveStrength <= 9_000, "GL-05 strength at most 90%");
        }
    }

    /// The IMD pile's batch minimum: small, so most trades convert inside the swap (checked from events).
    function imdMinimum() internal pure virtual returns (uint256) {
        return 1e15;
    }

    /// Whether the fuzzer records events (Foundry does, Echidna and Medusa don't).
    function logsRecorded() internal pure virtual returns (bool) {
        return true;
    }

    /// GL-06, after every run: no pool has become untradeable. A dust trade each way in every duel, in a new block,
    /// goes through (a queued move resolves inside it; its payout may be refused, never revert the trade).
    function afterInvariant() external {
        emit log_named_uint("swaps", handler.swaps());
        emit log_named_uint("moves", handler.moves());
        handler.nextBlock(12);
        for (uint256 i; i < keys.length; i++) {
            handler.trade(uint8(i), true, 1e12, 0, false);
            handler.trade(uint8(i), false, 1e12, 0, false);
        }
    }
}
