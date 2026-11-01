// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// The real v4 contracts used by these suites. Loading their artifacts and leaving out unused upstream test
/// routers keeps a clean worker build small. Swap, initialization and token amounts match v4's Deployers helpers.
abstract contract V4Fixture is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    Currency internal currency0;
    Currency internal currency1;
    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    address feeController;

    function deployV4() internal virtual {
        manager = IPoolManager(vm.deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        bytes memory args = abi.encode(manager);
        swapRouter = PoolSwapTest(vm.deployCode("PoolSwapTest.sol:PoolSwapTest", args));
        modifyLiquidityRouter = PoolModifyLiquidityTest(vm.deployCode("PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest", args));
        feeController = makeAddr("feeController");
        manager.setProtocolFeeController(feeController);
    }

    function deployMintAndApproveCurrency() internal returns (Currency) {
        MockERC20 token = mockToken("TEST", "TEST");
        token.mint(address(this), 2 ** 255);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        return Currency.wrap(address(token));
    }

    function mockToken(string memory name, string memory symbol) internal virtual returns (MockERC20) {
        return MockERC20(vm.deployCode("lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode(name, symbol, uint8(18))));
    }

    function deployMintAndApprove2Currencies() internal returns (Currency, Currency) {
        Currency a = deployMintAndApproveCurrency();
        Currency b = deployMintAndApproveCurrency();
        (currency0, currency1) = a < b ? (a, b) : (b, a);
        return (currency0, currency1);
    }

    function initPool(Currency a, Currency b, IHooks hooks, uint24 fee, uint160 price)
        internal returns (PoolKey memory key, PoolId id)
    {
        return initPool(a, b, hooks, fee, fee.isDynamicFee() ? int24(60) : int24(fee / 100 * 2), price);
    }

    function initPool(Currency a, Currency b, IHooks hooks, uint24 fee, int24 spacing, uint160 price)
        internal returns (PoolKey memory key, PoolId id)
    {
        key = PoolKey(a, b, fee, spacing, hooks);
        id = key.toId();
        manager.initialize(key, price);
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount, bytes memory data)
        internal returns (BalanceDelta)
    {
        bool nativeInput = zeroForOne && key.currency0.isAddressZero();
        if (nativeInput) require(amount < 0, "Use swapNativeInput() for native-token exact-output swaps");
        return swapRouter.swap{value: nativeInput ? uint256(-amount) : 0}(key,
            SwapParams(zeroForOne, amount, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false), data);
    }

    function swapNativeInput(PoolKey memory key, bool zeroForOne, int256 amount, bytes memory data, uint256 value)
        internal returns (BalanceDelta)
    {
        require(key.currency0.isAddressZero(), "currency0 is not native. Use swap() instead");
        if (!zeroForOne) require(value == 0, "msgValue must be 0 for oneForZero swaps");
        return swapRouter.swap{value: value}(key,
            SwapParams(zeroForOne, amount, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false), data);
    }

    receive() external payable {}
}
