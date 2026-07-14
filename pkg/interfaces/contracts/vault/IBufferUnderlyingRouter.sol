// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IBufferUnderlyingRouter
/// @notice Router interface for adding liquidity to ERC4626 buffers using underlying tokens,
/// with frontrun (slippage) protection 
interface IBufferUnderlyingRouter {
    /// @notice Add liquidity to an ERC4626 buffer by depositing underlying tokens.
    /// @dev The router wraps the underlying into the wrapped token, then deposits into the buffer.
    /// Reverts if the issued shares fall below `minSharesToIssue` (slippage guard).
    /// Any dust (excess underlying not consumed) is refunded to the caller.
    /// @param wrappedToken The ERC4626 wrapped token whose buffer receives liquidity
    /// @param maxAmountUnderlyingIn The maximum amount of underlying tokens the caller is willing to spend
    /// @param exactSharesToIssue The  acceptable shares to receive
    function addLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue
    ) external returns (uint256 amountUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares);

    /// @notice Query (off-chain simulation) for `addLiquidityUnderlyingToBuffer`.
    /// @dev Mirrors the mutating function signature minus `deadline`. Does not modify state.
    /// @param wrappedToken The ERC4626 wrapped token whose buffer is queried
    /// @param maxAmountUnderlyingIn The maximum amount of underlying tokens to simulate spending
    /// @param exactSharesToIssue The  acceptable shares to receive
    /// @return amountUnderlyingIn The estimated amount of underlying tokens that would be consumed
    /// @return amountWrappedIn The wrapped amount used
    function queryAddLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue
    ) external returns (uint256 amountUnderlyingIn,uint256 amountWrappedIn, uint256 issuedShares);
}
