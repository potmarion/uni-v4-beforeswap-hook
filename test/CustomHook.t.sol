// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPermit2} from "v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {CustomHook} from "../src/CustomHook.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

contract TestCustomHook is Test, IERC721Receiver {
    using SafeERC20 for IERC20;

    IPositionManager constant positionManager =
        IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPoolManager constant poolManager =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPermit2 constant permit2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IUniversalRouter constant universalRouter =
        IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);

    IAavePool constant aavePool =
        IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IERC20 constant aUSDC = IERC20(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
    IERC20 constant aUSDT = IERC20(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    address constant ALICE = address(0x111);
    address constant BOB = address(0x222);
    address constant CHARLIE = address(0x333);

    CustomHook customHook;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setupPool(address usdc, address usdt) public {
        (, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ),
            type(CustomHook).creationCode,
            abi.encode(address(poolManager), address(aavePool))
        );

        customHook = new CustomHook{salt: salt}(poolManager, aavePool);

        console2.log("customHook:", address(customHook));

        customHook.setATokens(address(aUSDC), Currency.wrap(usdc));
        customHook.setATokens(address(aUSDT), Currency.wrap(usdt));

        // Create pool key for USDC/USDT
        poolKey = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(usdt),
            fee: 10000, // Must be 0 for wrapper pools
            tickSpacing: 200,
            hooks: IHooks(address(customHook))
        });

        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(poolKey, initSqrtPriceX96);

        // Add liquidity
        deal(address(USDC), address(this), 1_000_000e6);
        deal(address(USDT), address(this), 1_000_000e6);
        USDC.forceApprove(address(permit2), type(uint).max);
        USDT.forceApprove(address(permit2), type(uint).max);
        permit2.approve(
            address(USDC),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        permit2.approve(
            address(USDT),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            -200,
            200,
            1_000_000e6,
            type(uint).max,
            type(uint).max,
            address(this),
            ""
        );
        params[1] = abi.encode(
            Currency.wrap(address(USDC)),
            Currency.wrap(address(USDT))
        );
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );
    }

    function swapExactInputSingle(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minAmountOut,
        address user
    ) public returns (uint256 amountOut) {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: customHook.getHookData(user)
            })
        );
        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        universalRouter.execute(commands, inputs, block.timestamp + 60);

        // Verify and return the output amount
        amountOut = IERC20(Currency.unwrap(key.currency1)).balanceOf(
            address(this)
        );
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }

    function setUp() public {
        // vm.createSelectFork("https://rpc.ankr.com/eth");
        vm.createSelectFork("http://127.0.0.1:8545");

        deal(address(USDC), ALICE, 1_000_000e6);
        deal(address(USDT), ALICE, 1_000_000e6);
        deal(address(USDC), BOB, 1_000_000e6);
        deal(address(USDT), BOB, 1_000_000e6);
        deal(address(USDC), CHARLIE, 1_000_000e6);
        deal(address(USDT), CHARLIE, 1_000_000e6);

        vm.startPrank(ALICE);
        USDC.forceApprove(address(permit2), type(uint).max);
        USDT.forceApprove(address(permit2), type(uint).max);
        vm.stopPrank();

        vm.startPrank(BOB);
        USDC.forceApprove(address(permit2), type(uint).max);
        USDT.forceApprove(address(permit2), type(uint).max);
        vm.stopPrank();

        vm.startPrank(CHARLIE);
        USDC.forceApprove(address(permit2), type(uint).max);
        USDT.forceApprove(address(permit2), type(uint).max);
        vm.stopPrank();
    }

    function testSetupPool() public {
        setupPool(address(USDC), address(USDT));
    }

    function testHookDeployment() public {
        setupPool(address(USDC), address(USDT));
        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(aUSDC)),
            currency1: Currency.wrap(address(USDT)),
            fee: 10000, // Must be 0 for wrapper pools
            tickSpacing: 200,
            hooks: IHooks(address(customHook))
        });

        vm.expectRevert();
        poolManager.initialize(invalidPoolKey, initSqrtPriceX96);

        invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(aUSDC)),
            currency1: Currency.wrap(address(USDC)),
            fee: 10000, // Must be 0 for wrapper pools
            tickSpacing: 200,
            hooks: IHooks(address(customHook))
        });
        vm.expectRevert();
        poolManager.initialize(invalidPoolKey, initSqrtPriceX96);
    }

    function testSwapFeeToAave() public {
        setupPool(address(USDC), address(USDT));

        permit2.approve(
            address(USDC),
            address(universalRouter),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );

        uint128 swapAmount = 1_000e6;
        uint fee = swapAmount / 1000;
        uint aReserveBefore = USDC.balanceOf(address(aUSDC));

        swapExactInputSingle(poolKey, swapAmount, 0, address(this));

        assertEq(USDC.balanceOf(address(aUSDC)) - aReserveBefore, fee);
        assertEq(aUSDC.balanceOf(address(customHook)), fee);
    }

    function testWithdrawRewardsForDevAndTraders() public {
        setupPool(address(USDC), address(USDT));

        vm.startPrank(ALICE);
        permit2.approve(
            address(USDC),
            address(universalRouter),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );

        uint128 swapAmount = 1_000e6;
        uint fee = swapAmount / 1000;

        swapExactInputSingle(poolKey, swapAmount, 0, ALICE);
        vm.stopPrank();

        assertEq(
            customHook.devFeeAccrued(Currency.wrap(address(USDC))),
            fee / 2
        );
        assertEq(customHook.devFeeAccrued(Currency.wrap(address(USDT))), 0);
        assertEq(
            customHook.pendingRewards(ALICE, Currency.wrap(address(USDC))),
            fee / 2
        );

        vm.startPrank(address(this));
        uint usdcDevBalBefore = USDC.balanceOf(address(this));
        customHook.claimDevFee(Currency.wrap(address(USDC)));
        assertEq(customHook.devFeeAccrued(Currency.wrap(address(USDC))), 0);
        assertEq(USDC.balanceOf(address(this)) - usdcDevBalBefore, fee / 2);
        vm.stopPrank();

        vm.startPrank(ALICE);
        uint usdcBalBefore = USDC.balanceOf(ALICE);
        customHook.claimUserFee(Currency.wrap(address(USDC)));
        assertEq(
            customHook.pendingRewards(ALICE, Currency.wrap(address(USDC))),
            0
        );
        vm.stopPrank();
    }

    function testRewardsDistributionVolume() public {
        setupPool(address(USDC), address(USDT));

        uint128 swapAmount = 2_000e6;
        uint rewards = swapAmount / 2000;

        vm.startPrank(ALICE);
        permit2.approve(
            address(USDC),
            address(universalRouter),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount, 0, ALICE);
        vm.stopPrank();
        assertEq(
            customHook.pendingRewards(ALICE, Currency.wrap(address(USDC))),
            rewards
        );

        vm.startPrank(BOB);
        permit2.approve(
            address(USDC),
            address(universalRouter),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount, 0, BOB);
        vm.stopPrank();
        assertEq(
            customHook.pendingRewards(ALICE, Currency.wrap(address(USDC))),
            rewards + rewards / 2
        );
        assertEq(
            customHook.pendingRewards(BOB, Currency.wrap(address(USDC))),
            rewards / 2
        );

        vm.startPrank(CHARLIE);
        permit2.approve(
            address(USDC),
            address(universalRouter),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount * 2, 0, CHARLIE);
        vm.stopPrank();
        assertEq(
            customHook.pendingRewards(ALICE, Currency.wrap(address(USDC))),
            1e6 * 2
        );
        assertEq(
            customHook.pendingRewards(BOB, Currency.wrap(address(USDC))),
            1e6
        );
        assertEq(
            customHook.pendingRewards(CHARLIE, Currency.wrap(address(USDC))),
            1e6
        );

        vm.prank(ALICE);
        customHook.claimUserFee(Currency.wrap(address(USDC)));
        vm.startPrank(BOB);
        permit2.approve(
            address(USDC),
            address(universalRouter),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount, 0, BOB);
        vm.stopPrank();
        assertEq(
            customHook.pendingRewards(ALICE, Currency.wrap(address(USDC))),
            0.2e6
        );
        assertEq(
            customHook.pendingRewards(BOB, Currency.wrap(address(USDC))),
            1.4e6
        );
        assertEq(
            customHook.pendingRewards(CHARLIE, Currency.wrap(address(USDC))),
            1.4e6
        );
    }
}
