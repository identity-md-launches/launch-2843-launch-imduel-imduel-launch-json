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
import {HookConfig, IMDuelHarness} from "./Harness.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DebtOwner} from "./Tokens.sol";

/// Takes no ETH: its ETH rewards stay owed.
contract NoEth {}

/// A property check every fuzzer understands (Echidna and Medusa have no message-carrying asserts): reverts with `why`.
function need(bool ok, string memory why) pure {
    if (!ok) revert(why);
}

/// Random actions across several duels on one hook, every slice burned or (in IMD) put in the main duel's IMD pot. Every action
/// must succeed (fail_on_revert), and each checks the properties of what it just did (SP-01..06; the global ones are
/// GL-01..05 below). Runs under Foundry, Echidna and Medusa (test/fuzz/): only cheatcodes all support, except the event
/// checks, which only Foundry records (`withEvents`), and queued mates, which need the test harness (Foundry).
contract DuelsHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 constant MATE_PAID = keccak256("MatePaid(bytes32,uint32,address,address,uint256)");

    IMDuelHook public hook;
    bool immutable withEvents; // Foundry: check each mate's payout from its event
    // two positions whose side to move has one legal move and it mates (Base.forcedMate): White's, then Black's
    uint256[2] mateBoards;
    uint32[2][2] mateStates;
    uint256 public mates; // mates paid in this run
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

    /// The forced-mate positions queueMate puts on a board (the test computes them: Base.forcedMate).
    function setMates(uint256[2] memory boards, uint32[2][2] memory states) external {
        if (mateBoards[0] != 0) return; // once, by the test (the fuzzer calls it too)
        (mateBoards, mateStates) = (boards, states);
    }

    function _gameHash(uint256 i) internal view returns (bytes32) {
        return keccak256(abi.encode(hook.game(pools[i].toId())));
    }

    /// SP-05: a mate pays at most what that game's trades paid into the losing pot (`inflow`, read before the
    /// trade that played it: that trade's own fee counts for the next game), and at most a quarter of the pot it was
    /// paid from (every fee goes in before the move is played, so that pot is `potAfter` plus the payout).
    function _checkMates(Vm.Log[] memory entries, PoolKey memory k, uint256[2] memory inflow, uint256[2] memory potAfter) internal {
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] != MATE_PAID) continue;
            (,, Currency c, uint256 amount) = abi.decode(entries[i].data, (uint32, address, Currency, uint256));
            uint256 loser = c == k.currency0 ? 0 : 1;
            need(amount <= inflow[loser], "SP-05 a mate pays at most the pot fees into the losing pot that game");
            need(amount * 3 <= potAfter[loser], "SP-05 at most a quarter of the loser's pot");
            mates++;
        }
    }

    /// The team whose move is being bid for now.
    function _mover(IMDuelHook.Game memory g) internal pure returns (uint256) {
        return (g.gameNo & 1) ^ (g.base ^ 1) ^ (g.ply & 1);
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
        // played is cleared (a new one may follow), and a move whose block hash expired keeps its size for nobody
        for (uint256 t; t < 2; t++) {
            (IMDuelHook.TopBid memory x, IMDuelHook.TopBid memory y) = (a.bids[t], b.bids[t]);
            bool forNobody = t == mover && expired && y.owner == address(0) && y.size == x.size;
            if ((t == mover && played) || forNobody || !x.open || !y.open || (y.owner == x.owner && y.size == x.size)) continue;
            need(uint256(y.size) * 100 > uint256(x.size) * 110, "SP-03 only a bid 10% bigger takes the top spot");
        }
        if (played) return;
        (IMDuelHook.TopBid memory was, IMDuelHook.TopBid memory cur) = (a.bids[mover], b.bids[mover]);
        bool opened = cur.open && cur.owner == address(0) && cur.size == 0 && !(was.open && was.owner == address(0) && was.size == 0);
        if (opened) need(time >= a.turnStart + hook.TURN_TIMEOUT(), "SP-04 a timeout only after silence");
        // SP-06: a move's window closes: past it, its bid is final; it only moves to the block a first bid lands in
        if (was.open && now_ > a.closeBlock && !expired) need(cur.owner == was.owner && cur.size == was.size, "SP-06 a closed window takes no bids");
        // a window moves only to this block (a timeout, an expired hash) or, at a move's first bid in or after its
        // last block, to a full window from it
        bool firstLate = !was.open && cur.open && now_ >= a.closeBlock;
        need(b.closeBlock == a.closeBlock || b.closeBlock == now_ || (firstLate && b.closeBlock == now_ + hook.turnBlocks() - 1),
            "SP-06 a window only moves to this block, or opens in full at a late first bid");
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
        IMDuelHook.Game memory before = hook.game(k.toId());
        (uint256 in0, uint256 in1) = hook.gameInflow(k.toId(), before.gameNo);
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
        IMDuelHook.Game memory after_ = hook.game(k.toId());
        if (withEvents) _checkMates(vm.getRecordedLogs(), k, [in0, in1], [hook.chest(k.toId(), 0), hook.chest(k.toId(), 1)]);
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

    /// A liquidity provider stepping in and out (full range, its own salt): neither strength nor pots may move with it.
    /// Fees earned so far are collected first (v4's test router asserts an addition only owes).
    function addLiquidity(uint8 p, uint256 liquidity) external {
        PoolKey memory k = pools[p % pools.length];
        liquidity = bound(liquidity, 1e15, 1e22);
        if (added[p % pools.length] != 0) _lp(k, 0);
        _lp(k, int256(liquidity));
        added[p % pools.length] += liquidity;
    }

    function removeLiquidity(uint8 p, uint256 liquidity) external {
        PoolKey memory k = pools[p % pools.length];
        uint256 have = added[p % pools.length];
        if (have == 0) return;
        liquidity = bound(liquidity, have < 1e15 ? have : 1e15, have);
        _lp(k, -int256(liquidity));
        added[p % pools.length] -= liquidity;
    }

    function _lp(PoolKey memory k, int256 liquidity) internal {
        lpRouter.modifyLiquidity{value: k.currency0.isAddressZero() && liquidity > 0 ? 1e28 : 0}(
            k, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(uint256(1))), "");
    }

    /// Puts a forced mate on pool `p`'s board (Foundry's harness only; a production hook under Echidna has no setter):
    /// the next trades play it, so payouts and their caps happen in every run.
    function queueMate(uint8 p, bool blackMates) external {
        uint256 i = blackMates ? 1 : 0;
        try IMDuelHarness(address(hook)).setPosition(pools[p % pools.length].toId(), mateBoards[i], mateStates[i][0],
            mateStates[i][1], uint16(i), 0) {} catch {}
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

    /// Anyone sends the owed $IMDUEL burn to 0x...dEaD.
    function burn() external {
        hook.withdraw(address(0xdEaD), hook.imduel());
    }

    /// The ETH-refusing owner can't withdraw ETH (its reward stays owed); everyone else always can.
    function withdrawReward(uint8 owner, uint8 c) external {
        address who = owners[owner % owners.length];
        Currency cur = currencies[c % currencies.length];
        if ((who.code.length != 0 || uint160(who) < 0x100) && cur.isAddressZero()) return; // contracts and precompiles
        hook.withdraw(who, cur);
    }
}

/// Four duels on one hook (the main $IMDUEL / IMD duel first and thin, a token against IMD, ETH against IMD, a token
/// against $IMDUEL), with mates queued along the way: every action succeeds, every currency's claims equal its chests,
/// the burn and what is owed, and every board stays sound.
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
        deployHook(config(v5(), imdC));
        keys.push(open(imdC, duelC, IHooks(address(hook)), 1e20)); // the main duel, first on the hook, thin as at launch
        keys.push(open(xC, imdC, IHooks(address(hook)), 1e24));
        keys.push(open(CurrencyLibrary.ADDRESS_ZERO, imdC, IHooks(address(hook)), 1e24)); // an ETH duel: its slice in IMD
        keys.push(open(xC, duelC, IHooks(address(hook)), 1e24));
        (pool, id) = (keys[0], keys[0].toId());
        Currency[] memory cs = new Currency[](4);
        (cs[0], cs[1], cs[2], cs[3]) = (imdC, duelC, xC, CurrencyLibrary.ADDRESS_ZERO);
        handler = new DuelsHandler(hook, swapRouter, modifyLiquidityRouter, keys, cs, logsRecorded());
        uint256 w;
        w = put(put(put(put(put(put(w, "c8", 6), "h8", 4), "a8", 14), "a7", 9), "b7", 9), "d7", 13);
        uint256 b;
        b = put(put(put(put(put(put(b, "c1", 14), "h1", 12), "a1", 6), "a2", 1), "b2", 1), "d2", 5);
        handler.setMates([w, b], [[side("c8"), side("a8")], [side("a1"), side("c1")]]);
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
            need(held == total, "GL-01 held = chests + burn + owed");
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
                // a timeout move is empty; a bid whose hash expired keeps its size and strength for nobody
                if (b.owner == address(0) && b.size == 0) need(b.strength == 0, "GL-05 a timeout move is at 0%");
                need(b.strength <= 9_000, "GL-05 strength at most 90%");
            }
            need(g.moveStrength <= 9_000, "GL-05 strength at most 90%");
        }
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
        emit log_named_uint("mates paid", handler.mates());
        handler.nextBlock(12);
        for (uint256 i; i < keys.length; i++) {
            handler.trade(uint8(i), true, 1e12, 0, false);
            handler.trade(uint8(i), false, 1e12, 0, false);
        }
    }
}
