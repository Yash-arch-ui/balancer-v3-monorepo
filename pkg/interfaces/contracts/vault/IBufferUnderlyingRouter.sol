// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IBufferUnderlyingRouter
/// @notice Router interface for adding liquidity to ERC4626 buffers using underlying tokens,
/// with frontrun (slippage) protection per issue #1267.
interface IBufferUnderlyingRouter {
    /// @notice Add liquidity to an ERC4626 buffer by depositing underlying tokens.
    /// @dev The router wraps the underlying into the wrapped token, then deposits into the buffer.
    /// Reverts if the issued shares fall below `minSharesToIssue` (slippage guard).
    /// Any dust (excess underlying not consumed) is refunded to the caller.
    /// @param wrappedToken The ERC4626 wrapped token whose buffer receives liquidity
    /// @param maxAmountUnderlyingIn The maximum amount of underlying tokens the caller is willing to spend
    /// @param minSharesToIssue The minimum acceptable shares to receive; reverts if fewer are issued
    /// @param sharesOwner The address that will receive the issued buffer shares
    /// @param deadline Block timestamp after which the transaction reverts
    /// @return amountUnderlyingIn The actual amount of underlying tokens consumed
    /// @return issuedShares The number of buffer shares minted to `sharesOwner`
    function addLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 minSharesToIssue,
        address sharesOwner,
        uint256 deadline
    ) external returns (uint256 amountUnderlyingIn, uint256 issuedShares);

    /// @notice Query (off-chain simulation) for `addLiquidityUnderlyingToBuffer`.
    /// @dev Mirrors the mutating function signature minus `deadline`. Does not modify state.
    /// @param wrappedToken The ERC4626 wrapped token whose buffer is queried
    /// @param maxAmountUnderlyingIn The maximum amount of underlying tokens to simulate spending
    /// @param minSharesToIssue The minimum acceptable shares (for revert simulation)
    /// @param sharesOwner The address that would receive the issued buffer shares
    /// @return amountUnderlyingIn The estimated amount of underlying tokens that would be consumed
    /// @return issuedShares The estimated number of buffer shares that would be minted
    function queryAddLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 minSharesToIssue,
        address sharesOwner
    ) external returns (uint256 amountUnderlyingIn, uint256 issuedShares);
}
