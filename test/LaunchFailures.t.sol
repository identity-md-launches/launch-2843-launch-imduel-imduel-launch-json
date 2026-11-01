// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

/// Pays ETH to this, and it trades on the main duel from inside the hook's unlock: the one way a recipient runs code
/// while the hook has the PoolManager unlocked. Its own swap settles itself, so the unlock can still finish.
contract TradingRecipient {
    IPoolManager immutable manager;
    PoolKey key;
    bool zeroForOne;
    bool public traded;
    bytes public tryWhileInside;
    address public target;
    bool public insideCallFailed;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function arm(PoolKey memory key_, bool zeroForOne_, address target_, bytes memory call_) external {
        (key, zeroForOne, target, tryWhileInside) = (key_, zeroForOne_, target_, call_);
    }

    receive() external payable {
        if (target != address(0)) {
            (bool ok,) = target.call(tryWhileInside);
            insideCallFailed = !ok;
        }
        traded = true;
        // the manager is unlocked by the hook's claim: act directly, and settle before returning
        BalanceDelta d = manager.swap(
            key,
            SwapParams(zeroForOne, -1e18, zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341),
            ""
        );
        (Currency pay, int128 owe, Currency take_, int128 get) = zeroForOne
            ? (key.currency0, d.amount0(), key.currency1, d.amount1())
            : (key.currency1, d.amount1(), key.currency0, d.amount0());
        manager.sync(pay);
        MockERC20(Currency.unwrap(pay)).transfer(address(manager), uint128(-owe));
        manager.settle();
        manager.take(take_, address(this), uint128(get));
    }
}

/// Refuses every plain ETH payment.
contract EthRefuser {
    function withdrawTo(IMDuelHook hook, Currency c, address to) external {
        hook.withdrawTo(c, to);
    }
}

/// A token that, called inside fundChest's unlock, points the PoolManager's synced currency at another token and pays
/// that in: the hook's settle() would count it as `paid`. It tries to turn real IMD credit into a claim on its own
/// token, or the other way round. `mode`: 0 plain, 1 re-sync to `other` after paying it in, 2 report nothing delivered
/// (returns false and moves nothing).
contract SyncSwitchToken is MockERC20 {
    IPoolManager immutable manager;
    Currency immutable other;
    uint8 public mode;

    constructor(IPoolManager manager_, Currency other_) MockERC20("Switch", "SW", 18) {
        (manager, other) = (manager_, other_);
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == 2) return false;
        if (mode == 1) {
            manager.sync(other);
            MockERC20(Currency.unwrap(other)).transfer(address(manager), amount);
            return true;
        }
        return super.transferFrom(from, to, amount);
    }
}

/// Calls a function of the hook from inside an unlock of its own: the hook's claims need an unlock of their own.
contract InsideUnlock is IUnlockCallback {
    IPoolManager immutable manager;
    address target;
    bytes data;
    bool public ok;
    bytes public err;

    constructor(IPoolManager m) {
        manager = m;
    }

    function run(address t, bytes memory d) external {
        (target, data) = (t, d);
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        (ok, err) = target.call(data);
        return "";
    }
}

/// The unhappy paths of the launch on the production bytecode: who may not call what, which orders are refused, which
/// hookData doesn't name an owner, the exact block and second a window and a timeout turn, claims that fail or have
/// nothing to pay, hostile tokens and recipients, and an engine that misbehaves in every way the hook handles.
contract LaunchFailuresTest is LaunchFixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        setUpLaunches();
    }

    /// What a hook's custom error looks like after the PoolManager wrapped it.
    function wrapped(address hook, bytes4 callback, bytes4 reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function other(string memory name) internal returns (Currency c) {
        MockERC20 t = mockToken(name, name);
        t.mint(address(this), 1e36);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        c = Currency.wrap(address(t));
    }

    // ---------------------------------------------------------------- nobody but the manager, and nothing privileged

    /// Every entry point the manager alone may reach refuses every other caller, whoever pretends to be it.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_nobodyButTheManagerDrivesTheCallbacks(address caller, bool tokenIs0, bytes calldata hookData)
        public
    {
        Launched memory l = launched(tokenIs0);
        vm.assume(caller != address(manager));
        SwapParams memory p = SwapParams(true, -1e18, MIN_PRICE_LIMIT);
        vm.startPrank(caller);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        l.hook.afterInitialize(caller, l.key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        l.hook.beforeSwap(caller, l.key, p, hookData);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        l.hook.afterSwap(caller, l.key, p, BalanceDelta.wrap(0), hookData);
        vm.expectRevert(IMDuelHook.NotManager.selector);
        l.hook.unlockCallback(abi.encode(uint8(0), abi.encode(caller, imd, uint256(1))));
        vm.stopPrank();
    }

    /// No owner, admin, pause, upgrade or signer function answers, nor any callback the launch doesn't enable, and the
    /// hook takes no plain ETH. The hook's address carries exactly launch.json's five permissions.
    function test_theHookHasNoPrivilegedSurface() public {
        Launched memory l = below;
        string[17] memory sigs = [
            "owner()",
            "admin()",
            "getOwner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "paused()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "implementation()",
            "setEngine(address)",
            "setSigner(address)",
            "signer()",
            "setTurnBlocks(uint256)",
            "setFee(uint24)",
            "sweep(address,address)"
        ];
        for (uint256 i; i < sigs.length; i++) {
            (bool ok,) = address(l.hook).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
        }
        bytes4[6] memory notEnabled = [
            IHooks.beforeInitialize.selector,
            IHooks.beforeAddLiquidity.selector,
            IHooks.afterAddLiquidity.selector,
            IHooks.beforeRemoveLiquidity.selector,
            IHooks.afterRemoveLiquidity.selector,
            IHooks.beforeDonate.selector
        ];
        for (uint256 i; i < notEnabled.length; i++) {
            vm.prank(address(manager));
            (bool ok,) = address(l.hook).call(abi.encodeWithSelector(notEnabled[i]));
            assertFalse(ok, "a callback it doesn't enable");
        }
        (bool took,) = address(l.hook).call{value: 1}("");
        assertFalse(took, "no plain ETH");
        assertEq(uint160(address(l.hook)) & Hooks.ALL_HOOK_MASK, IMDUEL_HOOK_FLAGS, "exactly the five permissions");
        assertEq(address(l.hook).balance, 0);
    }

    /// The token has no privileged surface either.
    function test_theTokenHasNoPrivilegedSurface() public {
        Launched memory l = above;
        string[9] memory sigs = [
            "owner()",
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "setTax(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs.length; i++) {
            (bool ok,) = address(l.token).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    // ---------------------------------------------------------------- deployment and opening

    /// Before the hook has code nobody can open its pool: the factory's atomic launch can't be front-run.
    function test_aPoolCannotOpenOnAHookWithoutCode() public {
        address empty = address(uint160(0xABCD) << 40 | IMDUEL_HOOK_FLAGS);
        assertEq(empty.code.length, 0);
        vm.expectRevert();
        manager.initialize(
            PoolKey(imd, Currency.wrap(address(0xffffFF0000000000000000000000000000000000)), 12_500, 60, IHooks(empty)),
            SQRT_PRICE_1_1
        );
    }

    function deployHookAt(uint256 salt, IChessEngine e, Currency imd_, uint256 blocks) internal returns (IMDuelHook) {
        address at = address(uint160(IMDUEL_HOOK_FLAGS) | uint160(salt << 40));
        deployCodeTo("IMDuelHook.sol:IMDuelHook", abi.encode(manager, e, imd_, blocks), at);
        return IMDuelHook(at);
    }

    /// turnBlocks takes 1 and 1,000 and nothing past them; a move's first window really is that long.
    function test_turnBlocksEdges() public {
        IMDuelHook h = deployHookAt(0x77, IChessEngine(ENGINE), imd, 1_000);
        assertEq(h.turnBlocks(), 1_000);
        Currency t = other("T");
        (Currency c0, Currency c1) = t < imd ? (t, imd) : (imd, t);
        (, PoolId pid) = initPool(c0, c1, IHooks(address(h)), 12_500, 60, SQRT_PRICE_1_1);
        assertEq(h.game(pid).closeBlock, vm.getBlockNumber() + 999);
        h = deployHookAt(0x78, IChessEngine(ENGINE), imd, 1);
        (, pid) = initPool(c0, c1, IHooks(address(h)), 12_500, 60, SQRT_PRICE_1_1);
        assertEq(h.game(pid).closeBlock, vm.getBlockNumber(), "one block: the opening block itself");
    }

    /// The first pool must pair IMD with a real token: a refused opening leaves the hook able to take the right one.
    function test_aRefusedOpeningDoesNotBrickTheLaunch() public {
        IMDuelHook h = deployHookAt(0x79, IChessEngine(ENGINE), imd, 3);
        (Currency a, Currency b) = (other("A"), other("B"));
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        PoolKey memory wrong = PoolKey(c0, c1, 12_500, 60, IHooks(address(h)));
        vm.expectRevert(wrapped(address(h), IHooks.afterInitialize.selector, IMDuelHook.BadConfig.selector));
        manager.initialize(wrong, SQRT_PRICE_1_1);
        PoolKey memory eth = PoolKey(CurrencyLibrary.ADDRESS_ZERO, imd, 12_500, 60, IHooks(address(h)));
        // ETH against IMD pairs IMD, but ETH can't be $IMDUEL
        vm.expectRevert(wrapped(address(h), IHooks.afterInitialize.selector, IMDuelHook.BadConfig.selector));
        manager.initialize(eth, SQRT_PRICE_1_1);
        assertTrue(h.imduel().isAddressZero(), "nothing learned");
        assertFalse(h.game(wrong.toId()).live);

        (c0, c1) = a < imd ? (a, imd) : (imd, a);
        PoolKey memory right = PoolKey(c0, c1, 12_500, 60, IHooks(address(h)));
        manager.initialize(right, SQRT_PRICE_1_1);
        assertTrue(h.imduel() == a, "the right opening names $IMDUEL");
        assertEq(PoolId.unwrap(h.mainId()), PoolId.unwrap(right.toId()));
    }

    /// The main duel can't be reopened; later pools route through IMD or $IMDUEL or don't open; neither changes it.
    function test_theMainDuelIsFixedOnceOpened() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            vm.expectRevert();
            manager.initialize(l.key, SQRT_PRICE_1_1);
            (Currency a, Currency b) = (other("A"), other("B"));
            (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
            vm.expectRevert(wrapped(address(l.hook), IHooks.afterInitialize.selector, IMDuelHook.NoRoute.selector));
            manager.initialize(PoolKey(c0, c1, 12_500, 60, IHooks(address(l.hook))), SQRT_PRICE_1_1);
            // the same pair at another fee is a side duel: it burns its slice, but it isn't main and counts nothing
            PoolKey memory twin = PoolKey(l.key.currency0, l.key.currency1, 3_000, 60, IHooks(address(l.hook)));
            manager.initialize(twin, SQRT_PRICE_1_1);
            assertFalse(l.hook.game(twin.toId()).main);
            assertEq(PoolId.unwrap(l.hook.mainId()), PoolId.unwrap(l.id));
            assertEq(Currency.unwrap(l.hook.imduel()), address(l.token));
            assertEq(l.hook.game(twin.toId()).slice, l.duelTeam);
        }
    }

    // ---------------------------------------------------------------- orders the hook refuses

    /// A launch pool holds no IMD until someone buys: a first sale can't fill, and is refused whole.
    function test_aFirstSaleIntoTheLaunchPoolIsRefusedWhole() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            uint256 bal = l.token.balanceOf(address(this));
            vm.expectRevert(wrapped(address(l.hook), IHooks.afterSwap.selector, IMDuelHook.PartialFill.selector));
            swap(l.key, buying(l.imdTeam), -1e18, "");
            assertEq(l.token.balanceOf(address(this)), bal);
            assertEq(claimsOf(l, cur(l, l.duelTeam)), 0, "no fee kept");
        }
    }

    /// Every shape of order its price limit stops is refused whole, with PartialFill, in both token orders.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_aStoppedOrderIsRefusedWhole(bool tokenIs0, bool buysDuel, bool exactOut) public {
        Launched memory l = launched(tokenIs0);
        deepen(l);
        uint256 team = buysDuel ? l.duelTeam : l.imdTeam;
        bool zeroForOne = buying(team);
        (uint160 price,,,) = manager.getSlot0(l.id);
        uint160 limit = zeroForOne ? price - price / 100_000 : price + price / 100_000; // 0.001%
        // each big against a limit that small: in IMDUEL 1e25 either way, in IMD 50 out or 1,000 in
        int256 amount = exactOut
            ? (team == l.duelTeam ? int256(1e25) : int256(50e18))
            : (team == l.duelTeam ? int256(1_000e18) : int256(1e25));
        uint256 held0 = claimsOf(l, l.key.currency0);
        vm.expectRevert(wrapped(address(l.hook), IHooks.afterSwap.selector, IMDuelHook.PartialFill.selector));
        swapRouter.swap(
            l.key,
            SwapParams(zeroForOne, exactOut ? amount : -amount, limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(claimsOf(l, l.key.currency0), held0);
    }

    /// A zero order never reaches the hook; orders too big for a v4 delta revert, whatever their sign, never truncate
    /// a fee; a limit on the wrong side of the price is the manager's refusal. None of them moves anything.
    function test_impossibleOrdersMoveNothing() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            deepen(l);
            bytes32 before = keccak256(abi.encode(st(l), l.hook.chest(l.id, 0), l.hook.chest(l.id, 1)));
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
            swap(l.key, true, 0, "");
            int256[6] memory huge = [
                type(int256).min,
                type(int256).max,
                -int256(1 << 200),
                int256(1 << 200),
                -int256(uint256(type(uint128).max)) * 1_000,
                int256(uint256(type(uint128).max)) * 1_000
            ];
            for (uint256 i; i < huge.length; i++) {
                bytes memory call = abi.encodeCall(
                    PoolSwapTest.swap,
                    (
                        l.key,
                        SwapParams(i % 2 == 0, huge[i], i % 2 == 0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                        PoolSwapTest.TestSettings(false, false),
                        bytes("")
                    )
                );
                (bool ok,) = address(swapRouter).call(call);
                assertFalse(ok, "an order past what a delta holds");
            }
            (uint160 price,,,) = manager.getSlot0(l.id);
            vm.expectRevert();
            swapRouter.swap(l.key, SwapParams(true, -1e18, price + 1), PoolSwapTest.TestSettings(false, false), "");
            assertEq(keccak256(abi.encode(st(l), l.hook.chest(l.id, 0), l.hook.chest(l.id, 1))), before);
        }
    }

    // ---------------------------------------------------------------- who owns a bid

    /// Any hookData: only 20 bytes, or 32 bytes with clean padding, naming somebody who can own a reward, names the
    /// owner; everything else falls to the signer. Oracle from the brief, input from the fuzzer.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_hookDataNamesAnOwnerOnlyInItsTwoShapes(bool tokenIs0, bytes memory data, address signer) public {
        Launched memory l = launched(tokenIs0);
        vm.assume(signer != address(0));
        address named;
        if (data.length == 20) {
            named = address(bytes20(data));
        } else if (data.length == 32) {
            uint256 word = uint256(bytes32(data));
            if (word <= type(uint160).max) named = address(uint160(word));
        }
        bool excluded = named == address(0) || named == address(l.hook) || named == address(manager) || named == DEAD;
        vm.prank(address(this), signer);
        swap(l.key, buying(l.duelTeam), -1e18, data);
        assertEq(st(l).bids[l.duelTeam].owner, excluded ? signer : named);
    }

    /// The shapes pinned: one byte off either way, dirty padding and each excluded address.
    function test_hookDataEdges() public {
        Launched memory l = above;
        address signer = address(0x51);
        bytes[11] memory none = [
            bytes(""),
            hex"01",
            abi.encodePacked(bytes19(uint152(0xA11CE))),
            abi.encodePacked(bytes21(uint168(0xA11CE))),
            abi.encodePacked(bytes31(uint248(0xA11CE))),
            abi.encodePacked(uint256(0xA11CE), hex"00"),
            abi.encodePacked(uint256(1) << 160 | 0xA11CE),
            abi.encodePacked(address(0)),
            abi.encode(address(0)),
            abi.encodePacked(DEAD),
            abi.encode(DEAD)
        ];
        uint256 amount = 1e15;
        for (uint256 i; i < none.length; i++) {
            amount = amount * 12 / 10;
            vm.prank(address(this), signer);
            swap(l.key, buying(l.duelTeam), -int256(amount), none[i]);
            assertEq(st(l).bids[l.duelTeam].owner, signer);
        }
        bytes[4] memory theHook = [
            abi.encodePacked(address(l.hook)),
            abi.encode(address(l.hook)),
            abi.encodePacked(address(manager)),
            abi.encode(address(manager))
        ];
        for (uint256 i; i < theHook.length; i++) {
            amount = amount * 12 / 10;
            vm.prank(address(this), signer);
            swap(l.key, buying(l.duelTeam), -int256(amount), theHook[i]);
            assertEq(st(l).bids[l.duelTeam].owner, signer);
        }
        amount = amount * 12 / 10;
        swap(l.key, buying(l.duelTeam), -int256(amount), abi.encodePacked(ALICE));
        assertEq(st(l).bids[l.duelTeam].owner, ALICE, "20 bytes");
        amount = amount * 12 / 10;
        swap(l.key, buying(l.duelTeam), -int256(amount), abi.encode(BOB));
        assertEq(st(l).bids[l.duelTeam].owner, BOB, "32 clean bytes");
    }

    // ---------------------------------------------------------------- the raise

    /// A new top must pay over 10% more, compared on what each trade paid the pool: at or below 110% nothing changes,
    /// a wei over takes it, whoever asks. Fuzzed around the edge with exact output so the pool's input can be read.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_theRaiseIsExactlyOverTenPercent(bool tokenIs0, uint256 first, uint256 secondPct) public {
        Launched memory l = launched(tokenIs0);
        first = bound(first, 1e12, 100e18);
        secondPct = bound(secondPct, 80, 140);
        buyDuel(l, first, ALICE);
        IMDuelHook.TopBid memory top = st(l).bids[l.duelTeam];
        vm.recordLogs();
        buyDuel(l, first * secondPct / 100, BOB);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 a0, int128 a1) = rawSwap(logs);
        uint256 paid = uint256(uint128(l.imdTeam == 0 ? -a0 : -a1));
        IMDuelHook.TopBid memory after_ = st(l).bids[l.duelTeam];
        if (paid * 100 > uint256(top.size) * 110) {
            assertEq(after_.owner, BOB);
            assertEq(after_.size, paid);
        } else {
            assertEq(after_.owner, ALICE);
            assertEq(after_.size, top.size);
            assertEq(after_.strength, top.strength);
        }
    }

    /// The pool's input a buy of IMDUEL exact-in `a` of IMD reaches: the order less its pot share on the input side.
    function netOf(uint256 a) internal pure returns (uint256) {
        return a - a * 65 / 20_000;
    }

    /// The order whose pool input is exactly `net`.
    function orderFor(uint256 net) internal pure returns (uint256 a) {
        a = net * 20_000 / 19_935;
        while (netOf(a) < net) a++;
        while (netOf(a) > net) a--;
        assertTrue(netOf(a) == net);
    }

    /// Exactly 110% is not "over 10% more", and one wei past it is, in both token orders.
    function test_exactlyTenPercentMoreDoesNotTakeTheTop() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            uint256 a = 1e18;
            while (netOf(a) % 10 != 0) a++;
            buyDuel(l, a, ALICE);
            uint256 size = st(l).bids[l.duelTeam].size;
            assertEq(size, netOf(a));
            buyDuel(l, orderFor(size * 11 / 10), BOB);
            assertEq(st(l).bids[l.duelTeam].owner, ALICE, "exactly 110%: no");
            assertEq(st(l).bids[l.duelTeam].size, size);
            buyDuel(l, orderFor(size * 11 / 10 + 1), BOB);
            assertEq(st(l).bids[l.duelTeam].owner, BOB, "a wei more: yes");
            assertEq(st(l).bids[l.duelTeam].size, size * 11 / 10 + 1);
        }
    }

    // ---------------------------------------------------------------- windows and timeouts, to the block and second

    /// A move takes bids through its window's last block and not one block more.
    function test_theWindowEndsAtItsLastBlock() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            buyDuel(l, 1e18, ALICE); // White's first bid, in the opening block
            uint256 close = st(l).closeBlock;
            assertEq(close, vm.getBlockNumber() + 2, "three blocks: launch.json's turnBlocks");
            vm.roll(close);
            swap(l.key, buying(l.duelTeam), -int256(1e6), abi.encodePacked(BOB)); // too small to take the top spot
            assertEq(
                st(l).bids[l.duelTeam].owner, ALICE, "in its last block the move stands, and isn't replayed for nobody"
            );
            buyDuel(l, 2e18, BOB);
            assertEq(st(l).bids[l.duelTeam].owner, BOB, "the last block still takes bids");
            assertEq(st(l).ply, 0, "not played in its window's last block");
            vm.roll(close + 1);
            vm.recordLogs();
            buyDuel(l, 100e18, ALICE);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(countOf(logs, MOVED), 1, "the first trade past the window plays it");
            assertEq(st(l).ply, 1);
            assertEq(st(l).moveOwner, BOB, "for the bid that stood when it closed");
            assertEq(st(l).bids[l.duelTeam].owner, ALICE, "and the trade bids for its team's next move");
        }
    }

    /// The silent side times out at exactly TURN_TIMEOUT seconds, not a second before, and only by the other team's
    /// trade; a bid by the silent side after that is just a bid.
    function test_theTimeoutIsExactToTheSecond() public {
        Launched memory l = below;
        deepen(l);
        closeWindow(l);
        swap(l.key, buying(l.duelTeam), -int256(1e9), ""); // plays White: IMD's team to move, silent
        IMDuelHook.Game memory g = st(l);
        uint256 silent = moverOf(g);
        assertEq(silent, l.imdTeam);
        assertFalse(g.bids[silent].open);
        uint256 topNext = g.bids[l.duelTeam].size;

        vm.warp(uint256(g.turnStart) + 599);
        vm.roll(vm.getBlockNumber() + 1);
        buyDuel(l, topNext * 2, ALICE);
        g = st(l);
        assertFalse(g.bids[silent].open, "599 seconds: no timeout");

        vm.warp(uint256(g.turnStart) + 600);
        vm.roll(vm.getBlockNumber() + 1);
        buyDuel(l, 1e9, BOB);
        g = st(l);
        assertTrue(g.bids[silent].open, "600 seconds: the silent side's move opens");
        assertEq(g.bids[silent].owner, address(0));
        assertEq(g.bids[silent].size, 0);
        assertEq(g.bids[silent].strength, 0);
        assertEq(g.closeBlock, vm.getBlockNumber(), "its window is this block");

        // the silent team can still take it in this block, a real bid beating the empty one
        swap(l.key, buying(silent), -int256(1e12), abi.encodePacked(BOB));
        assertEq(st(l).bids[silent].owner, BOB, "a real bid takes the timeout's move");
        assertEq(st(l).closeBlock, vm.getBlockNumber(), "without moving its window");
    }

    /// The silent side's own trade never times itself out: its first bid after the deadline opens a full window.
    function test_aLateBidBySilentSideGetsAFullWindow() public {
        Launched memory l = above;
        vm.warp(vm.getBlockTimestamp() + 10_000);
        vm.roll(vm.getBlockNumber() + 500);
        buyDuel(l, 1e15, ALICE); // White's first bid, long after its window
        IMDuelHook.Game memory g = st(l);
        assertEq(g.bids[l.duelTeam].owner, ALICE);
        assertEq(g.closeBlock, vm.getBlockNumber() + 2);
    }

    /// The dice's hash: exactly 256 blocks back the BLOCKHASH serves, past it EIP-2935, past 8,191 nobody: then the bid
    /// keeps its size and strength but plays for nobody and takes this block as its window.
    function test_theDiceHashEdges() public {
        Launched memory l = above;
        buyDuel(l, 1e18, ALICE);
        uint256 close = st(l).closeBlock;
        uint256 snap = vm.snapshotState();
        uint256[3] memory served = [close + 1, close + 256, close + 257];
        for (uint256 i; i < served.length; i++) {
            vm.revertToState(snap);
            snap = vm.snapshotState();
            vm.roll(served[i]);
            swap(l.key, buying(l.duelTeam), -int256(1e12), "");
            assertEq(st(l).ply, 1, "the hash is served: the move plays");
            assertEq(st(l).moveOwner, ALICE);
        }
        vm.revertToState(snap);
        snap = vm.snapshotState();
        vm.roll(close + 8_191);
        swap(l.key, buying(l.duelTeam), -int256(1e12), "");
        assertEq(st(l).ply, 1, "the history contract's last block");

        vm.revertToState(snap);
        IMDuelHook.TopBid memory kept = st(l).bids[l.duelTeam];
        vm.roll(close + 8_192);
        (bool ready,) = l.hook.previewMove(l.id, keccak256("any"));
        assertFalse(ready, "no preview once the hash is gone");
        swap(l.key, buying(l.imdTeam), -int256(1e15), abi.encodePacked(BOB));
        IMDuelHook.TopBid memory b = st(l).bids[l.duelTeam];
        assertEq(st(l).ply, 0, "not played: its dice are gone");
        assertEq(b.owner, address(0), "for nobody");
        assertEq(b.size, kept.size);
        assertEq(b.strength, kept.strength);
        assertEq(st(l).closeBlock, vm.getBlockNumber());
    }

    /// Without EIP-2935 (a chain that doesn't run it) BLOCKHASH alone decides: exactly 256 blocks back is served, 257 isn't.
    function test_withoutHistoryTheLastServedHashIs256BlocksBack() public {
        vm.etch(HISTORY, "");
        Launched memory l = below;
        buyDuel(l, 1e18, ALICE);
        uint256 close = st(l).closeBlock;
        uint256 snap = vm.snapshotState();
        vm.roll(close + 256);
        swap(l.key, buying(l.duelTeam), -int256(1e12), "");
        assertEq(st(l).ply, 1, "256 back: served");
        assertEq(st(l).moveOwner, ALICE);
        vm.revertToState(snap);
        vm.roll(close + 257);
        swap(l.key, buying(l.duelTeam), -int256(1e12), "");
        assertEq(st(l).ply, 0, "257 back: gone");
        assertEq(st(l).bids[l.duelTeam].owner, address(0));
    }

    /// A paid bid whose dice were lost plays for nobody even when its move mates: no reward for the bidder, none recorded
    /// at address zero, no MatePaid, the pot untouched, nobody listed.
    function test_aMateAfterLostDicePaysNobody() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            buyDuel(l, 1_000e18, ALICE);
            uint256 close = st(l).closeBlock;
            vm.roll(close + 8_192);
            buyDuel(l, 1e12, ALICE); // too small to retake it: the bid now plays for nobody
            assertEq(st(l).bids[l.duelTeam].owner, address(0));
            uint256 pot = l.hook.chest(l.id, l.imdTeam);
            script.script(2, true, false);
            nextBlock();
            vm.recordLogs();
            swap(l.key, buying(l.imdTeam), -int256(1e9), ""); // pays IMDUEL: its output is dust, the IMD pot barely moves
            Vm.Log[] memory logs = vm.getRecordedLogs();
            script.script(0, false, false);
            assertEq(countOf(logs, GAME_OVER), 1, "the move mated");
            assertEq(countOf(logs, MATE_PAID), 0, "for nobody");
            assertEq(l.hook.owed(ALICE, imd.toId()), 0);
            assertEq(l.hook.owed(address(0), imd.toId()), 0, "nothing stranded at zero");
            assertGe(l.hook.chest(l.id, l.imdTeam), pot, "the pot keeps it");
            assertEq(l.hook.playerCount(), 0, "nobody listed");
        }
    }

    /// previewMove says nothing for a pool that isn't live, before a window's last block, or with no bid.
    function test_previewRefusals() public {
        Launched memory l = below;
        (bool ready, uint16 m) = l.hook.previewMove(PoolId.wrap(bytes32(uint256(1))), bytes32(uint256(1)));
        assertFalse(ready);
        assertEq(m, 0);
        (ready,) = l.hook.previewMove(l.id, bytes32(uint256(1)));
        assertFalse(ready, "no bid");
        buyDuel(l, 1e18, ALICE);
        (ready,) = l.hook.previewMove(l.id, bytes32(uint256(1)));
        assertFalse(ready, "before the last block");
        vm.roll(st(l).closeBlock);
        (ready,) = l.hook.previewMove(l.id, bytes32(uint256(1)));
        assertTrue(ready, "from the last block the caller's hash decides");
    }

    // ---------------------------------------------------------------- claims

    function owedSome(Launched memory l, address owner) internal returns (uint256 amount) {
        buyDuel(l, 1_000e18, owner);
        script.script(2, true, false);
        closeWindow(l);
        swap(l.key, buying(l.duelTeam), -int256(1e12), "");
        script.script(0, false, false);
        amount = l.hook.owed(owner, imd.toId());
        assertGt(amount, 1);
    }

    /// A claim: only to its owner, whoever calls; all but the 1 wei kept; the second call does nothing; no other
    /// balance moves; the hook's claims fall by exactly what left.
    function test_aClaimPaysOnceAndOnlyItsOwner() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            uint256 amount = owedSome(l, ALICE);
            uint256 held = claimsOf(l, imd);
            uint256 before = MockERC20(IMD).balanceOf(ALICE);
            vm.prank(BOB);
            l.hook.withdraw(ALICE, imd);
            assertEq(MockERC20(IMD).balanceOf(ALICE) - before, amount - 1, "to the owner, all but 1 wei");
            assertEq(MockERC20(IMD).balanceOf(BOB), 0, "nothing to the caller");
            assertEq(l.hook.owed(ALICE, imd.toId()), 1);
            assertEq(held - claimsOf(l, imd), amount - 1);
            vm.recordLogs();
            l.hook.withdraw(ALICE, imd);
            assertEq(vm.getRecordedLogs().length, 0, "1 wei owed: nothing happens, not even an event");
            assertEq(MockERC20(IMD).balanceOf(ALICE) - before, amount - 1, "once");
            vm.prank(ALICE);
            l.hook.withdrawTo(imd, BOB);
            assertEq(MockERC20(IMD).balanceOf(BOB), 0, "the kept wei doesn't leave either");
            address[] memory who = new address[](1);
            who[0] = ALICE;
            assertBooks(l, who);
        }
    }

    /// Nobody can take anybody's reward: withdrawTo spends only the caller's own. It refuses the addresses that would
    /// lose it, and a refused call keeps the reward.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_withdrawToSpendsOnlyTheCallersOwn(address thief, address to) public {
        Launched memory l = above;
        vm.assume(
            thief != ALICE && thief != DEAD && to != address(0) && to != address(l.hook) && to != address(manager)
        );
        uint256 amount = owedSome(l, ALICE);
        uint256 before = MockERC20(IMD).balanceOf(to);
        vm.prank(thief);
        l.hook.withdrawTo(imd, to);
        assertEq(MockERC20(IMD).balanceOf(to), before, "the thief has nothing to send");
        assertEq(l.hook.owed(ALICE, imd.toId()), amount);
        vm.startPrank(ALICE);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        l.hook.withdrawTo(imd, address(0));
        vm.expectRevert(IMDuelHook.BadValue.selector);
        l.hook.withdrawTo(imd, address(l.hook));
        vm.expectRevert(IMDuelHook.BadValue.selector);
        l.hook.withdrawTo(imd, address(manager));
        vm.stopPrank();
        assertEq(l.hook.owed(ALICE, imd.toId()), amount, "refusals keep it");
        vm.prank(ALICE);
        l.hook.withdrawTo(imd, to);
        assertEq(MockERC20(IMD).balanceOf(to) - before, amount - 1);
    }

    /// A claim needs its own unlock: inside anybody's unlock it reverts, and fundChest too; the books stand.
    function test_claimsAndFundingRefuseToRunInsideAnUnlock() public {
        Launched memory l = below;
        uint256 amount = owedSome(l, ALICE);
        InsideUnlock inside = new InsideUnlock(manager);
        inside.run(address(l.hook), abi.encodeCall(IMDuelHook.withdraw, (ALICE, imd)));
        assertFalse(inside.ok());
        assertEq(bytes4(inside.err()), IPoolManager.AlreadyUnlocked.selector);
        assertEq(l.hook.owed(ALICE, imd.toId()), amount);
        inside.run(address(l.hook), abi.encodeCall(IMDuelHook.fundChest, (l.key, false, uint256(0))));
        assertFalse(inside.ok());
        assertEq(bytes4(inside.err()), IPoolManager.AlreadyUnlocked.selector);
    }

    /// A recipient runs code during the hook's unlock only when native ETH reaches it. Trading there is allowed and the
    /// books stay exact: its swap pays its fees, its claim still arrives, and the reward can't be claimed twice from
    /// inside (what is owed is written down before the unlock, so the nested claim finds 1 wei and does nothing).
    function test_aRecipientTradingInsideItsClaimKeepsTheBooks() public {
        Launched memory l = above;
        deepen(l);
        // an ETH duel on the launch's hook, so a reward in native ETH exists
        PoolKey memory ethDuel = PoolKey(CurrencyLibrary.ADDRESS_ZERO, imd, 3_000, 60, IHooks(address(l.hook)));
        PoolId eid = ethDuel.toId();
        manager.initialize(ethDuel, SQRT_PRICE_1_1);
        vm.deal(address(this), 1e24);
        modifyLiquidityRouter.modifyLiquidity{value: 1e23}(ethDuel, ModifyLiquidityParams(-887220, 887220, 1e22, 0), "");

        TradingRecipient r = new TradingRecipient(manager);
        MockERC20(IMD).mint(address(r), 1e24);
        vm.prank(address(l.factory));
        l.token.transfer(address(r), 1e24);
        // ETH's team is White in game 0 (it isn't the base), so a mate there would pay IMD. A drawn game swaps the
        // colours: IMD's team then moves first, and mating ETH's team pays in native ETH.
        script.script(1, false, false);
        swap(ethDuel, true, -int256(1e18), ""); // buys IMD: IMD's team bids for its next move
        swapRouter.swap(ethDuel, SwapParams(false, -1e18, MAX_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        vm.roll(uint256(l.hook.game(eid).closeBlock) + 1);
        swapRouter.swap(ethDuel, SwapParams(false, -1e15, MAX_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        script.script(0, false, false);
        assertEq(l.hook.game(eid).gameNo, 1, "a draw: colours swapped");
        // game 1: IMD's team (1) is White and to move
        uint256 top = l.hook.game(eid).bids[1].open ? l.hook.game(eid).bids[1].size : 0;
        swap(ethDuel, true, -int256(5e18 + top * 2), abi.encodePacked(address(r)));
        assertEq(l.hook.game(eid).bids[1].owner, address(r));
        script.script(2, true, false);
        vm.roll(uint256(l.hook.game(eid).closeBlock) + 1);
        swapRouter.swap(ethDuel, SwapParams(false, -1e15, MAX_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        script.script(0, false, false);
        uint256 reward = l.hook.owed(address(r), 0);
        assertGt(reward, 1, "owed in native ETH");

        // inside its claim: try to claim again, and swap on the main duel
        r.arm(
            l.key,
            buying(l.duelTeam),
            address(l.hook),
            abi.encodeCall(IMDuelHook.withdraw, (address(r), CurrencyLibrary.ADDRESS_ZERO))
        );
        uint256 ethPot = l.hook.chest(eid, 0);
        uint256 duelClaims = claimsOf(l, cur(l, l.duelTeam));
        uint256 potDuel = l.hook.chest(l.id, l.duelTeam);
        l.hook.withdraw(address(r), CurrencyLibrary.ADDRESS_ZERO);
        assertTrue(r.traded(), "it traded inside");
        assertFalse(r.insideCallFailed(), "the nested claim is a no-op: only 1 wei is owed by then");
        assertEq(address(r).balance, reward - 1, "paid once");
        assertEq(l.hook.owed(address(r), 0), 1);
        assertEq(l.hook.chest(eid, 0), ethPot);
        assertGt(claimsOf(l, cur(l, l.duelTeam)), duelClaims, "its trade paid its fee");
        assertGt(l.hook.chest(l.id, l.duelTeam), potDuel);
        assertEq(manager.balanceOf(address(l.hook), 0), l.hook.chest(eid, 0) + 1, "ETH: the pot and the 1 wei");
    }

    /// A recipient that refuses ETH makes only its own claim revert, atomically, and it can send it elsewhere.
    function test_aRefusingRecipientLosesNothing() public {
        Launched memory l = above;
        deepen(l);
        PoolKey memory ethDuel = PoolKey(CurrencyLibrary.ADDRESS_ZERO, imd, 3_000, 60, IHooks(address(l.hook)));
        PoolId eid = ethDuel.toId();
        manager.initialize(ethDuel, SQRT_PRICE_1_1);
        vm.deal(address(this), 1e24);
        modifyLiquidityRouter.modifyLiquidity{value: 1e23}(ethDuel, ModifyLiquidityParams(-887220, 887220, 1e22, 0), "");
        // game 0: ETH's team is White (it isn't the base). Its bid pays IMD; a draw flips the colours so IMD's team mates ETH's
        script.script(1, false, false);
        swapRouter.swap(ethDuel, SwapParams(false, -1e18, MAX_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        vm.roll(uint256(l.hook.game(eid).closeBlock) + 1);
        swap(ethDuel, true, -int256(1e18), "");
        script.script(0, false, false);
        assertEq(l.hook.game(eid).gameNo, 1);
        EthRefuser r = new EthRefuser();
        uint256 top = l.hook.game(eid).bids[1].open ? l.hook.game(eid).bids[1].size : 0;
        swap(ethDuel, true, -int256(3e18 + top * 2), abi.encodePacked(address(r)));
        script.script(2, true, false);
        vm.roll(uint256(l.hook.game(eid).closeBlock) + 1);
        swap(ethDuel, true, -int256(1e15), "");
        script.script(0, false, false);
        uint256 reward = l.hook.owed(address(r), 0);
        assertGt(reward, 1);
        vm.expectRevert();
        l.hook.withdraw(address(r), CurrencyLibrary.ADDRESS_ZERO);
        assertEq(l.hook.owed(address(r), 0), reward, "kept");
        r.withdrawTo(l.hook, CurrencyLibrary.ADDRESS_ZERO, BOB);
        assertEq(BOB.balance, reward - 1);
    }

    // ---------------------------------------------------------------- funding

    function test_fundChestRefusals() public {
        Launched memory l = below;
        Currency a = other("A");
        (Currency c0, Currency c1) = a < imd ? (a, imd) : (imd, a);
        PoolKey memory neverOpened = PoolKey(c0, c1, 3_000, 60, IHooks(address(l.hook)));
        vm.expectRevert(IMDuelHook.NotLive.selector);
        l.hook.fundChest(neverOpened, false, 1);
        PoolKey memory foreignHook = PoolKey(l.key.currency0, l.key.currency1, 12_500, 60, IHooks(address(above.hook)));
        vm.expectRevert(IMDuelHook.NotLive.selector);
        l.hook.fundChest(foreignHook, false, 1);
        vm.expectRevert(IMDuelHook.BadValue.selector);
        l.hook.fundChest{value: 1}(l.key, false, 1); // ETH to a token pot
        vm.prank(ALICE);
        vm.expectRevert(IMDuelHook.BadValue.selector); // Alice approved nothing: the pull fails, wrapped into BadValue
        l.hook.fundChest(l.key, false, 1);
        (uint256 p0, uint256 p1) = (l.hook.chest(l.id, 0), l.hook.chest(l.id, 1));
        assertEq(p0 + p1, 0, "nothing arrived");
    }

    /// A token whose transferFrom says false without moving anything funds nothing: the pot records what arrived.
    function test_aLyingTokenFundsNothing() public {
        Launched memory l = below;
        SyncSwitchToken t = new SyncSwitchToken(manager, imd);
        t.mint(address(this), 1e24);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(l.hook), type(uint256).max);
        Currency tc = Currency.wrap(address(t));
        (Currency c0, Currency c1) = tc < imd ? (tc, imd) : (imd, tc);
        (PoolKey memory k, PoolId pid) = initPool(c0, c1, IHooks(address(l.hook)), 3_000, 60, SQRT_PRICE_1_1);
        t.setMode(2);
        l.hook.fundChest(k, tc == c1, 1e18);
        assertEq(l.hook.chest(pid, tc == c1 ? 1 : 0), 0, "it said false and nothing moved");
        assertEq(manager.balanceOf(address(l.hook), tc.toId()), 0);
    }

    /// A hostile token repoints the manager's synced currency during fundChest and pays in real IMD, so settle() counts
    /// IMD while the hook mints a claim on the hostile token. The hook then holds a credit it can't clear, and the whole
    /// call reverts: the hostile token can't get a claim for free, nor touch the IMD claims.
    function test_aTokenSwitchingTheSyncedCurrencyCannotMintItselfAClaim() public {
        Launched memory l = below;
        SyncSwitchToken t = new SyncSwitchToken(manager, imd);
        t.mint(address(this), 1e24);
        t.approve(address(l.hook), type(uint256).max);
        MockERC20(IMD).mint(address(t), 1e24);
        Currency tc = Currency.wrap(address(t));
        (Currency c0, Currency c1) = tc < imd ? (tc, imd) : (imd, tc);
        (PoolKey memory k, PoolId pid) = initPool(c0, c1, IHooks(address(l.hook)), 3_000, 60, SQRT_PRICE_1_1);
        t.setMode(1);
        uint256 imdClaims = claimsOf(l, imd);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        l.hook.fundChest(k, tc == c1, 1e18);
        assertEq(manager.balanceOf(address(l.hook), tc.toId()), 0, "no claim on it");
        assertEq(claimsOf(l, imd), imdClaims, "IMD claims untouched");
        assertEq(l.hook.chest(pid, tc == c1 ? 1 : 0), 0);
    }

    // ---------------------------------------------------------------- an engine that misbehaves

    /// Each way a call to the engine can come back unusable (a revert, too few bytes, a move past the board) falls to
    /// a legal move at 0% strength for the bid's owner, says so, and the trade goes through. The next move is the
    /// engine's again.
    function test_aMisbehavingEngineFallsBack() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            uint256 snap = vm.snapshotState();
            for (uint256 mode; mode < 3; mode++) {
                vm.revertToState(snap);
                snap = vm.snapshotState();
                script.fail(mode == 0, false, mode == 1, mode == 2);
                buyDuel(l, 1e18, ALICE);
                assertEq(st(l).bids[l.duelTeam].strength, 9_000, "bid at the launch's cap");
                closeWindow(l);
                vm.recordLogs();
                swap(l.key, buying(l.duelTeam), -int256(1e12), "");
                assertEq(countOf(vm.getRecordedLogs(), FAILED), 1, "it says so");
                assertEq(st(l).ply, 1, "a move was still played");
                assertEq(st(l).moveStrength, 0, "at 0%");
                assertEq(st(l).moveOwner, ALICE);
                script.fail(false, false, false, false);
                swap(l.key, buying(l.imdTeam), -int256(1e9), ""); // IMD's team bids for its move
                closeWindow(l);
                vm.recordLogs();
                swap(l.key, buying(l.imdTeam), -int256(1e9), "");
                assertEq(countOf(vm.getRecordedLogs(), FAILED), 0, "no scar");
                assertEq(st(l).ply, 2);
            }
            vm.revertToState(snap);
        }
    }

    /// A mate from the fallback still pays its owner (a mate is a mate); both calls failing is a draw, nobody is paid,
    /// the bid is gone and the next trade bids afresh.
    function test_fallbackMateAndDoubleFailure() public {
        Launched memory l = below;
        buyDuel(l, 1_000e18, ALICE);
        script.fail(true, false, false, false);
        script.script(2, true, false);
        closeWindow(l);
        vm.recordLogs();
        swap(l.key, buying(l.duelTeam), -int256(1e12), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countOf(logs, FAILED), 1);
        (bool seen, address to,, uint256 amount) = matePaid(logs);
        assertTrue(seen, "the fallback's mate pays");
        assertEq(to, ALICE);
        assertEq(l.hook.owed(ALICE, imd.toId()), amount);
        script.fail(false, false, false, false);
        script.script(0, false, false);

        // game 1: both fail
        l = above;
        buyDuel(l, 1_000e18, BOB);
        script.fail(true, true, false, false);
        closeWindow(l);
        vm.recordLogs();
        swap(l.key, buying(l.duelTeam), -int256(1e12), "");
        logs = vm.getRecordedLogs();
        script.fail(false, false, false, false);
        assertEq(countOf(logs, GAME_OVER), 1, "a draw");
        assertEq(countOf(logs, DRAW), 1);
        assertEq(countOf(logs, MATE_PAID), 0);
        assertEq(st(l).gameNo, 1);
        assertEq(st(l).ply, 0);
        assertEq(l.hook.owed(BOB, imd.toId()), 0);
        assertFalse(st(l).bids[l.duelTeam].open && st(l).bids[l.duelTeam].owner == BOB, "the played-out bid is gone");
    }

    /// With no code at the engine's address (a chain it was never deployed on) nothing bricks: each game ends a draw at
    /// its first move, pays nothing, and the pool trades on.
    function test_anAddressWithoutCodeDrawsEveryGame() public {
        Launched memory l = above;
        vm.etch(ENGINE, "");
        for (uint256 i; i < 3; i++) {
            uint256 mover = moverOf(st(l));
            uint256 top = st(l).bids[mover].open ? uint256(st(l).bids[mover].size) * 2 : 0;
            buyDuelOr(l, mover, (mover == l.duelTeam ? 1e18 : 1e22) + top);
            closeWindow(l);
            uint256 gameNo = st(l).gameNo;
            swap(l.key, buying(l.duelTeam), -int256(1e12), "");
            assertEq(st(l).gameNo, gameNo + 1, "a draw");
        }
        assertEq(l.hook.owed(ALICE, imd.toId()), 0);
        assertEq(l.hook.owed(ALICE, l.key.currency1.toId()), 0);
    }

    function buyDuelOr(Launched memory l, uint256 team, uint256 amount) internal {
        buy(l, team, amount, abi.encodePacked(ALICE));
    }

    // ---------------------------------------------------------------- stats: for display only

    /// Whatever a player's counts are, the game treats them the same: a veteran and a newcomer get the same bid, the
    /// same strength and the same prize from the same state. The engine ignores nothing here but the seed (it picks by
    /// seed, which holds the owner), so only money and strength are compared, and only that those don't read the counts.
    function test_statsNeverPayOrLimit() public {
        for (uint256 o; o < 2; o++) {
            Launched memory l = o == 0 ? below : above;
            // the veteran earns a record: three mates in the main duel, over several colours
            address veteran = address(0xBE7E);
            address newcomer = address(0x0DD);
            for (uint256 i; i < 3; i++) {
                uint256 m = moverOf(st(l));
                uint256 top = st(l).bids[m].open ? uint256(st(l).bids[m].size) * 2 : 0;
                addFullRange(l, 1e22);
                buy(l, m, (m == l.duelTeam ? 1e18 : 1e22) + top, abi.encodePacked(veteran));
                script.script(2, true, false);
                closeWindow(l);
                swap(l.key, buying(1 - m), -int256(1e9), "");
                script.script(0, false, false);
            }
            (uint256 vm0, uint256 vr0) = l.hook.stats(veteran);
            assertGt(vm0, 0);
            assertEq(vr0 & 0xffff, 3, "three mates counted");
            (uint256 nm0, uint256 nr0) = l.hook.stats(newcomer);
            assertEq(nm0 | nr0, 0);

            uint256 m2 = moverOf(st(l));
            uint256 top2 = st(l).bids[m2].open ? uint256(st(l).bids[m2].size) * 2 : 0;
            uint256 amount = (m2 == l.duelTeam ? 5e18 : 5e22) + top2;
            uint256 snap = vm.snapshotState();
            uint256[2] memory strength;
            uint256[2] memory won;
            for (uint256 who; who < 2; who++) {
                vm.revertToState(snap);
                snap = vm.snapshotState();
                address owner = who == 0 ? veteran : newcomer;
                buy(l, m2, amount, abi.encodePacked(owner));
                strength[who] = st(l).bids[m2].strength;
                Currency c = cur(l, 1 - m2);
                uint256 before = l.hook.owed(owner, c.toId());
                script.script(2, true, false);
                closeWindow(l);
                swap(l.key, buying(1 - m2), -int256(1e9), "");
                script.script(0, false, false);
                won[who] = l.hook.owed(owner, c.toId()) - before;
            }
            assertEq(strength[0], strength[1], "the same strength");
            assertEq(won[0], won[1], "the same prize");
            assertGt(won[0], 0);
        }
    }

    /// A side duel counts nothing for anyone and a player name never enters the list for it; the main duel lists once.
    function test_onlyTheMainDuelCounts() public {
        Launched memory l = above;
        Currency x = other("X");
        (Currency c0, Currency c1) = x < imd ? (x, imd) : (imd, x);
        (PoolKey memory side, PoolId sid) = initPool(c0, c1, IHooks(address(l.hook)), 3_000, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(side, ModifyLiquidityParams(-887220, 887220, 1e23, 0), "");
        uint256 xTeam = x == c0 ? 0 : 1;
        swap(side, buying(xTeam), -int256(1e18), abi.encodePacked(ALICE)); // X's team is White here
        vm.roll(uint256(l.hook.game(sid).closeBlock) + 1);
        swap(side, buying(xTeam), -int256(1e12), "");
        assertEq(l.hook.game(sid).ply, 1);
        assertEq(l.hook.game(sid).moveOwner, ALICE);
        (uint256 a, uint256 b) = l.hook.stats(ALICE);
        assertEq(a | b, 0, "a side duel counts nothing");
        assertEq(l.hook.playerCount(), 0);

        buyDuel(l, 1e18, ALICE);
        closeWindow(l);
        swap(l.key, buying(l.imdTeam), -int256(1e9), "");
        (a, b) = l.hook.stats(ALICE);
        assertGt(a, 0);
        assertEq(l.hook.playerCount(), 1);
        assertEq(l.hook.players(0), ALICE);
        buyDuel(l, 1e18, ALICE); // White's next
        swap(l.key, buying(l.imdTeam), -int256(1e12), "");
        closeWindow(l);
        swap(l.key, buying(l.imdTeam), -int256(1e12), ""); // plays Black's, by the signer
        closeWindow(l);
        swap(l.key, buying(l.imdTeam), -int256(1e12), ""); // plays White's next, by Alice again
        uint256 listed;
        for (uint256 i; i < l.hook.playerCount(); i++) {
            if (l.hook.players(i) == ALICE) listed++;
        }
        assertEq(listed, 1, "listed once");
    }
}
