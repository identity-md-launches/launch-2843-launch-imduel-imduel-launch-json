// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// How the IMD launch factory opens a hook launch (Ethereum policy v34): a 1B-supply
/// token, its pool with IMD at fee 12500 and spacing 60, opening at 2,500 IMD for the whole supply, 80% of the supply
/// seeded single-sided in the token (the launch's poolBps; 10% is the swarm's, 10% team supply: 5% the team, 5% reserved for the Robinhood Chain duel launch, 2026-10-29). And the hook's constructor arguments as a launch file (launch/hook.json) gives
/// them. Shared by the launch tests and the mainnet-fork rehearsal (script/RehearseMainnet.s.sol).
library LaunchPolicy {
    uint256 internal constant SUPPLY = 1e27;
    uint24 internal constant FEE = 12_500;
    int24 internal constant SPACING = 60;
    int24 internal constant OPEN_TICK = 128_940; // |log1.0001(2,500 IMD / 1e9 tokens)|, on the 60 spacing
    int24 internal constant EDGE = 887_220;
    uint256 internal constant SEED_BPS = 8_000;

    /// The opening price and the single-sided seed for a token sorting below IMD (`tokenIs0`, price = IMD per token)
    /// or above it: the token alone, on the side of the price it is sold along.
    function opening(bool tokenIs0) internal pure returns (uint160 price, int24 lower, int24 upper, uint256 liquidity) {
        int24 open = tokenIs0 ? -OPEN_TICK : OPEN_TICK;
        price = TickMath.getSqrtPriceAtTick(open);
        (lower, upper) = tokenIs0 ? (open, EDGE) : (-EDGE, open);
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 amount = SUPPLY * SEED_BPS / 10_000;
        liquidity = tokenIs0
            ? FullMath.mulDiv(FullMath.mulDiv(amount, a, 1 << 96), b, b - a)
            : FullMath.mulDiv(amount, 1 << 96, b - a);
        liquidity = liquidity * 999 / 1000; // rounding room
    }

    /// The hook's ABI-encoded constructor arguments from a launch file, with `$poolManager` and `ENGINE_ADDRESS` filled
    /// in as the launch fills them.
    function hookArgs(Vm vm, string memory json, address manager, address engine) internal pure returns (bytes memory) {
        string[] memory a = vm.parseJsonStringArray(json, ".hook.constructorArgs");
        require(a.length == 4, "a launch file gives the hook 4 constructor arguments");
        require(keccak256(bytes(a[0])) == keccak256("$poolManager") && keccak256(bytes(a[1])) == keccak256("ENGINE_ADDRESS"));
        return abi.encode(manager, engine, vm.parseAddress(a[2]), vm.parseUint(a[3]));
    }
}
