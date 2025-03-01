// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";

contract CustomHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using SafeERC20 for IERC20;

    Currency public immutable USDC = Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    Currency public immutable USDT = Currency.wrap(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    error InvalidPoolTokens();

    constructor(IPoolManager _poolManager, IAavePool _aavePool) BaseHook(_poolManager) Ownable(msg.sender) {
        aavePool = _aavePool;

        IERC20(Currency.unwrap(USDC)).forceApprove(address(aavePool), type(uint256).max);
        IERC20(Currency.unwrap(USDT)).forceApprove(address(aavePool), type(uint256).max);
    }

    // -----------------------------------------------
    // NOTE: Hook related functions
    // -----------------------------------------------

    /// @notice Inherit from getHookPermissions of BaseHook
    /// These Hook flags should be set as true:
    /// - beforeInitialize
    /// - beforeSwap
    /// - beforeSwapReturnDelta
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Inherit from _beforeInitialize of BaseHook
    /// Implemented logic:
    /// pool token validation in beforeInitialize hook
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (key.currency0 == USDC && key.currency1 == USDT) {
            return BaseHook.beforeInitialize.selector;
        }

        revert InvalidPoolTokens();
    }

    /// @notice Inherit from _beforeSwap of BaseHook
    /// Implemented logics:
    /// step1: take 0.1% from input token amount(amountSpecified) per each swap.
    ///        hook developer gets 50% of taken fee as a reward
    /// step2: deposit taken fee to aave lending pool
    ///
    /// step3: deposit to virtual masterchef
    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 swapAmount =
            uint256(swapParams.amountSpecified > 0 ? swapParams.amountSpecified : -swapParams.amountSpecified);
        Currency swapCurrency = swapParams.zeroForOne ? USDC : USDT;

        // calculate fee
        uint256 fee = swapAmount / 1000;
        totalFeeAccrued[swapCurrency] += fee;
        devFeeAccrued[swapCurrency] += fee / 2;
        poolManager.take(swapCurrency, address(this), fee);

        /// deposit fee to aave
        _depositToAave(fee, swapCurrency);

        /// deposit to virtual masterchef
        address user = parseHookData(hookData);
        _depositToVirtualMC(user, swapAmount, swapCurrency);
        _addRewardsToVirtualMC(swapParams.zeroForOne ? USDC : USDT, fee / 2);

        // calculate BeforeSwapDelta
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(fee)), 0);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    // -----------------------------------------------
    // NOTE: Virtual Masterchef related logics
    // -----------------------------------------------

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    mapping(Currency => mapping(address => UserInfo)) public userInfos;
    mapping(Currency => uint256) public devFeeAccrued;
    mapping(Currency => uint256) public totalFeeAccrued;
    mapping(Currency => uint256) public rewardPerShare;
    mapping(Currency => uint256) public totalShares;

    /// @notice Encode hook data
    function getHookData(address user) public pure returns (bytes memory) {
        return abi.encode(user);
    }

    /// @notice Decode hook data
    function parseHookData(bytes calldata data) public pure returns (address user) {
        return abi.decode(data, (address));
    }

    /// @notice Pending rewards amount in virtual masterchef
    function pendingRewards(address user, Currency currency) public view returns (uint256 reward) {
        UserInfo storage userInfo = userInfos[currency][user];
        reward = (userInfo.amount * rewardPerShare[currency]) / 1e18 - userInfo.rewardDebt;
    }

    /// @notice Claim user fee, called by anyone
    /// Withdraw fee from Aave pool and returns to user
    function claimUserFee(Currency currency) external {
        address user = msg.sender;
        uint256 pendingReward = pendingRewards(user, currency);
        if (pendingReward > 0) {
            UserInfo storage userInfo = userInfos[currency][user];
            userInfo.rewardDebt = (userInfo.amount * rewardPerShare[currency]) / 1e18;
            _withdrawFromAave(pendingReward, user, currency);
        }
    }

    /// @notice Claim dev fee, called only by hook developer(owner)
    /// Withdraw fee from Aave pool and returns to user
    function claimDevFee(Currency currency) external onlyOwner {
        _withdrawFromAave(devFeeAccrued[currency], msg.sender, currency);
        devFeeAccrued[currency] = 0;
    }

    /// @notice Deposit to virtual masterchef
    /// This function is needed for reward calculation
    function _depositToVirtualMC(address user, uint256 amount, Currency currency) internal {
        UserInfo storage userInfo = userInfos[currency][user];
        userInfo.amount += amount;
        userInfo.rewardDebt += (amount * rewardPerShare[currency]) / 1e18;
        totalShares[currency] += amount;
    }

    /// @notice Add reward to virtual masterchef
    function _addRewardsToVirtualMC(Currency currency, uint256 amount) internal {
        rewardPerShare[currency] += (amount * 1e18) / totalShares[currency];
    }

    // -----------------------------------------------
    // NOTE: Aave related logics
    // -----------------------------------------------

    mapping(Currency => IERC20) public aTokens;
    mapping(Currency => uint256) public totalATokenShares;
    IAavePool public immutable aavePool;

    /// @notice Set aToken of currency
    function setATokens(address aToken, Currency uToken) external onlyOwner {
        aTokens[uToken] = IERC20(aToken);
    }

    /// @notice Aave's aToken share price calcuation
    function _getATokenSharePrice(Currency currency) internal view returns (uint256) {
        return (aTokens[currency].balanceOf(address(this)) * 1e18) / totalATokenShares[currency];
    }

    /// @notice Deposit to aave pool
    function _depositToAave(uint256 share, Currency currency) internal {
        totalATokenShares[currency] += share;
        aavePool.supply(Currency.unwrap(currency), share, address(this), 0);
    }

    /// @notice Withdraw from aave pool
    function _withdrawFromAave(uint256 share, address to, Currency currency) internal returns (uint256) {
        uint256 amount = (share * _getATokenSharePrice(currency)) / 1e18;
        totalATokenShares[currency] -= share;
        return aavePool.withdraw(Currency.unwrap(currency), amount, to);
    }
}
