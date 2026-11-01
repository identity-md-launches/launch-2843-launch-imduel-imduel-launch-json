// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {IMDuelToken} from "../src/IMDuelToken.sol";
import {Strength} from "../src/Strength.sol";
import {AtomicLaunchProbe} from "./FactoryLaunch.t.sol";
import {LaunchFixture, ScriptEngine} from "./LaunchFixture.sol";

/// Takes no ETH: a reward in ETH stays owed to it.
contract NoEthOwner {}

/// Random call sequences against the launch as it ships: the production hook and token, the factory's position, and
/// three side duels. It keeps its own books from what the brief says each call must do and checks each call as it
/// goes; a broken promise reverts, and fail-on-revert makes that the finding. Nothing here sets state on the hook:
/// every wei and every game reach it through a swap, a fundChest or a claim.
contract LaunchHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant HOOK_SWAP = keccak256("HookSwap(bytes32,address,int128,int128,uint24)");
    bytes32 constant MOVED = keccak256("Moved(bytes32,uint32,uint16,uint16,address,uint256,uint16,uint8,bool)");
    bytes32 constant MATE_PAID = keccak256("MatePaid(bytes32,uint32,address,address,uint256)");
    bytes32 constant GAME_OVER = keccak256("GameOver(bytes32,uint32,uint8,uint16)");
    bytes32 constant FAILED = keccak256("EngineFailed(bytes32,uint32,uint16)");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant TURN_BLOCKS = 3;

    IMDuelHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest immutable router;
    AtomicLaunchProbe immutable factory;
    address immutable controller;
    Currency public immutable imd;
    Currency public immutable duel;
    PoolId public mainId;
    uint256 immutable imdMainTeam;

    PoolKey[] public pools;
    Currency[] public currencies;
    address[] public actors;
    address[] public everyOwner; // whoever a reward was ever recorded for, read from MatePaid, not assumed
    mapping(address => bool) seenOwner;
    address[] public mainPlayers; // who owned a move of the main duel, from the Moved events
    mapping(address => bool) seenPlayer;

    // the handler's own books
    mapping(uint256 => uint256) public ghostHeld; // by currency id: fees and donations in, claims out
    mapping(uint256 => uint256) public ghostOwedTotal;
    mapping(address => mapping(uint256 => uint256)) public ghostOwed;
    mapping(bytes32 => uint256[2]) ghostPot;
    uint256 public ghostMainOwnedMoves;
    uint256 public ghostMainMates;
    mapping(bytes32 => uint32) highestGame;

    // what the run reached, so that a suite can't pass by doing nothing
    uint256 public swaps;
    uint256 public refused;
    uint256 public moves;
    uint256 public mates;
    uint256 public matesPaid;
    uint256 public draws;
    uint256 public fallbacks;
    uint256 public timeouts;
    uint256 public expired;
    uint256 public claimsPaid;
    uint256 public collects;

    constructor(
        IMDuelHook hook_,
        PoolSwapTest router_,
        AtomicLaunchProbe factory_,
        address controller_,
        PoolKey[] memory pools_,
        Currency[] memory currencies_,
        Currency duel_
    ) {
        (hook, router, factory, controller, duel) = (hook_, router_, factory_, controller_, duel_);
        manager = hook_.manager();
        imd = hook_.imd();
        for (uint256 i; i < pools_.length; i++) {
            pools.push(pools_[i]);
        }
        mainId = pools_[0].toId();
        imdMainTeam = pools_[0].currency0 == imd ? 0 : 1;
        for (uint256 i; i < currencies_.length; i++) {
            currencies.push(currencies_[i]);
        }
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        actors.push(address(new NoEthOwner()));
        vm.deal(address(this), 1e30);
    }

    receive() external payable {}

    function check(bool ok, string memory why) internal pure {
        if (!ok) revert(why);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function ownerCount() external view returns (uint256) {
        return everyOwner.length;
    }

    function playerCount() external view returns (uint256) {
        return mainPlayers.length;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function currencyCount() external view returns (uint256) {
        return currencies.length;
    }

    function pot(PoolId id, uint256 team) external view returns (uint256) {
        return ghostPot[PoolId.unwrap(id)][team];
    }

    function poolKey(uint256 i) external view returns (PoolKey memory) {
        return pools[i];
    }

    // ---------------------------------------------------------------- the calls

    function buyExactIn(uint8 p, bool zeroForOne, uint256 size, uint8 owner, uint8 signer) external {
        _swap(p, zeroForOne, size, false, owner, signer);
    }

    function buyExactInAgain(uint8 p, bool zeroForOne, uint256 size, uint8 owner, uint8 signer) external {
        _swap(p, zeroForOne, size, false, owner, signer);
    }

    function buyExactOut(uint8 p, bool zeroForOne, uint256 size, uint8 owner, uint8 signer) external {
        _swap(p, zeroForOne, size, true, owner, signer);
    }

    function tradeNextBlock(uint8 p, bool zeroForOne, uint256 size, uint8 owner, uint8 signer, uint8 blocks) external {
        roll(blocks);
        _swap(p, zeroForOne, size, false, owner, signer);
    }

    function roll(uint8 blocks) public {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 5));
        vm.warp(vm.getBlockTimestamp() + 12 * uint256(bound(blocks, 1, 5)));
    }

    /// Past TURN_TIMEOUT and past what BLOCKHASH serves: the history contract answers, and timeouts open.
    function silence() external {
        vm.warp(vm.getBlockTimestamp() + 700);
        vm.roll(vm.getBlockNumber() + 300);
    }

    /// A day and more of nothing: past the 8,191 blocks of history too, so a queued move's dice are gone.
    function longSilence() external {
        vm.warp(vm.getBlockTimestamp() + 110_000);
        vm.roll(vm.getBlockNumber() + 9_000);
    }

    function fund(uint8 p, bool inCurrency1, uint256 amount) external {
        PoolKey memory k = pools[p % pools.length];
        Currency c = inCurrency1 ? k.currency1 : k.currency0;
        amount = bound(amount, 0, 1e22);
        (uint256 in0, uint256 in1) = hook.gameInflow(k.toId(), hook.game(k.toId()).gameNo);
        uint256 before = hook.chest(k.toId(), inCurrency1 ? 1 : 0);
        hook.fundChest{value: c.isAddressZero() ? amount : 0}(k, inCurrency1, amount);
        check(hook.chest(k.toId(), inCurrency1 ? 1 : 0) == before + amount, "a donation lands in the pot it names");
        (uint256 j0, uint256 j1) = hook.gameInflow(k.toId(), hook.game(k.toId()).gameNo);
        check(j0 == in0 && j1 == in1, "a donation is no inflow");
        ghostHeld[c.toId()] += amount;
        ghostPot[PoolId.unwrap(k.toId())][inCurrency1 ? 1 : 0] += amount;
    }

    /// Anyone's withdraw: the owner gets all but the 1 wei kept, nobody else gets anything.
    function withdraw(uint8 who, uint8 c) external {
        if (everyOwner.length == 0) return;
        _claim(everyOwner[who % everyOwner.length], currencies[c % currencies.length]);
    }

    /// Anyone's burn.
    function burn() external {
        _claim(DEAD, duel);
    }

    function _claim(address who, Currency c) internal {
        uint256 cid = c.toId();
        uint256 owed = hook.owed(who, cid);
        check(owed == ghostOwed[who][cid], "owed is what the books say");
        uint256 before = c.balanceOf(who);
        uint256 callerBefore = c.balanceOf(address(this));
        (bool ok,) = address(hook).call(abi.encodeCall(IMDuelHook.withdraw, (who, c)));
        if (!ok) {
            // only an owner that can't take ETH may fail, and it keeps what it is owed
            check(c.isAddressZero() && who.code.length != 0, "a claim failed");
            check(hook.owed(who, cid) == owed, "a failed claim keeps the reward");
            return;
        }
        uint256 sent = owed > 1 ? owed - 1 : 0;
        check(c.balanceOf(who) - before == sent, "the owner gets all but 1 wei");
        if (who != address(this)) check(c.balanceOf(address(this)) == callerBefore, "the caller gets nothing");
        check(hook.owed(who, cid) == (owed > 1 ? 1 : owed), "1 wei stays owed");
        if (sent != 0) {
            ghostOwed[who][cid] -= sent;
            ghostOwedTotal[cid] -= sent;
            ghostHeld[cid] -= sent;
            claimsPaid++;
        }
    }

    /// The owner sends it elsewhere: what a contract that takes no ETH does.
    function withdrawElsewhere(uint8 who, uint8 c, uint8 to) external {
        if (everyOwner.length == 0) return;
        address owner = everyOwner[who % everyOwner.length];
        Currency cur = currencies[c % currencies.length];
        address dest = actors[to % 3]; // the first three take ETH
        uint256 cid = cur.toId();
        uint256 owed = hook.owed(owner, cid);
        uint256 before = cur.balanceOf(dest);
        vm.prank(owner);
        hook.withdrawTo(cur, dest);
        uint256 sent = owed > 1 ? owed - 1 : 0;
        if (dest != owner) check(cur.balanceOf(dest) - before == sent, "sent where the owner said");
        if (sent != 0) {
            ghostOwed[owner][cid] -= sent;
            ghostOwedTotal[cid] -= sent;
            ghostHeld[cid] -= sent;
            claimsPaid++;
        }
    }

    /// The factory collects its LP fees with a zero liquidity change: never blocked, never negative, and the hook's
    /// books don't move.
    function collectLpFees() external {
        bytes32 before = _hookBooks();
        vm.prank(controller);
        BalanceDelta d = factory.collect();
        check(d.amount0() >= 0 && d.amount1() >= 0, "a collect never pays");
        check(_hookBooks() == before, "a collect touches nothing of the hook's");
        collects++;
    }

    function _hookBooks() internal view returns (bytes32) {
        PoolKey memory k = pools[0];
        return keccak256(
            abi.encode(
                hook.chest(k.toId(), 0),
                hook.chest(k.toId(), 1),
                hook.game(k.toId()),
                manager.balanceOf(address(hook), imd.toId())
            )
        );
    }

    // ---------------------------------------------------------------- one swap, against the brief

    struct Before {
        IMDuelHook.Game g;
        uint256[2] pots;
        uint256 mainImdPot;
        uint256 burn;
        uint256 in0;
        uint256 in1;
        uint256[2] held;
        uint256[2] bal;
        bytes32[] others;
    }

    function _hookData(uint8 seed) internal view returns (bytes memory data, address named) {
        address a = actors[seed % actors.length];
        uint256 shape = (seed >> 3) % 8;
        if (shape == 0) return ("", address(0));
        if (shape <= 2) return (abi.encodePacked(a), a); // 20 bytes
        if (shape <= 4) return (abi.encode(a), a); // 32 bytes
        if (shape == 5) return (abi.encodePacked(uint256(1) << 200 | uint160(a)), address(0)); // dirty padding
        if (shape == 6) return (abi.encodePacked(DEAD), address(0));
        return (abi.encodePacked(address(hook)), address(0));
    }

    function _mover(IMDuelHook.Game memory g) internal pure returns (uint256) {
        return (g.gameNo & 1) ^ (g.base ^ 1) ^ (g.ply & 1);
    }

    function _gameHash(uint256 i) internal view returns (bytes32) {
        return keccak256(abi.encode(hook.game(pools[i].toId())));
    }

    function _size(PoolKey memory k, bool zeroForOne, bool exactOut, uint256 size, uint256 p)
        internal
        view
        returns (uint256)
    {
        // the launch pool is priced at about 1e-5 IMD per IMDUEL, the side duels at par
        size = bound(size, 1e6, 100e18);
        if (p != 0) return size;
        bool specifiedIsDuel = (zeroForOne != exactOut) == (k.currency0 == duel);
        return specifiedIsDuel ? size * 1e4 : size / 5;
    }

    function _swap(uint8 rawP, bool zeroForOne, uint256 size, bool exactOut, uint8 ownerSeed, uint8 signerSeed)
        internal
    {
        uint256 p = rawP % pools.length;
        PoolKey memory k = pools[p];
        PoolId id = k.toId();
        if (exactOut && zeroForOne && k.currency0.isAddressZero()) exactOut = false; // the test router pays native exact in
        size = _size(k, zeroForOne, exactOut, size, p);
        (bytes memory data, address named) = _hookData(ownerSeed);
        address signer = actors[signerSeed % actors.length];
        address expectedOwner = named == address(0) ? signer : named;

        Before memory b;
        b.g = hook.game(id);
        b.pots = [hook.chest(id, 0), hook.chest(id, 1)];
        b.mainImdPot = hook.chest(mainId, imdMainTeam);
        b.burn = hook.owed(DEAD, duel.toId());
        (b.in0, b.in1) = hook.gameInflow(id, b.g.gameNo);
        b.held = [
            manager.balanceOf(address(hook), k.currency0.toId()), manager.balanceOf(address(hook), k.currency1.toId())
        ];
        b.bal = [k.currency0.balanceOf(address(this)), k.currency1.balanceOf(address(this))];
        b.others = new bytes32[](pools.length);
        for (uint256 i; i < pools.length; i++) {
            b.others[i] = _gameHash(i);
        }

        int256 amount = exactOut ? int256(size) : -int256(size);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 value = zeroForOne && k.currency0.isAddressZero() ? size : 0;
        vm.recordLogs();
        vm.prank(address(this), signer);
        try router.swap{value: value}(
            k, SwapParams(zeroForOne, amount, limit), PoolSwapTest.TestSettings(false, false), data
        ) {}
        catch (bytes memory err) {
            vm.getRecordedLogs();
            // the only refusal an ordinary order can get: it can't fill whole
            check(
                keccak256(err)
                    == keccak256(
                        abi.encodeWithSelector(
                            CustomRevert.WrappedError.selector,
                            address(hook),
                            IHooks.afterSwap.selector,
                            abi.encodeWithSelector(IMDuelHook.PartialFill.selector),
                            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                        )
                    ),
                "a swap reverted for any reason but PartialFill"
            );
            refused++;
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        swaps++;
        for (uint256 i; i < pools.length; i++) {
            if (i != p) check(_gameHash(i) == b.others[i], "another duel's game is untouched");
        }
        _checkFee(k, id, b, logs, zeroForOne, exactOut, size);
        (uint256 paidRaw, uint256 gotRaw) = _raw(logs, zeroForOne);
        _checkPlay(k, id, b, logs, zeroForOne, paidRaw, gotRaw, expectedOwner);
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    function _rawBoth(Vm.Log[] memory logs) internal pure returns (uint256 a0, uint256 a1) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == SWAP_EVENT) {
                (int128 x0, int128 x1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                (a0, a1) = (_abs(x0), _abs(x1));
            }
        }
    }

    function _raw(Vm.Log[] memory logs, bool zeroForOne) internal pure returns (uint256 paid, uint256 got) {
        (uint256 a0, uint256 a1) = _rawBoth(logs);
        (paid, got) = zeroForOne ? (a0, a1) : (a1, a0);
    }

    /// 0.325% of each side into its own pot, 0.1% of the slice side burned or into the main IMD pot, HookSwap the sum.
    function _checkFee(
        PoolKey memory k,
        PoolId id,
        Before memory b,
        Vm.Log[] memory logs,
        bool zeroForOne,
        bool exactOut,
        uint256 size
    ) internal {
        (uint256 a0, uint256 a1) = _rawBoth(logs);
        uint256 spec = zeroForOne == !exactOut ? 0 : 1;
        uint256[2] memory base = spec == 0 ? [size, a1] : [a0, size];
        uint256[2] memory toPot = [base[0] * 65 / 20_000, base[1] * 65 / 20_000];
        // where the slice falls: $IMDUEL where the pool holds it, else IMD
        uint256 sliceTeam = k.currency1 == duel ? 1 : k.currency0 == duel ? 0 : k.currency1 == imd ? 1 : 0;
        bool burns = k.currency0 == duel || k.currency1 == duel;
        uint256 slice = base[sliceTeam] * 10 / 10_000;
        uint256[2] memory fee = [toPot[0], toPot[1]];
        fee[sliceTeam] += slice;

        check(
            manager.balanceOf(address(hook), k.currency0.toId()) - b.held[0] == fee[0], "claims in currency0: the fee"
        );
        check(
            manager.balanceOf(address(hook), k.currency1.toId()) - b.held[1] == fee[1], "claims in currency1: the fee"
        );
        ghostHeld[k.currency0.toId()] += fee[0];
        ghostHeld[k.currency1.toId()] += fee[1];
        ghostPot[PoolId.unwrap(id)][0] += toPot[0];
        ghostPot[PoolId.unwrap(id)][1] += toPot[1];
        if (burns) {
            check(hook.owed(DEAD, duel.toId()) - b.burn == slice, "the slice is owed to 0x...dEaD");
            ghostOwed[DEAD][duel.toId()] += slice;
            ghostOwedTotal[duel.toId()] += slice;
        } else {
            ghostPot[PoolId.unwrap(mainId)][imdMainTeam] += slice;
            check(hook.owed(DEAD, duel.toId()) == b.burn, "no IMDUEL here: nothing burned");
        }

        uint256 events;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != HOOK_SWAP) continue;
            events++;
            (int128 h0, int128 h1, uint24 pips) = abi.decode(logs[i].data, (int128, int128, uint24));
            check(_abs(h0) == fee[0] && _abs(h1) == fee[1] && h0 <= 0 && h1 <= 0, "HookSwap reports the fee taken");
            check(pips == 7_500, "HookSwap's rate is 0.75%");
        }
        check(events == (fee[0] + fee[1] == 0 ? 0 : 1), "one HookSwap for each swap that paid");

        // the order is exact on its specified side
        uint256 in_ = zeroForOne ? 0 : 1;
        uint256 out = 1 - in_;
        uint256[2] memory bal = [k.currency0.balanceOf(address(this)), k.currency1.balanceOf(address(this))];
        uint256 got = bal[out] - b.bal[out];
        uint256 spent = b.bal[in_] - bal[in_];
        uint256[2] memory raw = [a0, a1];
        if (exactOut) {
            check(got == size, "exact output: exactly the order");
            check(spent == raw[in_] + fee[in_], "the input side's fee on top");
        } else {
            check(spent == size, "exact input: exactly the order");
            check(got == raw[out] - fee[out], "the output side's fee off the top");
        }
    }

    function _checkPlay(
        PoolKey memory k,
        PoolId id,
        Before memory b,
        Vm.Log[] memory logs,
        bool zeroForOne,
        uint256 paid,
        uint256 got,
        address expectedOwner
    ) internal {
        IMDuelHook.Game memory a = hook.game(id);
        (uint256 now_, uint256 time) = (vm.getBlockNumber(), vm.getBlockTimestamp());
        uint256 mover = _mover(b.g);
        IMDuelHook.TopBid memory queued = b.g.bids[mover];
        bool due = queued.open && now_ > b.g.closeBlock;
        bool dead = due && now_ - b.g.closeBlock > 8_191; // nobody serves the dice
        uint256 moved;
        uint256 overs;
        uint8 result;
        for (uint256 i; i < logs.length; i++) {
            bytes32 t = logs[i].topics[0];
            if (t == MOVED) {
                moved++;
                (,,, address o, uint256 sz,,,) =
                    abi.decode(logs[i].data, (uint32, uint16, uint16, address, uint256, uint16, uint8, bool));
                check(o == queued.owner && sz == queued.size, "a move is played for the bid that stood");
            } else if (t == GAME_OVER) {
                overs++;
                (, result,) = abi.decode(logs[i].data, (uint32, uint8, uint16));
            } else if (t == FAILED) {
                fallbacks++;
            }
        }
        // a move only past its window, at most one a trade, and the trade past it always plays it (or its dice are gone)
        check(moved <= 1 && overs <= 1, "one move a trade");
        if (!due || dead) check(moved == 0 && overs == 0, "no move before its window closes");
        else check(moved == 1 || overs == 1, "the first trade past the window plays it");
        if (dead) {
            IMDuelHook.TopBid memory x = a.bids[mover];
            uint256 buyer = zeroForOne ? 1 : 0;
            if (buyer != mover || paid * 100 <= uint256(queued.size) * 110) {
                check(
                    x.owner == address(0) && x.size == queued.size && x.strength == queued.strength,
                    "a lost hash replays the bid for nobody"
                );
            }
            check(a.closeBlock == now_, "in this block's window");
            expired++;
        }
        moves += moved;
        if (a.gameNo == b.g.gameNo) {
            check(a.ply == b.g.ply + moved, "the half-move count follows the moves");
        } else {
            check(
                a.gameNo == b.g.gameNo + 1 && a.ply == 0 && overs == 1,
                "a game ends once, and the next starts at its start"
            );
        }
        check(a.gameNo >= highestGame[PoolId.unwrap(id)], "a finished game never reopens");
        highestGame[PoolId.unwrap(id)] = a.gameNo;

        // the mate
        bool isMate = overs == 1 && moved == 1 && (result == 1 || result == 2);
        (uint256 potAfter0, uint256 potAfter1) = (hook.chest(id, 0), hook.chest(id, 1));
        uint256 loser = 1 - mover;
        uint256 mateAmount;
        uint256 mateEvents;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != MATE_PAID) continue;
            mateEvents++;
            (, address to, Currency c, uint256 amount) = abi.decode(logs[i].data, (uint32, address, Currency, uint256));
            check(isMate, "only a mate pays");
            check(to == queued.owner, "the mating move's owner");
            check(c == (loser == 0 ? k.currency0 : k.currency1), "in the loser's token");
            mateAmount = amount;
            ghostOwed[to][c.toId()] += amount;
            ghostOwedTotal[c.toId()] += amount;
            if (!seenOwner[to]) {
                seenOwner[to] = true;
                everyOwner.push(to);
            }
        }
        if (isMate) {
            mates++;
            uint256 potWhenPlayed = (loser == 0 ? potAfter0 : potAfter1) + mateAmount;
            uint256 want = potWhenPlayed / 4;
            if (uint256(queued.size) * 2 < want) want = uint256(queued.size) * 2;
            uint256 inflow = loser == 0 ? b.in0 : b.in1;
            if (inflow < want) want = inflow;
            if (queued.owner == address(0)) want = 0;
            check(mateAmount == want, "the mate pays the least of the three");
            check(mateEvents == (want == 0 ? 0 : 1), "MatePaid for a payment, once");
            if (want != 0) matesPaid++;
            ghostPot[PoolId.unwrap(id)][loser] -= mateAmount;
        } else {
            check(mateEvents == 0, "nothing but a mate pays");
            if (overs == 1) draws++;
        }

        // the main duel's counts, for display
        if (PoolId.unwrap(id) == PoolId.unwrap(mainId) && moved == 1 && queued.owner != address(0)) {
            ghostMainOwnedMoves++;
            if (isMate) ghostMainMates++;
            if (!seenPlayer[queued.owner]) {
                seenPlayer[queued.owner] = true;
                mainPlayers.push(queued.owner);
            }
        }

        // the books: every pot is what the handler reckons
        check(hook.chest(id, 0) == ghostPot[PoolId.unwrap(id)][0], "pot 0 is what the books say");
        check(hook.chest(id, 1) == ghostPot[PoolId.unwrap(id)][1], "pot 1 is what the books say");

        // the bid. What the trade faces is its team's top bid after any move it played
        uint256 team = zeroForOne ? 1 : 0;
        IMDuelHook.TopBid memory prior = b.g.bids[team];
        bool cleared = team == mover && (moved == 1 || (due && !dead && overs == 1));
        bool priorOpen = prior.open && !cleared;
        bool beats = !priorOpen || paid * 100 > uint256(prior.size) * 110;
        IMDuelHook.TopBid memory top = a.bids[team];
        if (beats) {
            check(top.open && top.owner == expectedOwner, "a bid that clears the raise owns the move");
            check(top.size == paid, "its size is what it paid");
            check(
                top.strength == Strength.fromShare(got, hook.chest(id, team)),
                "its strength is its share of its own pot"
            );
        } else if (dead && team == mover) {
            check(top.owner == address(0) && top.size == queued.size, "the lost hash's bid stands, for nobody");
        } else {
            check(
                top.owner == prior.owner && top.size == prior.size && top.strength == prior.strength,
                "a smaller bid changes nothing"
            );
        }
        check(top.strength <= 9_000, "strength stops at 90%");

        // the timeout: only the other team's trade, only when the mover has no bid and 600 seconds have passed
        if (moved == 0 && overs == 0 && team != mover && !queued.open) {
            if (time >= uint256(b.g.turnStart) + 600) {
                IMDuelHook.TopBid memory x = a.bids[mover];
                check(
                    x.open && x.owner == address(0) && x.size == 0 && x.strength == 0,
                    "a silent side's move opens at 0%"
                );
                check(a.closeBlock == now_, "its window is this block");
                timeouts++;
            } else {
                check(!a.bids[mover].open, "no timeout before 600 seconds");
            }
        }

        // the window
        if (moved == 1 || overs == 1) {
            check(a.closeBlock >= now_ && a.closeBlock <= now_ + TURN_BLOCKS - 1, "a new move's window");
        } else if (team == mover && !queued.open) {
            bool late = now_ >= b.g.closeBlock;
            check(
                a.closeBlock == (late ? now_ + TURN_BLOCKS - 1 : b.g.closeBlock), "a late first bid opens a full window"
            );
        }
    }
}

abstract contract LaunchInvariantBase is LaunchFixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LaunchHandler handler;
    Launched l;
    PoolKey[] keys;
    Currency xc;
    address[] holders;

    function tokenIs0() internal pure virtual returns (bool);

    /// How often the scripted engine reports each ending; the real-engine suites override installEngine and this.
    function scriptCadence() internal virtual {
        script.cadence(5, 11, 17, 3);
    }

    function setUp() public {
        setUpLaunches();
        scriptCadence();
        l = launched(tokenIs0());

        MockERC20 x = mockToken("X", "X");
        xc = Currency.wrap(address(x));
        x.mint(address(this), 1e36);
        x.approve(address(modifyLiquidityRouter), type(uint256).max);
        l.token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 1e30);

        keys.push(l.key);
        (Currency a0, Currency a1) = xc < imd ? (xc, imd) : (imd, xc);
        keys.push(PoolKey(a0, a1, 3_000, 60, IHooks(address(l.hook))));
        keys.push(PoolKey(CurrencyLibrary.ADDRESS_ZERO, imd, 3_000, 60, IHooks(address(l.hook))));
        Currency d = Currency.wrap(address(l.token));
        (a0, a1) = xc < d ? (xc, d) : (d, xc);
        keys.push(PoolKey(a0, a1, 3_000, 60, IHooks(address(l.hook))));
        for (uint256 i = 1; i < keys.length; i++) {
            manager.initialize(keys[i], SQRT_PRICE_1_1);
            modifyLiquidityRouter.modifyLiquidity{value: keys[i].currency0.isAddressZero() ? 1e24 : 0}(
                keys[i], ModifyLiquidityParams(-887220, 887220, 1e23, 0), ""
            );
        }

        Currency[] memory cs = new Currency[](4);
        (cs[0], cs[1], cs[2], cs[3]) = (imd, d, xc, CurrencyLibrary.ADDRESS_ZERO);
        PoolKey[] memory ks = new PoolKey[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            ks[i] = keys[i];
        }
        handler = new LaunchHandler(l.hook, swapRouter, l.factory, address(this), ks, cs, d);

        // the handler trades: tokens, approvals, the factory's spare IMDUEL
        vm.startPrank(address(handler));
        MockERC20(IMD).approve(address(swapRouter), type(uint256).max);
        MockERC20(IMD).approve(address(l.hook), type(uint256).max);
        x.approve(address(swapRouter), type(uint256).max);
        x.approve(address(l.hook), type(uint256).max);
        l.token.approve(address(swapRouter), type(uint256).max);
        l.token.approve(address(l.hook), type(uint256).max);
        vm.stopPrank();
        MockERC20(IMD).mint(address(handler), 1e30);
        x.mint(address(handler), 1e30);
        vm.prank(address(l.factory));
        l.token.transfer(address(handler), 3e25);

        holders = [
            address(handler),
            address(manager),
            address(l.factory),
            address(this),
            DEAD,
            address(l.hook),
            address(swapRouter),
            address(modifyLiquidityRouter),
            handler.actors(0),
            handler.actors(1),
            handler.actors(2),
            handler.actors(3)
        ];

        bytes4[] memory calls = new bytes4[](12);
        calls[0] = LaunchHandler.buyExactIn.selector;
        calls[1] = LaunchHandler.buyExactInAgain.selector;
        calls[2] = LaunchHandler.buyExactOut.selector;
        calls[3] = LaunchHandler.tradeNextBlock.selector;
        calls[4] = LaunchHandler.roll.selector;
        calls[5] = LaunchHandler.silence.selector;
        calls[6] = LaunchHandler.longSilence.selector;
        calls[7] = LaunchHandler.fund.selector;
        calls[8] = LaunchHandler.withdraw.selector;
        calls[9] = LaunchHandler.burn.selector;
        calls[10] = LaunchHandler.withdrawElsewhere.selector;
        calls[11] = LaunchHandler.collectLpFees.selector;
        targetSelector(FuzzSelector(address(handler), calls));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- the properties, shared by the suites below

    /// Everything the hook holds in claims is what came in less what went out, and is exactly what it owes: the pots
    /// and the rewards, the burn among them. Nothing is created and nothing is stranded.
    function checkConservation() internal view {
        for (uint256 i; i < handler.currencyCount(); i++) {
            Currency c = handler.currencies(i);
            uint256 cid = c.toId();
            uint256 pots;
            for (uint256 p; p < handler.poolCount(); p++) {
                PoolKey memory k = handler.poolKey(p);
                if (k.currency0 == c) pots += l.hook.chest(k.toId(), 0);
                if (k.currency1 == c) pots += l.hook.chest(k.toId(), 1);
            }
            uint256 held = manager.balanceOf(address(l.hook), cid);
            assertEq(held, handler.ghostHeld(cid), "claims = fees and donations in, less claims out");
            assertEq(held, pots + handler.ghostOwedTotal(cid), "claims = pots + rewards + burn");
            assertLe(held, c.balanceOf(address(manager)), "the manager really has what the hook claims");
        }
    }

    /// Each pot is what the handler's books say, and each owed entry too.
    function checkEntries() internal view {
        for (uint256 p; p < handler.poolCount(); p++) {
            PoolId id = handler.poolKey(p).toId();
            assertEq(l.hook.chest(id, 0), handler.pot(id, 0), "pot 0");
            assertEq(l.hook.chest(id, 1), handler.pot(id, 1), "pot 1");
        }
        for (uint256 i; i < handler.currencyCount(); i++) {
            uint256 cid = handler.currencies(i).toId();
            for (uint256 o; o < handler.ownerCount(); o++) {
                address who = handler.everyOwner(o);
                assertEq(l.hook.owed(who, cid), handler.ghostOwed(who, cid), "owed");
            }
            assertEq(l.hook.owed(DEAD, cid), handler.ghostOwed(DEAD, cid), "the burn");
        }
        assertEq(l.hook.owed(address(l.hook), handler.duel().toId()), 0, "the hook is never owed");
        assertEq(l.hook.owed(address(manager), handler.duel().toId()), 0, "the manager is never owed");
        assertEq(l.hook.owed(address(0), handler.duel().toId()), 0, "nobody at zero is owed");
    }

    /// The token's supply is fixed and stays with the addresses that could ever receive it.
    function checkSupply() internal view {
        uint256 total;
        for (uint256 i; i < holders.length; i++) {
            total += l.token.balanceOf(holders[i]);
        }
        for (uint256 o; o < handler.ownerCount(); o++) {
            address who = handler.everyOwner(o);
            bool known;
            for (uint256 i; i < holders.length; i++) {
                known = known || holders[i] == who;
            }
            if (!known) total += l.token.balanceOf(who);
        }
        assertEq(l.token.totalSupply(), 1e27, "fixed");
        assertEq(total, 1e27, "held, every wei, by someone the launch paid");
    }

    /// Display counts follow the main duel's owned moves one for one, and the list holds each player once.
    function checkStats() internal view {
        uint256 pieceMoves;
        uint256 mateCount;
        assertEq(l.hook.playerCount(), handler.playerCount(), "one list entry per player");
        for (uint256 i; i < l.hook.playerCount(); i++) {
            address who = l.hook.players(i);
            (uint256 m, uint256 r) = l.hook.stats(who);
            for (uint256 piece; piece < 6; piece++) {
                pieceMoves += (m >> (piece * 20)) & 0xfffff;
            }
            mateCount += r & 0xffff;
            for (uint256 j; j < i; j++) {
                assertTrue(l.hook.players(j) != who, "listed once");
            }
        }
        assertEq(pieceMoves, handler.ghostMainOwnedMoves(), "every owned main-duel move counted once");
        assertEq(mateCount, handler.ghostMainMates(), "every owned main-duel mate counted once");
    }

    /// Boards stay real and windows stay in bounds, whatever was played.
    function checkGames() internal view {
        for (uint256 p; p < handler.poolCount(); p++) {
            IMDuelHook.Game memory g = l.hook.game(handler.poolKey(p).toId());
            assertTrue(g.live);
            uint256 wk;
            uint256 bk;
            for (uint256 s; s < 64; s++) {
                uint256 piece = (g.board >> (s << 2)) & 0xF;
                if (piece == 6) wk++;
                if (piece == 14) bk++;
            }
            assertEq(wk, 1, "one white king");
            assertEq(bk, 1, "one black king");
            assertLt(g.ply, l.hook.MAX_PLY());
            assertLt(g.quiet, l.hook.MAX_QUIET_PLY());
            assertLe(g.closeBlock, vm.getBlockNumber() + 2, "a window ends at most 3 blocks out");
            assertLe(g.moveStrength, 9_000);
        }
        assertEq(PoolId.unwrap(l.hook.mainId()), PoolId.unwrap(l.id), "the main duel never changes");
        assertEq(Currency.unwrap(l.hook.imduel()), address(l.token));
        assertTrue(l.hook.game(l.id).main);
    }

    /// After every sequence: each claim can still be paid in full, in real tokens, and what stays is the pots and the
    /// wei each claim keeps; and each duel still trades.
    function checkDrain() internal {
        for (uint256 i; i < handler.currencyCount(); i++) {
            Currency c = handler.currencies(i);
            uint256 cid = c.toId();
            uint256 pots;
            for (uint256 p; p < handler.poolCount(); p++) {
                PoolKey memory k = handler.poolKey(p);
                if (k.currency0 == c) pots += l.hook.chest(k.toId(), 0);
                if (k.currency1 == c) pots += l.hook.chest(k.toId(), 1);
            }
            uint256 left;
            for (uint256 o; o < handler.ownerCount(); o++) {
                address who = handler.everyOwner(o);
                if (who == address(0)) continue;
                if (who.code.length != 0) {
                    address to = handler.actors(0);
                    vm.prank(who);
                    l.hook.withdrawTo(c, to);
                } else {
                    l.hook.withdraw(who, c);
                }
                left += l.hook.owed(who, cid);
                assertLe(l.hook.owed(who, cid), 1, "drained but for the kept wei");
            }
            l.hook.withdraw(DEAD, c);
            assertLe(l.hook.owed(DEAD, cid), 1);
            left += l.hook.owed(DEAD, cid);
            assertEq(manager.balanceOf(address(l.hook), cid), pots + left, "only the pots and the kept wei stay");
        }
    }
}

/// The scripted engine: mates, stalemates, engine failures and double failures all happen in every run.
abstract contract ScriptedSuite is LaunchInvariantBase {
    function afterInvariant() external {
        emit log_named_uint("swaps", handler.swaps());
        emit log_named_uint("refused", handler.refused());
        emit log_named_uint("moves", handler.moves());
        emit log_named_uint("mates", handler.mates());
        emit log_named_uint("mates paid", handler.matesPaid());
        emit log_named_uint("draws", handler.draws());
        emit log_named_uint("fallbacks", handler.fallbacks());
        emit log_named_uint("timeouts", handler.timeouts());
        emit log_named_uint("expired", handler.expired());
        emit log_named_uint("claims", handler.claimsPaid());
        emit log_named_uint("collects", handler.collects());
        checkDrain();
    }

    /// A fixed walk through the handler, so that "the invariants held" can't mean "the run reached nothing": every
    /// ending and every claim path happens under the same checks. The handler reverts on any broken promise.
    function test_theHandlerReachesEveryPath() public {
        for (uint8 i; i < 90; i++) {
            handler.buyExactIn(0, i % 2 == 0, 3e17 + uint256(i) * 1e16, i, i >> 1);
            handler.tradeNextBlock(i % 4, i % 3 == 0, 1e18 + uint256(i) * 1e15, uint8((uint256(i) * 3) % 251), i, 3);
            handler.buyExactOut(1 + i % 3, i % 2 == 1, 1e15, uint8((uint256(i) * 5) % 251), i);
            handler.roll(4);
            handler.tradeNextBlock(0, i % 3 != 0, 2e15, uint8((uint256(i) * 7) % 251), i, 4);
            handler.tradeNextBlock(i % 4, i % 2 == 0, 2e15, uint8((uint256(i) * 11) % 251), i, 4);
            if (i % 9 == 0) handler.fund(i % 4, i % 2 == 0, 1e18);
            if (i % 11 == 0) handler.silence();
            if (i % 31 == 5) handler.longSilence();
            handler.withdraw(i, i);
            handler.withdrawElsewhere(i, i, i);
            handler.burn();
            if (i % 6 == 0) handler.collectLpFees();
        }
        assertGt(handler.swaps(), 300, "traded");
        assertGt(handler.moves(), 30, "moves played");
        assertGt(handler.mates(), 5, "mates");
        assertGt(handler.matesPaid(), 3, "mates paid");
        assertGt(handler.draws(), 3, "draws");
        assertGt(handler.fallbacks(), 3, "engine failures");
        assertGt(handler.timeouts(), 0, "timeouts");
        assertGt(handler.expired(), 0, "lost dice");
        assertGt(handler.claimsPaid(), 3, "claims");
        assertGt(handler.collects(), 3, "LP collects");
        checkConservation();
        checkEntries();
        checkSupply();
        checkStats();
        checkGames();
        checkDrain();
    }
}

contract LaunchInvariantTokenBelowImd is ScriptedSuite {
    function tokenIs0() internal pure override returns (bool) {
        return true;
    }

    /// Claims, pots, rewards, the burn and the token's supply, after every call of every sequence.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theMoneyIsAllAccountedFor() public view {
        checkConservation();
        checkEntries();
        checkSupply();
    }

    /// Boards and windows stay sound, and the display counts follow the main duel.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gamesAndCountsStaySound() public view {
        checkGames();
        checkStats();
    }
}

contract LaunchInvariantTokenAboveImd is ScriptedSuite {
    function tokenIs0() internal pure override returns (bool) {
        return false;
    }

    /// Claims, pots, rewards, the burn and the token's supply, after every call of every sequence.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theMoneyIsAllAccountedFor() public view {
        checkConservation();
        checkEntries();
        checkSupply();
    }

    /// Boards and windows stay sound, and the display counts follow the main duel.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gamesAndCountsStaySound() public view {
        checkGames();
        checkStats();
    }
}

/// Real chess: ChessEngineV5's build at the engine's address, no scripted ending. Fewer runs, each move costing what
/// it costs. The same books must hold, and every move the engine returns must be one the board can take.
abstract contract RealEngineSuite is LaunchInvariantBase {
    function installEngine() internal override {
        vm.etch(ENGINE, vm.deployCode("ChessEngineV5.sol:ChessEngineV5").code);
    }

    function scriptCadence() internal override {}

    function afterInvariant() external {
        emit log_named_uint("swaps", handler.swaps());
        emit log_named_uint("moves", handler.moves());
        emit log_named_uint("fallbacks", handler.fallbacks());
        assertEq(handler.fallbacks(), 0, "the real engine never fails a move");
        checkDrain();
    }
}

contract LaunchRealEngineTokenBelowImd is RealEngineSuite {
    function tokenIs0() internal pure override returns (bool) {
        return true;
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_realChessKeepsTheBooks() public view {
        checkConservation();
        checkEntries();
        checkSupply();
        checkStats();
        checkGames();
    }
}

contract LaunchRealEngineTokenAboveImd is RealEngineSuite {
    function tokenIs0() internal pure override returns (bool) {
        return false;
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_realChessKeepsTheBooks() public view {
        checkConservation();
        checkEntries();
        checkSupply();
        checkStats();
        checkGames();
    }
}
