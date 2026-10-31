// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";

/// The bidding rules at the launch value (moves open for 3 blocks): every buy bids for its team's next move, the
/// biggest owns it and a new top must pay more than 10% over the old, a move's window runs from the block the
/// previous move was played through `turnBlocks` blocks, and the first trade after it plays the move with the hash of
/// the window's last block. Swaps without next() between them share a block.
contract BiddingTest is Base {
    using CurrencyLibrary for Currency;

    function turnBlocks() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public {
        setUpMainDuel();
    }

    /// Next block, 12 seconds later, `n` times.
    function blocks(uint256 n) internal {
        for (uint256 i; i < n; i++) next(12);
    }

    // ---------------------------------------------------------------- every buy bids

    function test_aBuyOfTheOtherTeamBidsForItsNextMove() public {
        vm.recordLogs();
        black(2e18, address(0xB)); // White is to move: Black's buy bids for Black's next move
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(count(logs, BID), 1);
        assertFalse(bid().open, "White's move has no bid");
        assertEq(st().bids[1 - whiteTeam()].owner, address(0xB));
        white(1e18, address(0xA));
        blocks(3);
        white(1e18, address(0xC)); // plays White's move: Black's earlier bid is now the top for Black's move
        assertEq(st().ply, 1);
        assertEq(bid().owner, address(0xB));
        blocks(3);
        black(1e17, address(0xD)); // plays Black's move, owned by the early bid
        assertEq(st().moveOwner, address(0xB));
    }

    function test_theMoversOwnBuyAfterItsWindowBidsForItsNextMove() public {
        white(1e18, address(0xA));
        blocks(3);
        white(5e18, address(0xC)); // plays A's move, then bids for White's move after Black's
        assertEq(st().moveOwner, address(0xA));
        assertEq(st().bids[whiteTeam()].owner, address(0xC));
        assertFalse(bid().open, "Black's move has no bid yet");
    }

    // ---------------------------------------------------------------- the biggest, by more than 10%

    function test_aNewTopMustPayMoreThanTenPercentMore() public {
        white(10e18, address(0xA));
        white(10.9e18, address(0xB)); // 9% more: just trades
        assertEq(bid().owner, address(0xA));
        white(11.2e18, address(0xC)); // 12% more
        assertEq(bid().owner, address(0xC));
    }

    function test_bidsCountAcrossTheWholeWindow() public {
        white(1e18, address(0xA)); // the window's first block (the game opened in this one)
        next(12);
        white(2e18, address(0xB));
        next(12);
        white(4e18, address(0xC)); // the window's last block
        assertEq(st().closeBlock, vm.getBlockNumber());
        next(12);
        vm.recordLogs();
        white(9e18, address(0xD)); // too late: plays C's move, then bids for White's next
        assertEq(count(vm.getRecordedLogs(), MOVED), 1);
        assertEq(st().moveOwner, address(0xC));
    }

    function test_aClosedWindowTakesNoBidsForItsMove() public {
        white(1e18, address(0xA));
        uint256 last = st().closeBlock;
        vm.roll(last + 1);
        black(1e17, address(0xB)); // plays A's move
        assertEq(st().moveOwner, address(0xA));
        assertEq(st().ply, 1);
    }

    // ---------------------------------------------------------------- windows

    function test_aMoveIsOpenForTurnBlocksBlocks() public {
        uint256 opened = vm.getBlockNumber();
        assertEq(st().closeBlock, opened + 2, "this block and two more");
        white(1e18, address(0xA));
        blocks(3);
        black(1e18, address(0xB)); // plays White's move in this block: Black's window starts here
        assertEq(st().closeBlock, vm.getBlockNumber() + 2);
    }

    function test_aWindowWithoutBidsBecomesTheFirstBidsBlock() public {
        blocks(5); // White's window passes without a bid
        white(1e18, address(0xA));
        assertEq(st().closeBlock, vm.getBlockNumber(), "this block is the window now");
        white(3e18, address(0xB)); // a bigger buy in the same block takes it
        next(12);
        black(1e17, address(0));
        assertEq(st().moveOwner, address(0xB));
    }

    // ---------------------------------------------------------------- the dice

    /// The dice are the hash of the window's last block: whoever plays the move, and whenever, it is the same move.
    function test_theMoveDependsOnlyOnTheWindowsLastBlock() public {
        white(1e18, address(0xA));
        uint256 last = st().closeBlock;
        uint256 snap = vm.snapshotState();
        vm.roll(last + 1);
        black(1e18, address(0xB));
        uint256 soon = st().board;
        vm.revertToState(snap);
        vm.roll(last + 150);
        vm.warp(vm.getBlockTimestamp() + 1_800);
        white(5e18, address(0xC));
        assertEq(st().board, soon, "same move");
        assertEq(st().moveOwner, address(0xA));
    }

    /// What the site shows as soon as a window's last block is in is the move the next trade plays.
    function test_thePreviewIsTheMoveThatIsPlayed() public {
        white(1e18, address(0xA));
        uint256 last = st().closeBlock;
        (bool ready,) = hook.previewMove(id, bytes32(uint256(1)));
        assertFalse(ready, "not while the window takes bids");
        vm.roll(last + 1);
        bytes32 h = this.hashOf(last);
        uint16 move;
        (ready, move) = hook.previewMove(id, h);
        assertTrue(ready);
        vm.recordLogs();
        black(1e17, address(0xB));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != MOVED) continue;
            (,, uint16 played,,,,,) = abi.decode(logs[i].data, (uint32, uint16, uint16, address, uint256, uint16, uint8, bool));
            assertEq(played, move, "the same move");
            return;
        }
        fail();
    }

    function hashOf(uint256 n) external view returns (bytes32) {
        return blockhash(n);
    }

    /// A mate is paid from the LOSER's chest, in the loser's token, through the real resolve path: here Black
    /// (currency0's team) has one legal move and it mates, so White's team (currency1's) pays.
    function test_aMateIsPaidFromTheLosersChestInItsToken() public {
        forcedMate(true);
        for (uint256 c; c < 2; c++) {
            MockERC20(Currency.unwrap(c == 0 ? currency0 : currency1)).approve(address(hook), type(uint256).max);
            hook.fundChest(pool, c == 1, 100e18);
        }
        assertEq(1 - whiteTeam(), 0, "currency0's team plays Black in game 0");
        uint256 own = hook.chest(id, 0);
        black(1e18, address(0xB0B)); // pays 1 of currency1, the loser's token: the cap is 2
        vm.roll(st().closeBlock + 1);
        white(1e17, address(0)); // plays Black's move
        assertEq(st().gameNo, 1, "mate");
        assertEq(hook.owed(address(0xB0B), currency1.toId()), 2e18, "a quarter of the loser's chest, capped at twice the bid");
        assertApproxEqAbs(hook.chest(id, 1), 98e18, 1e15, "from the loser's chest (plus the playing trade's own fee)");
        assertGe(hook.chest(id, 0), own, "the winner's chest pays nothing");
        uint256 before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(0xB0B));
        hook.withdraw(address(0xB0B), currency1); // recorded for the owner, claimed by anyone for it
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(0xB0B)) - before, 2e18 - 1, "paid in the loser's token, 1 wei kept owed");
    }

    // ---------------------------------------------------------------- who a trade bids for

    /// The owner is the address in hookData (20 bytes packed or 32 bytes ABI-encoded), else the wallet that signed
    /// the transaction: a trade through any router or aggregator earns. A zero address counts as none.
    function test_theOwnerIsTheHookDataAddressElseTheSigner() public {
        uint256 w = whiteTeam();
        swap(pool, w == 1, -1e18, abi.encodePacked(address(0xA11CE)));
        assertEq(bid().owner, address(0xA11CE), "20 bytes packed");
        swap(pool, w == 1, -2e18, abi.encode(address(0xB0B)));
        assertEq(bid().owner, address(0xB0B), "32 bytes ABI-encoded");
        swap(pool, w == 1, -3e18, "");
        assertEq(bid().owner, tx.origin, "none: the signing wallet");
        swap(pool, w == 1, -4e18, abi.encode(address(0)));
        assertEq(bid().owner, tx.origin, "a zero address counts as none");
        swap(pool, w == 1, -5e18, hex"0102");
        assertEq(bid().owner, tx.origin, "anything else counts as none");
        swap(pool, w == 1, -6e18, abi.encodePacked(bytes12(0xffffffffffffffffffffffff), address(0xCAFE)));
        assertEq(bid().owner, tx.origin, "32 bytes with dirty padding count as none");
        vm.prank(address(this), address(0x51)); // a relayed trade: the signer, not the caller
        swap(pool, w == 1, -7e18, "");
        assertEq(bid().owner, address(0x51), "the transaction's signer");
    }

    // ---------------------------------------------------------------- timeouts

    function test_aBuyOfTheOtherTeamTimesTheSilentSideOutAndBids() public {
        next(hook.TURN_TIMEOUT());
        black(1e18, address(0xB)); // White silent: White's move opens at 0% in this block; B bids for Black's next
        assertTrue(bid().open);
        assertEq(bid().owner, address(0), "a timeout move");
        assertEq(st().closeBlock, vm.getBlockNumber());
        assertEq(st().bids[1 - whiteTeam()].owner, address(0xB));
        next(12);
        white(1e17, address(0xA)); // plays White's timeout move; A bids for White's next
        assertEq(st().moveOwner, address(0));
        assertEq(bid().owner, address(0xB), "Black's move is B's");
    }

    // ---------------------------------------------------------------- across a game's end

    /// A bid for a team's next move made while the other side mates still owns that team's next move: the first of
    /// the new game, where the colours have swapped and it plays White.
    function test_aNextMoveBidCarriesIntoTheNextGame() public {
        uint256 b;
        b = put(b, "g1", 6);
        b = put(b, "a1", 4);
        b = put(b, "h8", 14);
        b = put(b, "g7", 9);
        b = put(b, "h7", 9);
        hook.setPosition(id, b, side("g1"), side("h8"), 0, 0);
        uint256 loser = 1 - whiteTeam();
        black(2e18, address(0xB)); // Black's team bids for its next move
        hook.applyMove(pool, mv("a1", "a8"), address(0xA), 1e30); // White mates
        assertEq(st().gameNo, 1);
        assertEq(st().ply, 0);
        assertEq(whiteTeam(), loser, "colours swapped: the losing team now plays White");
        assertTrue(bid().open, "its bid waits for its next move, the new game's first");
        assertEq(bid().owner, address(0xB));
        blocks(3);
        black(1e17, address(0xC)); // plays it
        assertEq(st().moveOwner, address(0xB));
        assertEq(st().moveGameNo, 1);
        assertEq(st().movePly, 0);
    }
}
