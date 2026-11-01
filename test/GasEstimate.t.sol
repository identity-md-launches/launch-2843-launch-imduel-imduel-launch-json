// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";
import {HookConfig} from "./Harness.sol";

/// Wallets send a trade with the smallest gas limit that succeeds (eth_estimateGas). At that limit the trade must
/// still do all its work: play the queued turn and record its mate's payout, neither silently skipped for lack of gas.
contract GasEstimateTest is Base {

    /// The smallest gas limit at which `data` sent to the router succeeds (binary search from the same state), then
    /// sends it with that limit for real and returns its logs.
    function atMinimalGas(bytes memory data) internal returns (uint256 lo, Vm.Log[] memory logs) {
        uint256 hi = 4_000_000;
        lo = 50_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(swapRouter).call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
        vm.recordLogs();
        (bool sent,) = address(swapRouter).call{gas: lo}(data);
        assertTrue(sent, "succeeds at the estimate");
        logs = vm.getRecordedLogs();
    }

    function swapCall(uint256 team, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(PoolSwapTest.swap, (pool, SwapParams(team == 1, -int256(amount),
            team == 1 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), bytes("")));
    }

    /// White's only legal move mates (forcedMate), owned by 0xA11CE and queued; returns the trade that plays it and
    /// the currency the mate is paid in: the loser's, Black's team's token.
    function mateQueuedForAlice() internal returns (bytes memory play, Currency paidIn) {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
        forcedMate(false);
        white(1e18, address(0xA11CE)); // owns White's turn
        next(12);
        return (swapCall(1 - whiteTeam(), 1e17), whiteTeam() == 0 ? currency1 : currency0);
    }

    /// The one MatePaid in `logs`: its amount, from the event itself.
    function paidAmount(Vm.Log[] memory logs) internal pure returns (uint256 amount) {
        for (uint256 i; i < logs.length; i++) if (logs[i].topics[0] == MATE_PAID) (,,, amount) = abi.decode(logs[i].data, (uint32, address, address, uint256));
    }

    function test_atTheEstimateThePayoutIsRecorded() public {
        (bytes memory play, Currency paidIn) = mateQueuedForAlice();
        (uint256 g, Vm.Log[] memory logs) = atMinimalGas(play); // plays it
        emit log_named_uint("smallest gas limit that plays and records the mate's payout", g);
        assertEq(count(logs, MOVED), 1);
        assertEq(count(logs, MATE_PAID), 1);
        assertEq(hook.owed(address(0xA11CE), paidIn.toId()), paidAmount(logs), "recorded for the owner");
        // the bid's size is what the pool received, net of the hook fee taken on that side
        assertApproxEqAbs(paidAmount(logs), 2e18, 2e16, "a quarter of the loser's pot, capped at twice the 1-token bid");
    }

    /// Whoever plays a move picks the gas limit, so no limit may let the trade go through without its payout
    /// recorded. Every limit from far below to above the estimate, 1,000 gas apart (the estimate is measured first:
    /// --isolate adds about 100,000 to it).
    function test_noGasLimitPlaysTheMoveWithoutItsPayout() public {
        (bytes memory play, Currency paidIn) = mateQueuedForAlice();
        uint256 before = vm.snapshotState();
        (uint256 estimate,) = atMinimalGas(play);
        vm.revertToState(before);
        uint256 succeeded;
        for (uint256 gas = 50_000; gas <= estimate + 20_000; gas += 1_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = address(swapRouter).call{gas: gas}(play);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (ok) {
                succeeded++;
                assertEq(count(logs, MOVED), 1, "a trade that goes through plays the move");
                assertEq(count(logs, MATE_PAID), 1, "and records its payout");
                assertEq(hook.owed(address(0xA11CE), paidIn.toId()), paidAmount(logs), "recorded for the owner");
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0, "the range reaches the estimate");
    }
}
