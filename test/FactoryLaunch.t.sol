// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {IMDuelToken} from "../src/IMDuelToken.sol";
import {LaunchPolicy} from "../script/LaunchPolicy.sol";
import {V4Fixture} from "./V4Fixture.sol";

/// Test-only factory: CREATE2, initialization, single-sided seeding and fee collection in its own position.
contract AtomicLaunchProbe is IUnlockCallback {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant ENGINE = 0xc21788F704a8b9456f7391A01d8a3D95Be215a27;
    IPoolManager public immutable manager;
    address public immutable controller;
    IMDuelToken public token;
    IMDuelHook public hook;
    PoolKey public key;
    int24 internal lower;
    int24 internal upper;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function predicted(bytes32 codeHash, uint256 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }

    function deploy(bytes memory code, uint256 salt) internal returns (address at) {
        assembly ("memory-safe") {
            at := create2(0, add(code, 32), mload(code), salt)
        }
        require(at != address(0), "constructor failed");
    }

    function launch(bytes memory tokenCode, bytes memory hookCode, bool tokenIs0) external {
        require(msg.sender == controller && address(token) == address(0));
        bytes32 codeHash = keccak256(tokenCode);
        uint256 salt;
        while ((predicted(codeHash, salt) < IMD) != tokenIs0) salt++;
        token = IMDuelToken(deploy(tokenCode, salt));
        require(token.totalSupply() == 1e27 && token.balanceOf(address(this)) == 1e27, "policy supply");

        // Exactly launch.json's four arguments; the engine need not have code during construction.
        bytes memory initCode = abi.encodePacked(hookCode, abi.encode(manager, ENGINE, IMD, uint256(3)));
        codeHash = keccak256(initCode);
        salt = 0;
        while (uint160(predicted(codeHash, salt)) & Hooks.ALL_HOOK_MASK != IMDUEL_HOOK_FLAGS) salt++;
        hook = IMDuelHook(deploy(initCode, salt));

        Currency imd = Currency.wrap(IMD);
        Currency duel = Currency.wrap(address(token));
        (Currency c0, Currency c1) = tokenIs0 ? (duel, imd) : (imd, duel);
        key = PoolKey(c0, c1, 12_500, 60, IHooks(address(hook)));
        uint160 price;
        uint256 liquidity;
        (price, lower, upper, liquidity) = LaunchPolicy.opening(tokenIs0);
        manager.initialize(key, price);
        manager.unlock(abi.encode(int256(liquidity)));
    }

    function collect() external returns (BalanceDelta) {
        require(msg.sender == controller);
        return abi.decode(manager.unlock(abi.encode(int256(0))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, abi.decode(data, (int256)), bytes32(0)), ""
        );
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), uint128(-delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}

contract FactoryLaunchTest is V4Fixture {
    using PoolIdLibrary for PoolKey;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant ENGINE = 0xc21788F704a8b9456f7391A01d8a3D95Be215a27;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant HOOK_SWAP = keccak256("HookSwap(bytes32,address,int128,int128,uint24)");

    function setUp() public {
        vm.chainId(1);
        deployV4();
        vm.etch(IMD, address(mockToken("IMD", "IMD")).code);
    }

    function run(bool tokenIs0) internal {
        AtomicLaunchProbe factory = new AtomicLaunchProbe(manager);
        assertEq(ENGINE.code.length, 0);
        factory.launch(vm.getCode("IMDuelToken.sol:IMDuelToken"), vm.getCode("IMDuelHook.sol:IMDuelHook"), tokenIs0);
        IMDuelToken token = factory.token();
        IMDuelHook hook = factory.hook();
        Currency duel = Currency.wrap(address(token));
        Currency imd = Currency.wrap(IMD);
        PoolKey memory key = tokenIs0
            ? PoolKey(duel, imd, 12_500, 60, IHooks(address(hook)))
            : PoolKey(imd, duel, 12_500, 60, IHooks(address(hook)));
        assertEq(address(token) < IMD, tokenIs0);
        assertEq(token.name(), "IMDuel");
        assertEq(token.symbol(), "IMDUEL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(address(hook.manager()), address(manager));
        assertEq(address(hook.engine()), ENGINE);
        assertEq(Currency.unwrap(hook.imd()), IMD);
        assertEq(hook.turnBlocks(), 3);
        assertEq(Currency.unwrap(hook.imduel()), address(token));
        assertTrue(hook.game(key.toId()).main);
        assertEq(manager.balanceOf(address(hook), duel.toId()), 0, "no supply reserved for the hook");
        assertEq(MockERC20(IMD).balanceOf(address(manager)), 0, "tokens only at opening");
        assertEq(address(manager).balance, 0, "no ETH needed for swap fees");
        assertLe(address(hook).code.length, 24_576);
        Hooks.Permissions memory expected;
        (
            expected.afterInitialize,
            expected.beforeSwap,
            expected.afterSwap,
            expected.beforeSwapReturnDelta,
            expected.afterSwapReturnDelta
        ) = (true, true, true, true, true);
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));

        // The launch uses the already deployed engine; only this local empty-chain rehearsal installs its build.
        address localEngine = vm.deployCode("ChessEngineV5.sol:ChessEngineV5");
        vm.etch(ENGINE, localEngine.code);
        MockERC20(IMD).mint(address(this), 1_000e18);
        MockERC20(IMD).approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        vm.recordLogs();
        swap(key, !tokenIs0, -50e18, abi.encode(address(this))); // exact input buy
        assertHookSwap(vm.getRecordedLogs(), address(hook));
        assertGt(token.balanceOf(address(this)), 0);
        assertEq(hook.game(key.toId()).bids[tokenIs0 ? 0 : 1].owner, address(this));

        uint256 close = hook.game(key.toId()).closeBlock;
        vm.roll(close + 1);
        vm.setBlockhash(close, keccak256("factory launch window"));
        vm.recordLogs();
        swap(key, tokenIs0, -1_000_000e18, abi.encode(address(this))); // exact input sell plays the move
        assertHookSwap(vm.getRecordedLogs(), address(hook));
        assertEq(hook.game(key.toId()).ply, 1);
        vm.recordLogs();
        swap(key, !tokenIs0, 1_000e18, abi.encode(address(this))); // exact output buy
        assertHookSwap(vm.getRecordedLogs(), address(hook));
        vm.recordLogs();
        swap(key, tokenIs0, 1e18, abi.encode(address(this))); // exact output sell
        assertHookSwap(vm.getRecordedLogs(), address(hook));

        uint256 burn = hook.owed(DEAD, duel.toId());
        assertGt(burn, 1);
        hook.withdraw(DEAD, duel);
        assertEq(token.balanceOf(DEAD), burn - 1);
        assertEq(token.totalSupply(), 1e27, "burn destination leaves the fixed ERC-20 supply unchanged");
        for (uint256 i; i < 2; i++) {
            Currency c = i == 0 ? key.currency0 : key.currency1;
            assertEq(manager.balanceOf(address(hook), c.toId()), hook.chest(key.toId(), i) + hook.owed(DEAD, c.toId()));
        }

        uint256 imdBefore = MockERC20(IMD).balanceOf(address(factory));
        uint256 duelBefore = token.balanceOf(address(factory));
        BalanceDelta fees = factory.collect();
        assertGe(fees.amount0(), 0);
        assertGe(fees.amount1(), 0);
        assertGt(MockERC20(IMD).balanceOf(address(factory)), imdBefore, "factory collects IMD LP fees");
        assertGt(token.balanceOf(address(factory)), duelBefore, "factory collects IMDUEL LP fees");
    }

    function assertHookSwap(Vm.Log[] memory logs, address hook) internal pure {
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == hook && logs[i].topics[0] == HOOK_SWAP) {
                (int128 a0, int128 a1, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint24));
                assertLt(a0, 0);
                assertLt(a1, 0);
                assertEq(fee, 7_500);
                count++;
            }
        }
        assertEq(count, 1, "one URC-2 fee event per swap");
    }

    function test_factoryLaunchWithTokenBelowImd() public {
        run(true);
    }

    function test_factoryLaunchWithTokenAboveImd() public {
        run(false);
    }
}
