// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAavePool {
    function supply(address token, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address token, uint256 amount, address to) external returns (uint256);
}
