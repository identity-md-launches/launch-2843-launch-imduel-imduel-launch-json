// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Rules} from "../src/Rules.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {IMDuelToken} from "../src/IMDuelToken.sol";
import {V4Fixture} from "./V4Fixture.sol";
import {AtomicLaunchProbe} from "./FactoryLaunch.t.sol";

/// Stands at launch.json's engine address so the production hook, which has no setter of any kind, can be driven
/// through its real swap path into every ending. It plays a legal move picked by the seed by the real rules, and
/// then reports what the test scripted. The hook trusts the engine's report, so a scripted mate takes the same code
/// path a chess mate takes; the suites that use the real engine sit beside these (LaunchRealEngine*, Game, Draws).
contract ScriptEngine is IChessEngine {
    uint8 public forcedStatus; // reported instead of the real status when nonzero: 1 stalemate, 2 checkmate
    bool public forcedCheck;
    bool public forcedInsufficient;
    bool public playReverts;
    bool public anyReverts;
    bool public playShort; // answers with too few bytes
    bool public playBadMove; // answers with a move number past the board
    uint256 public mateEvery; // nonzero: every seed divisible by it reports a mate
    uint256 public drawEvery; // nonzero: every seed divisible by it reports a stalemate
    uint256 public playFailsEvery; // nonzero: every seed divisible by it fails `play`
    uint256 public anyFailsEvery; // nonzero: every seed divisible by it fails `playAny` too

    function script(uint8 status, bool check, bool insufficient) external {
        (forcedStatus, forcedCheck, forcedInsufficient) = (status, check, insufficient);
    }

    function fail(bool play_, bool any_, bool short_, bool badMove_) external {
        (playReverts, anyReverts, playShort, playBadMove) = (play_, any_, short_, badMove_);
    }

    function cadence(uint256 mate, uint256 draw, uint256 playFails, uint256 anyFails) external {
        (mateEvery, drawEvery, playFailsEvery, anyFailsEvery) = (mate, draw, playFails, anyFails);
    }

    function play(
        uint256 board,
        uint32 mover,
        uint32 other,
        bool black,
        uint256,
        uint256 seed,
        uint64[8] calldata,
        uint32,
        uint16
    ) external view returns (uint16 m, Rules.Played memory r) {
        if (playReverts || (playFailsEvery != 0 && seed % playFailsEvery == 0)) {
            revert("scripted failure");
        }
        if (playShort) {
            assembly ("memory-safe") {
                return(0, 32)
            }
        }
        (m, r) = _legal(board, mover, other, black, seed);
        if (playBadMove) m = 4096;
        if (forcedStatus != 0) r.status = forcedStatus;
        if (mateEvery != 0 && seed % mateEvery == 0) r.status = 2;
        else if (drawEvery != 0 && seed % drawEvery == 0) r.status = 1;
        if (r.status == 2 || forcedCheck) r.check = true;
        if (forcedInsufficient) r.insufficient = true;
    }

    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256 seed)
        external
        view
        returns (uint16 m, Rules.Played memory r)
    {
        if (anyReverts || (anyFailsEvery != 0 && seed % anyFailsEvery == 0)) revert("scripted failure");
        (m, r) = _legal(board, mover, other, black, seed);
        if (forcedStatus != 0) r.status = forcedStatus;
    }

    function _legal(uint256 board, uint32 mover, uint32 other, bool black, uint256 seed)
        internal
        pure
        returns (uint16 m, Rules.Played memory)
    {
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        uint16[] memory moves = Bitboard.legalMoves(Bitboard.fromBoard(board, w, b), !black);
        m = moves[seed % moves.length];
        return (m, Rules.move(board, mover, other, black, m));
    }
}

/// EIP-2935 as Ethereum runs it: the hash of each of the last 8,191 blocks, and a revert for anything else.
contract HistoryContract {
    fallback(bytes calldata data) external returns (bytes memory) {
        uint256 n = abi.decode(data, (uint256));
        require(n < block.number && block.number - n <= 8_191);
        return abi.encode(keccak256(abi.encode("history", n)));
    }
}

/// The launch as launch.json states it: the production IMDuelHook and IMDuelToken built by CREATE2 from one factory
/// call with the committed constructor arguments, the pool at fee 12500 and spacing 60, seeded single-sided. Both
/// token orders live side by side on one PoolManager, picked by `tokenIs0`, so a fuzz run does not mine salts.
abstract contract LaunchFixture is V4Fixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant ENGINE = 0xc21788F704a8b9456f7391A01d8a3D95Be215a27;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant HOOK_SWAP = keccak256("HookSwap(bytes32,address,int128,int128,uint24)");
    bytes32 internal constant MOVED =
        keccak256("Moved(bytes32,uint32,uint16,uint16,address,uint256,uint16,uint8,bool)");
    bytes32 internal constant MATE_PAID = keccak256("MatePaid(bytes32,uint32,address,address,uint256)");
    bytes32 internal constant GAME_OVER = keccak256("GameOver(bytes32,uint32,uint8,uint16)");
    bytes32 internal constant DRAW = keccak256("DrawTriggered(bytes32,uint32,uint8,uint16)");
    bytes32 internal constant FAILED = keccak256("EngineFailed(bytes32,uint32,uint16)");

    struct Launched {
        AtomicLaunchProbe factory;
        IMDuelToken token;
        IMDuelHook hook;
        PoolKey key;
        PoolId id;
        uint256 duelTeam; // which pool currency (and team) is $IMDUEL
        uint256 imdTeam;
    }

    Launched internal below; // $IMDUEL sorts below IMD: it is currency0
    Launched internal above; // $IMDUEL sorts above IMD: it is currency1
    ScriptEngine internal script = ScriptEngine(ENGINE);
    Currency internal imd = Currency.wrap(IMD);

    function setUpLaunches() internal {
        vm.chainId(1);
        deployV4();
        vm.etch(IMD, address(mockToken("IMD", "IMD")).code);
        vm.etch(HISTORY, address(new HistoryContract()).code);
        installEngine();
        below = launchOne(true);
        above = launchOne(false);
        MockERC20(IMD).mint(address(this), 1e30);
        MockERC20(IMD).approve(address(swapRouter), type(uint256).max);
        MockERC20(IMD).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    /// The scripted engine by default; a suite that wants real chess overrides this.
    function installEngine() internal virtual {
        vm.etch(ENGINE, address(new ScriptEngine()).code);
    }

    function launchOne(bool tokenIs0) internal returns (Launched memory l) {
        l.factory = new AtomicLaunchProbe(manager);
        l.factory.launch(vm.getCode("IMDuelToken.sol:IMDuelToken"), vm.getCode("IMDuelHook.sol:IMDuelHook"), tokenIs0);
        l.token = l.factory.token();
        l.hook = l.factory.hook();
        Currency duel = Currency.wrap(address(l.token));
        l.key = tokenIs0
            ? PoolKey(duel, imd, 12_500, 60, IHooks(address(l.hook)))
            : PoolKey(imd, duel, 12_500, 60, IHooks(address(l.hook)));
        l.id = l.key.toId();
        (l.duelTeam, l.imdTeam) = tokenIs0 ? (uint256(0), uint256(1)) : (uint256(1), uint256(0));
        // the trader's own IMDUEL, from the 20% the factory keeps after seeding
        vm.prank(address(l.factory));
        l.token.transfer(address(this), 1e26);
        l.token.approve(address(swapRouter), type(uint256).max);
        l.token.approve(address(l.hook), type(uint256).max);
        MockERC20(IMD).approve(address(l.hook), type(uint256).max);
    }

    function launched(bool tokenIs0) internal view returns (Launched memory) {
        return tokenIs0 ? below : above;
    }

    // ---------------------------------------------------------------- trading

    /// The zeroForOne that buys team `team`'s token.
    function buying(uint256 team) internal pure returns (bool) {
        return team == 1;
    }

    /// Exact input of `amount`, buying team `team`'s token.
    function buy(Launched memory l, uint256 team, uint256 amount, bytes memory data) internal returns (BalanceDelta) {
        return swap(l.key, buying(team), -int256(amount), data);
    }

    /// $IMDUEL bought with `imdIn` IMD, the launch's first possible trade.
    function buyDuel(Launched memory l, uint256 imdIn, address owner) internal returns (BalanceDelta) {
        return buy(l, l.duelTeam, imdIn, owner == address(0) ? bytes("") : abi.encodePacked(owner));
    }

    /// Enough two-way trading that both reserves hold plenty, with nobody named: the launch pool opens with no IMD.
    function deepen(Launched memory l) internal {
        script.cadence(0, 0, 0, 0);
        buy(l, l.duelTeam, 10_000e18, "");
    }

    /// More liquidity on both sides of the price, for a test that must sell for IMD before anyone has bought.
    function addFullRange(Launched memory l, int256 liquidity) internal {
        l.token.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            l.key, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(uint256(1))), ""
        );
    }

    function st(Launched memory l) internal view returns (IMDuelHook.Game memory) {
        return l.hook.game(l.id);
    }

    /// The team whose move is being bid for.
    function moverOf(IMDuelHook.Game memory g) internal pure returns (uint256) {
        return (g.gameNo & 1) ^ (g.base ^ 1) ^ (g.ply & 1);
    }

    /// Rolls past the move's window: the next trade plays it.
    function closeWindow(Launched memory l) internal {
        vm.roll(uint256(st(l).closeBlock) + 1);
        vm.warp(vm.getBlockTimestamp() + 48);
    }

    function nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function claimsOf(Launched memory l, Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(l.hook), c.toId());
    }

    function cur(Launched memory l, uint256 team) internal pure returns (Currency) {
        return team == 0 ? l.key.currency0 : l.key.currency1;
    }

    /// Chests of the main duel plus what is owed to `who` and the burn: everything the launch's hook may hold in a
    /// main-duel currency when no side duel has been opened.
    function assertBooks(Launched memory l, address[] memory who) internal view {
        for (uint256 team; team < 2; team++) {
            Currency c = cur(l, team);
            uint256 total = l.hook.chest(l.id, team) + l.hook.owed(DEAD, c.toId());
            for (uint256 i; i < who.length; i++) {
                total += l.hook.owed(who[i], c.toId());
            }
            assertEq(claimsOf(l, c), total, "held = chest + burn + owed");
        }
    }

    function one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function countOf(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) n++;
        }
    }

    /// The amounts the PoolManager's Swap event reports: the raw swap, before the hook's after-swap delta.
    function rawSwap(Vm.Log[] memory logs) internal pure returns (int128 a0, int128 a1) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == SWAP_EVENT) {
                (a0, a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    /// The MatePaid in `logs`, if any.
    function matePaid(Vm.Log[] memory logs)
        internal
        pure
        returns (bool seen, address owner, Currency c, uint256 amount)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == MATE_PAID) {
                seen = true;
                (, owner, c, amount) = abi.decode(logs[i].data, (uint32, address, Currency, uint256));
            }
        }
    }
}
