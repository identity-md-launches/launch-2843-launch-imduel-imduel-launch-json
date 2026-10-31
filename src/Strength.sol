// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// How strongly a trade's move is played: from what it received as a share of its own team's pot, which only money given to the game moves. +30% per tenfold share: 0% at 0.1% of the pot, 30% at 1%,
/// 60% at 10%, the 90% cap from the whole pot. An empty pot plays at the cap; a trade that received nothing at 0.
library Strength {
    uint256 internal constant MAX_BPS = 9_000;
    uint256 internal constant BPS_PER_DOUBLING = 903; // 3,000 per tenfold / log2(10)
    uint256 internal constant FLOOR = 1_000; // a share of 1 / FLOOR plays at 0
    uint256 internal constant FLOOR_BITS = 10; // 2^10 > FLOOR: a payment shifted this far times FLOOR always fits

    /// Strength in basis points of a trade that received `paid` against a pot of `depth` (both in the same token).
    function fromShare(uint256 paid, uint256 depth) internal pure returns (uint16) {
        if (paid == 0) return 0;
        if (paid >= depth) return uint16(MAX_BPS); // the whole pot or more (an empty pot too): the cap
        // a payment too large to scale by FLOOR: shift both out of the way (the share is what counts, and both keep
        // their fraction bits), instead of reverting
        if (paid > type(uint256).max / FLOOR) {
            paid >>= FLOOR_BITS;
            depth >>= FLOOR_BITS;
        }
        uint256 up = _log2x256(paid * FLOOR);
        uint256 down = _log2x256(depth);
        if (up <= down) return 0;
        uint256 s = (up - down) * BPS_PER_DOUBLING / 256;
        return uint16(s > MAX_BPS ? MAX_BPS : s);
    }

    /// log2(x) * 256, the fraction linear between powers of two (at most ~0.086 low): enough for a strength curve.
    function _log2x256(uint256 x) internal pure returns (uint256) {
        uint256 n;
        assembly ("memory-safe") {
            n := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            n := or(n, shl(6, lt(0xffffffffffffffff, shr(n, x))))
            n := or(n, shl(5, lt(0xffffffff, shr(n, x))))
            n := or(n, shl(4, lt(0xffff, shr(n, x))))
            n := or(n, shl(3, lt(0xff, shr(n, x))))
            n := or(n, shl(2, lt(0xf, shr(n, x))))
            n := or(n, shl(1, lt(0x3, shr(n, x))))
            n := or(n, lt(0x1, shr(n, x)))
        }
        // the 8 bits under the leading one
        uint256 frac = n >= 8 ? (x >> (n - 8)) & 0xff : (x << (8 - n)) & 0xff;
        return n * 256 + frac;
    }
}
