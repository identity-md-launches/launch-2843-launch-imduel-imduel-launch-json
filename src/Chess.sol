// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// What the rules, the engine and the hook share about a chess position, defined once.
///
/// Board: 64 squares of 4 bits (a1 = bits 0-3), piece type in the low three bits (1 pawn, 2 bishop, 3 knight,
/// 4 rook, 5 queen, 6 king), +8 for Black. A side's state packs its castling rooks, king square and en-passant
/// square (the ChessFish encoding). A move is from << 6 | to; promotion is always to a queen.
library Chess {
    uint256 internal constant START_BOARD = 0xcbaedabc99999999000000000000000000000000000000001111111143265234;
    uint32 internal constant START_WHITE = 0x000704ff;
    uint32 internal constant START_BLACK = 0x383f3cff;

    /// IMDuel's draw rules beyond stalemate, too little material and a position's third time, counting itself and the
    /// positions up to sixteen half-moves earlier (the start position counts from any distance; a repetition further
    /// apart is left to the quiet-move limit).
    uint16 internal constant MAX_PLY = 200;
    uint16 internal constant MAX_QUIET_PLY = 60; // half-moves without a capture or pawn move

    /// 64 bits of the position's hash, as the hook's repetition memory and the engine's history keep it.
    /// Positions come from play, not from a chooser, so a false match (about 2^-61 per check) is not reachable on
    /// purpose. Full side states are kept, which is conservative about castling and en-passant rights.
    function positionKey(uint256 board, uint32 whiteState, uint32 blackState, bool blackToMove, uint32 gameNo)
        internal
        pure
        returns (uint64)
    {
        return uint64(uint256(keccak256(abi.encode(board, whiteState, blackState, blackToMove, gameNo))));
    }

    /// The piece type on square `sq` (0 empty).
    function typeAt(uint256 board, uint256 sq) internal pure returns (uint8) {
        return uint8(board >> (sq << 2)) & 7;
    }
}
