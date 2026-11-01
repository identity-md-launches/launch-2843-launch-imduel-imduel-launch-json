// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";

/// The EIP-2935 history contract as far as the hook asks it: the hash of one block (else nothing).
contract HistoryStub {
    uint256 immutable n;
    bytes32 immutable h;

    constructor(uint256 n_, bytes32 h_) {
        (n, h) = (n_, h_);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        return abi.decode(data, (uint256)) == n ? abi.encode(h) : bytes("");
    }
}

/// Move windows at the launch value, 3 blocks (audit round 4's surviving mutants: every other suite used 1-block
/// windows): where an expired move's window goes, the half-move a resolving trade's Bid names, a hash past
/// BLOCKHASH's 256 read from history, and no preview before the closing block.
contract WindowsTest is Base {
    function turnBlocks() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function hashOf(uint256 n) external view returns (bytes32) {
        return blockhash(n);
    }

    /// The trade that finds an expired hash makes its own block the window, not a fresh 3-block one.
    function test_anExpiredMovesWindowIsTheFindingBlock() public {
        white(1e18, address(0xA));
        vm.roll(vm.getBlockNumber() + 300);
        vm.warp(vm.getBlockTimestamp() + 3_600);
        black(1e17, address(0xB));
        assertEq(bid().owner, address(0), "for nobody");
        assertEq(st().closeBlock, vm.getBlockNumber(), "this block is the window");
    }

    /// The trade that plays a move and then bids names the half-move it bids for in its Bid event.
    function test_theResolvingTradesBidNamesItsHalfMove() public {
        white(1e18, address(0xA));
        vm.roll(st().closeBlock + 1);
        vm.recordLogs();
        black(1e18, address(0xB)); // plays White's half-move 0, then bids for Black's, now current: 1
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != BID) continue;
            (, uint16 ply,,,) = abi.decode(logs[i].data, (uint32, uint16, address, uint256, uint16));
            assertEq(ply, 1, "Black's current half-move");
            seen++;
        }
        assertEq(seen, 1);
        assertEq(st().ply, 1);
    }

    /// 257 blocks after the window's last block BLOCKHASH serves nothing; the history contract does, and the move
    /// plays for its owner.
    function test_aHash257BlocksBackComesFromHistory() public {
        white(1e18, address(0xA));
        uint256 close = st().closeBlock;
        vm.roll(close + 1);
        bytes32 h = this.hashOf(close);
        assertTrue(h != 0);
        vm.etch(0x0000F90827F1C53a10cb7A02335B175320002935, address(new HistoryStub(close, h)).code);
        vm.roll(close + 257);
        vm.warp(vm.getBlockTimestamp() + 3_600);
        black(1e17, address(0xB));
        assertEq(st().ply, 1, "played");
        assertEq(st().moveOwner, address(0xA), "with the window's hash, for its owner");
    }

    /// One block before a window closes nothing is previewed; in the closing block it is.
    function test_noPreviewBeforeTheClosingBlock() public {
        white(1e18, address(0xA));
        uint256 close = st().closeBlock;
        vm.roll(close - 1);
        (bool ready,) = hook.previewMove(id, bytes32(uint256(1)));
        assertFalse(ready);
        vm.roll(close);
        (ready,) = hook.previewMove(id, bytes32(uint256(1)));
        assertTrue(ready);
    }
}
