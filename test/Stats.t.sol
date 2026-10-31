// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";

/// The player counts (`stats`, `players`): each field counts what it says, counters saturate, the list grows once
/// per address, timeout moves count for nobody. Display and badges only; no rule reads them.
contract StatsTest is Base {
    using CurrencyLibrary for Currency;

    address constant A = address(0xA11CE);
    address constant B = address(0xB0B);

    function setUp() public {
        setUpMainDuel();
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function field(uint256 w, uint256 shift, uint256 bits) internal pure returns (uint256) {
        return (w >> shift) & ((1 << bits) - 1);
    }

    function moves(address who) internal view returns (uint256 m) {
        (m,) = hook.stats(who);
    }

    function rare(address who) internal view returns (uint256 r) {
        (, r) = hook.stats(who);
    }

    /// A position with White to move: the white king on e1, the black king on h8, and `pieces` placed.
    function position(string[2][] memory pieces, uint256[] memory types, uint32 white) internal {
        uint256 b = put(put(0, "e1", 6), "h8", 14);
        for (uint256 i; i < pieces.length; i++) b = put(b, pieces[i][0], types[i]);
        hook.setPosition(id, b, white, side("h8"), 0, 0);
    }

    function test_movesByPieceCastlingAndFullStrength() public {
        hook.applyMove(pool, mv("e2", "e4"), A, 1e18); // pawn
        hook.applyMove(pool, mv("e7", "e5"), B, 1e18);
        hook.applyMove(pool, mv("g1", "f3"), A, 1e18); // knight
        hook.applyMove(pool, mv("b8", "c6"), B, 1e18);
        hook.applyMove(pool, mv("f1", "c4"), A, 1e18); // bishop
        hook.applyMove(pool, mv("f8", "c5"), B, 1e18);
        hook.applyMove(pool, mv("e1", "g1"), A, 1e18); // castles
        hook.applyMove(pool, mv("d7", "d6"), B, 1e18);
        hook.applyMove(pool, mv("d1", "e2"), A, 1e18); // queen
        hook.applyMove(pool, mv("a7", "a6"), B, 1e18);
        hook.applyMove(pool, mv("f1", "e1"), A, 1e18); // rook
        uint256 m = moves(A);
        assertEq(field(m, 0, 20), 1, "pawn moves");
        assertEq(field(m, 20, 20), 1, "bishop moves");
        assertEq(field(m, 40, 20), 1, "knight moves");
        assertEq(field(m, 60, 20), 1, "rook moves");
        assertEq(field(m, 80, 20), 1, "queen moves");
        assertEq(field(m, 100, 20), 1, "king moves");
        assertEq(field(m, 232, 12), 1, "castles");
        assertEq(field(m, 244, 12), 6, "moves at full strength (the harness plays every move at 90%)");
        assertEq(field(m, 200, 20), 0, "no checks");
        assertEq(field(moves(B), 0, 20), 3, "B's pawn moves");
        assertEq(field(moves(B), 232, 12), 0);
    }

    function test_checksAndCapturesByType() public {
        string[2][] memory p = new string[2][](1);
        uint256[] memory t = new uint256[](1);
        // a queen check: Qd1-d8 next to the black king (it can take it: still a check)
        (p[0][0], t[0]) = ("d1", 5);
        position(p, t, side("e1"));
        hook.applyMove(pool, mv("d1", "d8"), A, 1e18);
        assertEq(field(moves(A), 200, 20), 1, "checks");
        // captures: a pawn takes a queen, the king takes a rook, a knight a bishop, a rook a knight, a bishop a pawn
        string[2][] memory q = new string[2][](2);
        uint256[] memory u = new uint256[](2);
        (q[0][0], u[0], q[1][0], u[1]) = ("d4", 1, "e5", 13);
        position(q, u, side("e1"));
        hook.applyMove(pool, mv("d4", "e5"), A, 1e18);
        (q[0][0], u[0], q[1][0], u[1]) = ("d2", 12, "a1", 4); // Rd2 does not check e1; the king takes it
        position(q, u, side("e1"));
        hook.applyMove(pool, mv("e1", "d2"), A, 1e18);
        (q[0][0], u[0], q[1][0], u[1]) = ("c3", 3, "d5", 10);
        position(q, u, side("e1"));
        hook.applyMove(pool, mv("c3", "d5"), A, 1e18);
        (q[0][0], u[0], q[1][0], u[1]) = ("a1", 4, "a5", 11);
        position(q, u, side("e1"));
        hook.applyMove(pool, mv("a1", "a5"), A, 1e18);
        (q[0][0], u[0], q[1][0], u[1]) = ("c1", 2, "f4", 9);
        position(q, u, side("e1"));
        hook.applyMove(pool, mv("c1", "f4"), A, 1e18);
        uint256 m = moves(A);
        assertEq(field(m, 120, 16), 1, "pawns taken");
        assertEq(field(m, 136, 16), 1, "bishops taken");
        assertEq(field(m, 152, 16), 1, "knights taken");
        assertEq(field(m, 168, 16), 1, "rooks taken");
        assertEq(field(m, 184, 16), 1, "queens taken");
        uint256 r = rare(A);
        assertEq(field(r, 28, 12), 1, "a pawn took a queen");
        assertEq(field(r, 40, 12), 1, "the king took a piece");
        assertEq(field(r, 16, 12), 0, "no en passant");
        assertEq(field(r, 0, 16), 0, "no mate");
    }

    function test_enPassantAndPromotion() public {
        // Black plays d7-d5 past White's pawn on e5, which takes it en passant
        uint256 b = put(put(put(put(0, "e1", 6), "h8", 14), "e5", 1), "d7", 9);
        hook.setPosition(id, b, side("e1"), side("h8"), 1, 0);
        hook.applyMove(pool, mv("d7", "d5"), B, 1e18);
        hook.applyMove(pool, mv("e5", "d6"), A, 1e18);
        assertEq(field(rare(A), 16, 12), 1, "en passant");
        assertEq(field(moves(A), 120, 16), 1, "a pawn taken");
        assertEq(st().moveCaptured, 1);
        // a pawn promotes (to a queen, the engine's choice)
        b = put(put(put(0, "e1", 6), "h8", 14), "a7", 1);
        hook.setPosition(id, b, side("e1"), side("h8"), 0, 0);
        hook.applyMove(pool, mv("a7", "a8"), A, 1e18);
        assertEq(field(moves(A), 220, 12), 1, "promotions");
        assertEq(field(moves(A), 0, 20), 2, "both were pawn moves");
    }

    /// Games are counted once per game played in, the first main-duel game is kept, a mate is counted for its owner,
    /// and the player list grows once per address; a timeout move counts for nobody.
    function test_gamesMatesAndThePlayerList() public {
        assertEq(hook.playerCount(), 0);
        hook.applyMove(pool, mv("e2", "e4"), A, 1e18);
        assertEq(hook.playerCount(), 1);
        hook.applyMove(pool, mv("e7", "e5"), A, 1e18); // the same address again
        assertEq(hook.playerCount(), 1);
        hook.applyMove(pool, mv("g1", "f3"), address(0), 0); // a timeout move
        assertEq(hook.playerCount(), 1);
        hook.applyMove(pool, mv("b8", "c6"), B, 1e18);
        assertEq(hook.playerCount(), 2);
        assertEq(hook.players(0), A);
        assertEq(hook.players(1), B);
        assertEq(field(rare(A), 52, 24), 1, "games played");
        assertEq(field(rare(A), 108, 32), 1, "the first main-duel game, plus one");
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
        uint256 w = whiteTeam();
        mateAgainst(1 - w, A, 1e30); // game 0 ends, A mated
        assertEq(field(rare(A), 0, 16), 1, "mates");
        hook.applyMove(pool, mv("e2", "e4"), A, 1e18); // game 1
        assertEq(field(rare(A), 52, 24), 2, "a second game");
        assertEq(field(rare(A), 108, 32), 1, "the first main-duel game stays");
        assertEq(field(rare(B), 52, 24), 1);
        assertEq(field(rare(B), 0, 16), 0);
        assertEq(hook.playerCount(), 2);
    }

    /// What a mate won is counted in IMD (currency0 here) and in $IMDUEL (currency1), in units of 10^15 wei.
    function test_amountsWonAreCountedPerToken() public {
        hook.fundChest(pool, false, 100e18);
        hook.fundChest(pool, true, 100e18);
        mateAgainst(0, A, 1e30); // IMD's team loses: 25 IMD
        mateAgainst(1, A, 1e30); // $IMDUEL's team loses: 25 $IMDUEL
        assertEq(field(rare(A), 140, 40), 25_000, "IMD won");
        assertEq(field(rare(A), 180, 40), 25_000, "$IMDUEL won");
        assertEq(field(rare(A), 0, 16), 2, "two mates");
    }

    /// A side duel counts nothing: its empty pots play every bid at the cap for free, so its counts could be farmed
    /// for gas (audit 2026-10-31). Only the main duel's moves and prizes count.
    function test_aSideDuelCountsNothing() public {
        MockERC20 x = mockToken("X", "X");
        Currency c = Currency.wrap(address(x));
        (Currency a, Currency b) = c < currency0 ? (c, currency0) : (currency0, c);
        (PoolKey memory sideKey, PoolId sideId) = initPool(a, b, IHooks(address(hook)), 3000, SQRT_PRICE_1_1); // IMD / X
        hook.setPosition(sideId, put(put(put(put(put(0, "g1", 6), "a1", 4), "h8", 14), "g7", 9), "h7", 9), side("g1"), side("h8"), 0, 0);
        hook.applyMove(sideKey, mv("a1", "a8"), A, 1e18); // a back-rank mate for A, in the side duel
        assertEq(hook.game(sideId).gameNo, 1, "the side duel's game ended");
        (uint256 m, uint256 r) = hook.stats(A);
        assertEq(m, 0, "no moves counted");
        assertEq(r, 0, "no mate counted");
        assertEq(hook.playerCount(), 0, "not listed");
        hook.applyMove(pool, mv("e2", "e4"), A, 1e18); // the main duel counts
        assertEq(field(moves(A), 0, 20), 1);
        assertEq(hook.playerCount(), 1);
    }

    /// A field stops at its maximum and never spills into its neighbours.
    function test_countersSaturate() public view {
        uint256 w = (7 << 220) | (4_090 << 232) | (9 << 244);
        w = hook.add(w, 232, 12, 3);
        assertEq(field(w, 232, 12), 4_093);
        w = hook.add(w, 232, 12, 5);
        assertEq(field(w, 232, 12), 4_095, "stops at the maximum");
        w = hook.add(w, 232, 12, type(uint256).max);
        assertEq(field(w, 232, 12), 4_095, "and stays there");
        assertEq(field(w, 220, 12), 7, "the field below is untouched");
        assertEq(field(w, 244, 12), 9, "the field above is untouched");
        assertEq(hook.add(0, 140, 40, type(uint256).max), ((1 << 40) - 1) << 140, "a huge amount saturates a 40-bit field");
    }
}
