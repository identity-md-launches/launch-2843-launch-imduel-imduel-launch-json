// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Base} from "./Base.sol";

/// The protocol slice, 0.1% of every swap, taken with no swap and no price: in $IMDUEL wherever
/// the pool holds it, burned (owed to 0x...dEaD, sent by anyone's withdraw); in a pool without $IMDUEL, in IMD into the
/// main duel's IMD pot. The pot fee is half from each side of a trade, into that token's own pool's pot.
contract SliceTest is Base {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    Currency imd;
    Currency duel;
    Currency x; // some other token
    PoolKey main;

    function token(string memory name) internal returns (Currency c) {
        MockERC20 t = mockToken(name, name);
        t.mint(address(this), 1e36);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        c = Currency.wrap(address(t));
    }

    function newPool(Currency a, Currency b) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        (k,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        addLiquidity(k);
    }

    function setUp() public {
        deployV4();
        (imd, duel, x) = (token("IMD"), token("IMDUEL"), token("X"));
        deployHook(config(v5(), imd));
        main = newPool(imd, duel);
        (pool, id) = (main, main.toId());
    }

    /// Exact input of `amount` of `input` in pool `k`.
    function pay(PoolKey memory k, Currency input, uint256 amount) internal {
        swap(k, input == k.currency0, -int256(amount), "");
    }

    /// The main duel's pot of `c` (IMD or $IMDUEL).
    function mainPot(Currency c) internal view returns (uint256) {
        return hook.chest(main.toId(), c == main.currency0 ? 0 : 1);
    }

    function burn() internal view returns (uint256) {
        return hook.owed(DEAD, duel.toId());
    }

    function solvent(PoolKey memory other) internal view {
        bool same = PoolId.unwrap(other.toId()) == PoolId.unwrap(main.toId());
        PoolKey[] memory pools = new PoolKey[](same ? 1 : 2);
        pools[0] = main;
        if (!same) pools[1] = other;
        for (uint256 i; i < 3; i++) assertSolvent([imd, duel, x][i], pools, nobody());
    }

    /// Selling 10 $IMDUEL for IMD: the slice, 0.1% of the $IMDUEL side, is burned; half the pot fee from each side.
    function test_theMainDuelsSliceIsBurned() public {
        pay(main, duel, 10e18);
        assertEq(burn(), 0.01e18, "0.1% of the $IMDUEL input, burned");
        assertEq(mainPot(duel), 10e18 * 65 / 20_000, "the $IMDUEL pot: half the pot fee, from the input");
        assertGt(mainPot(imd), 0.03e18, "the IMD pot: the other half, from the IMD bought");
        solvent(main);
    }

    /// Buying $IMDUEL with IMD: the slice is taken from the $IMDUEL bought and burned.
    function test_buyingImduelBurnsASliceOfIt() public {
        pay(main, imd, 10e18);
        assertGt(burn(), 0, "a slice of the $IMDUEL bought, burned");
        assertEq(mainPot(imd), 10e18 * 65 / 20_000, "half the pot fee from the IMD paid");
        assertEq(claims(duel), mainPot(duel) + burn(), "every $IMDUEL claim is the pot or the burn");
    }

    /// A duel against IMD sends its slice, in IMD, to the main duel's IMD pot; its own pots get the pot fee.
    function test_aDuelAgainstImdSendsItsSliceToTheMainDuelsImdPot() public {
        PoolKey memory duelX = newPool(x, imd);
        pay(duelX, imd, 10e18); // buys X with 10 IMD
        assertEq(mainPot(imd), 0.01e18, "0.1% of the IMD side, to the main duel's IMD pot");
        assertEq(burn(), 0);
        assertEq(hook.chest(duelX.toId(), duelX.currency0 == imd ? 0 : 1), 10e18 * 65 / 20_000, "the duel's IMD pot: its half");
        assertGt(hook.chest(duelX.toId(), duelX.currency0 == x ? 0 : 1), 0, "the X pot: the other half");
        solvent(duelX);
    }

    /// A duel against $IMDUEL slices in $IMDUEL and burns it; the main duel's pots are untouched.
    function test_aDuelAgainstImduelBurnsItsSlice() public {
        PoolKey memory duelX = newPool(x, duel);
        pay(duelX, duel, 10e18);
        assertEq(burn(), 0.01e18);
        assertEq(mainPot(duel), 0);
        solvent(duelX);
    }

    /// The whole slice is burned, to the wei.
    function test_theWholeSliceIsBurnedToTheWei() public {
        pay(main, duel, 10e18 + 1_000); // a slice of 0.01e18 + 1 wei
        assertEq(burn(), 0.01e18 + 1);
        solvent(main);
    }

    /// The burn is sent by anyone's withdraw to 0x...dEaD (all but the 1 wei every claim leaves).
    function test_anyoneSendsTheBurn() public {
        pay(main, duel, 10e18);
        uint256 owed = burn();
        vm.prank(address(0xB0B));
        hook.withdraw(DEAD, duel);
        assertEq(MockERC20(Currency.unwrap(duel)).balanceOf(DEAD), owed - 1);
        assertEq(burn(), 1);
        solvent(main);
    }

    /// The hook swaps nothing of its own: a side duel's trade leaves the main duel's price where it was.
    function test_aSliceMovesNoPrice() public {
        PoolKey memory duelX = newPool(x, imd);
        (uint160 before,,,) = manager.getSlot0(main.toId());
        for (uint256 i; i < 5; i++) pay(duelX, imd, 1_000e18);
        (uint160 after_,,,) = manager.getSlot0(main.toId());
        assertEq(after_, before);
        assertEq(mainPot(imd), 5e18, "5 x 0.1% of 1,000 IMD");
    }

    /// A trade too small for a slice pays none: nothing is burned, nothing is lost.
    function test_dustPaysNoSlice() public {
        pay(main, duel, 999);
        assertEq(burn(), 0);
        solvent(main);
    }
}
