// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strength} from "../src/Strength.sol";

/// Direct coverage of the shipped strength curve, independent of any hook.
contract StrengthTest is Test {
    uint256 internal constant MAX_SCALED_PAID = type(uint256).max / 1_000; // the largest paid * FLOOR that fits

    /// The share of the team's pot: 0% at 0.1%, 30% at 1%, 60% at 10%, 90% from the whole pot.
    function test_decidedPoints() public pure {
        uint256 pot = 1e9;
        assertEq(Strength.fromShare(100_000, pot), 0, "below the floor");
        assertEq(Strength.fromShare(1_000_000, pot), 0, "0.1% share");
        // The interpolated logarithm approximates each nominal point within one percentage point.
        assertApproxEqAbs(Strength.fromShare(10_000_000, pot), 3_000, 100, "1% share");
        assertApproxEqAbs(Strength.fromShare(100_000_000, pot), 6_000, 100, "10% share");
        assertApproxEqAbs(Strength.fromShare(999_999_999, pot), 9_000, 100, "just under the whole pot");
        assertEq(Strength.fromShare(pot, pot), 9_000, "the whole pot");
        assertEq(Strength.fromShare(pot * 10, pot), 9_000, "more than the pot");
    }

    /// A trade that received nothing plays at 0; an empty pot plays at the cap (nothing to measure against).
    function test_zeroInputs() public pure {
        assertEq(Strength.fromShare(0, 0), 0);
        assertEq(Strength.fromShare(0, type(uint256).max), 0);
        assertEq(Strength.fromShare(1, 0), 9_000, "an empty pot plays at the cap");
        assertEq(Strength.fromShare(type(uint256).max, 0), 9_000);
    }

    function testFuzz_boundedAndMonotonic(uint256 paid, uint256 more, uint256 depth) public pure {
        more = bound(more, paid, type(uint256).max);
        uint256 low = Strength.fromShare(paid, depth);
        uint256 high = Strength.fromShare(more, depth);
        assertLe(low, high, "paying more cannot reduce strength");
        assertLe(high, 9_000, "strength remains capped");
    }

    function testFuzz_depthMonotonic(uint256 paid, uint256 depth, uint256 deeper) public pure {
        depth = bound(depth, 1, type(uint256).max);
        deeper = bound(deeper, depth, type(uint256).max);
        assertLe(Strength.fromShare(paid, deeper), Strength.fromShare(paid, depth), "more depth reduces share");
    }

    function testFuzz_tenfoldIsAboutThirtyPoints(uint128 rawPaid, uint128 rawDepth) public pure {
        uint256 depth = bound(uint256(rawDepth), 1_000_000, type(uint128).max);
        // Keep both shares between the floor (0.1%) and the cap (the whole pot).
        uint256 paid = bound(uint256(rawPaid), (depth + 999) / 1_000, depth / 10);
        uint256 before = Strength.fromShare(paid, depth);
        uint256 afterTenfold = Strength.fromShare(paid * 10, depth);
        assertGe(afterTenfold, before);
        assertApproxEqAbs(afterTenfold - before, 3_000, 100);
    }

    /// A payment too large to scale by the floor used to revert with Panic(0x11) (audit 8116943f, review 916b9526):
    /// now it plays at the cap when it is the whole depth or more, and at its share otherwise.
    function test_hugePaymentsDoNotRevert() public pure {
        assertEq(Strength.fromShare(MAX_SCALED_PAID, 1), 9_000, "last scalable paid reaches the cap");
        assertEq(Strength.fromShare(MAX_SCALED_PAID + 1, 1), 9_000, "the first unscalable paid too");
        assertEq(Strength.fromShare(MAX_SCALED_PAID + 1, MAX_SCALED_PAID + 1), 9_000, "a 100% share");
        assertEq(Strength.fromShare(type(uint256).max, 1), 9_000, "the largest payment");
        assertEq(Strength.fromShare(type(uint256).max, type(uint256).max), 9_000, "all of the largest depth");
        assertLe(Strength.fromShare(MAX_SCALED_PAID, type(uint256).max), 10, "last scalable paid at the floor");
        assertLe(Strength.fromShare(MAX_SCALED_PAID + 1, type(uint256).max), 10, "the first unscalable paid too");
        // a share of 2^-5 (3.125%): 30 points per tenfold above 0.1% gives about 4,480
        assertApproxEqAbs(Strength.fromShare(1 << 250, 1 << 255), 4_480, 100, "an unscalable paid at its share");
    }

    /// The curve is unchanged where it never reverted, and continues it where it did: shifting a payment and its
    /// depth by the same amount keeps the share, so it keeps the strength, across the scaling boundary.
    function testFuzz_shiftKeepsTheShare(uint256 paid, uint256 depth, uint8 shift) public pure {
        shift = uint8(bound(shift, 1, 40));
        paid = bound(paid, 1, type(uint256).max >> shift);
        depth = bound(depth, 1, type(uint256).max >> shift);
        assertEq(Strength.fromShare(paid << shift, depth << shift), Strength.fromShare(paid, depth));
    }

    /// Above the scaling boundary the curve stays within a few points of the shifted computation at every payment
    /// (the cap test reads the unshifted values, so a share just under 1 can land a few points under it).
    function testFuzz_unscalablePaidFollowsTheCurve(uint256 paid, uint256 depth) public pure {
        paid = bound(paid, MAX_SCALED_PAID + 1, type(uint256).max);
        depth = bound(depth, paid, type(uint256).max);
        uint256 s = Strength.fromShare(paid, depth);
        assertLe(s, 9_000);
        assertApproxEqAbs(s, Strength.fromShare(paid >> 10, depth >> 10), 20, "the share decides");
    }
}
