// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {Base} from "./Base.sol";
import {LaunchPolicy} from "../script/LaunchPolicy.sol";

/// The launch files (launch/*.json) the IMD swarm deploys from: the real hook deploys with exactly their constructor
/// arguments at an address carrying their permission bits, and every argument lands where it is meant to. A change to
/// the constructor that the files don't follow fails here, not in a paid launch.
contract LaunchFilesTest is Base {
    function setUp() public {
        deployV4();
    }

    /// Deploys IMDuelHook from a launch file's constructor arguments ($poolManager and ENGINE_ADDRESS filled in as the
    /// launch fills them) and checks it against the file's pool block.
    function check(string memory file) internal {
        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonStringArray(json, ".hook.constructorArgs").length, 4, "constructor arguments");
        // the published worker refuses a manifest whose notes pass 4,000 characters (worker v0.1.9); the export fills
        // the engine's address (42 characters) in for ENGINE_ADDRESS (14)
        assertLe(bytes(vm.parseJsonString(json, ".notes")).length + 28, 4_000, "the worker's limit on the notes");
        IChessEngine engine = v5();
        bytes memory args = LaunchPolicy.hookArgs(vm, json, address(manager), address(engine));

        // the permissions the file names are the hook's: the launch mines the address from them
        string[] memory names = vm.parseJsonStringArray(json, ".hook.permissions");
        uint160 flags;
        for (uint256 i; i < names.length; i++) flags |= flag(names[i]);
        assertEq(flags, IMDUEL_HOOK_FLAGS, "permissions");
        address at = address(flags | (uint160(0x1A0C4 + hooksDeployed++) << 40));
        deployCodeTo("IMDuelHook.sol:IMDuelHook", args, at);
        IMDuelHook h = IMDuelHook(at);
        Hooks.Permissions memory p = h.getHookPermissions();
        uint160 told = (p.afterInitialize ? Hooks.AFTER_INITIALIZE_FLAG : 0) | (p.beforeSwap ? Hooks.BEFORE_SWAP_FLAG : 0)
            | (p.afterSwap ? Hooks.AFTER_SWAP_FLAG : 0) | (p.beforeSwapReturnDelta ? Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG : 0)
            | (p.afterSwapReturnDelta ? Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG : 0);
        bool others = p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
            || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
            || p.afterRemoveLiquidityReturnDelta;
        assertTrue(told == flags && !others, "getHookPermissions() names the file's permissions, nothing else");

        assertEq(address(h.manager()), address(manager));
        assertEq(address(h.engine()), address(engine));
        assertEq(Currency.unwrap(h.imd()), vm.parseJsonAddress(json, ".pool.pairedCurrency"), "imd is the pool's pair");
        assertEq(h.turnBlocks(), 3, "a move takes bids for 3 blocks (about 36 s)");
        assertEq(vm.parseJsonUint(json, ".pool.fee"), LaunchPolicy.FEE, "the launch policy's pool fee");
        assertEq(vm.parseJsonInt(json, ".pool.tickSpacing"), LaunchPolicy.SPACING, "the launch policy's tick spacing");
    }

    function flag(string memory name) internal pure returns (uint160) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("afterInitialize")) return Hooks.AFTER_INITIALIZE_FLAG;
        if (n == keccak256("beforeSwap")) return Hooks.BEFORE_SWAP_FLAG;
        if (n == keccak256("afterSwap")) return Hooks.AFTER_SWAP_FLAG;
        if (n == keccak256("beforeSwapReturnDelta")) return Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (n == keccak256("afterSwapReturnDelta")) return Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        revert(string.concat("unknown permission ", name));
    }

    function test_ethereumLaunchFile() public {
        check("./launch/hook.json");
    }

    function test_sepoliaLaunchFile() public {
        check("./launch/hook.sepolia.json");
    }

    function test_engineLaunchFileDeploysTheEngineWithoutArguments() public {
        string memory json = vm.readFile("./launch/engine.json");
        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "ChessEngineV5");
        assertEq(vm.parseJsonStringArray(json, ".contracts[0].constructorArgs").length, 0);
    }
}
