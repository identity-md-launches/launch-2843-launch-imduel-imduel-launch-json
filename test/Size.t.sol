// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IMDuelHook, IMDUEL_HOOK_FLAGS} from "../src/IMDuelHook.sol";
import {IChessEngine} from "../src/IChessEngine.sol";

/// Ethereum rejects contracts over 24,576 bytes (EIP-170); the budgets keep a margin. Other tests
/// place code directly and would not notice.
contract SizeTest is Test {
    uint256 constant LIMIT = 24_576;
    uint256 constant HOOK_BUDGET = 23_500;
    uint256 constant ENGINE_BUDGET = 24_000;

    function test_deployedCodeFitsTheBudgets() public {
        address v5 = vm.deployCode("ChessEngineV5.sol:ChessEngineV5"); // 200 runs (foundry.toml)
        address at = address(IMDUEL_HOOK_FLAGS | (uint160(0x512E) << 40));
        deployCodeTo("IMDuelHook.sol:IMDuelHook", abi.encode(IPoolManager(address(1)), IChessEngine(v5),
            Currency.wrap(address(2)), uint256(3)), at);
        emit log_named_uint("hook", at.code.length);
        emit log_named_uint("engine v5", v5.code.length);
        assertLe(at.code.length, HOOK_BUDGET, "hook");
        assertLe(v5.code.length, ENGINE_BUDGET, "engine v5");
    }
}
