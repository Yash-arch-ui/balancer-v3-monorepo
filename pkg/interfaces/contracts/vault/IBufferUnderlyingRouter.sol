// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IBufferUnderlyingRouter
/// @notice Router interface for adding liquidity to ERC4626 buffers using only the underlying token.
/// @dev The caller specifies an exact number of buffer shares to mint and a ceiling on the underlying
/// they are willing to spend. The router keeps part of the underlying, wraps the remainder into the
/// wrapped token, and adds both sides to the buffer proportionally.
interface IBufferUnderlyingRouter {
    /// @notice Add liquidity to an ERC4626 buffer by supplying only the underlying token.
    /// @dev The router splits the underlying: part is deposited directly, the rest is wrapped via the
    /// ERC4626 token and then deposited. Shares are minted exactly (`exactSharesToIssue`); slippage /
    /// frontrun protection is enforced by `maxAmountUnderlyingIn`, so the call reverts if the total
    /// underlying required (direct deposit + wrap cost) exceeds that cap. Any leftover underlying or
    /// wrapped dust is refunded to the caller. Reverts if `exactSharesToIssue` is zero or the buffer
    /// is not initialized.
    /// @param wrappedToken The ERC4626 wrapped token whose buffer receives liquidity
    /// @param maxAmountUnderlyingIn Maximum total underlying the caller is willing to spend (slippage cap)
    /// @param exactSharesToIssue Exact number of buffer shares to mint to the caller
    /// @param deadline Block timestamp after which the transaction reverts
    /// @return totalUnderlyingIn Total underlying spent (direct buffer deposit plus the cost of wrapping)
    /// @return amountWrappedIn Wrapped tokens deposited into the buffer
    /// @return issuedShares Buffer shares minted to the caller (equal to `exactSharesToIssue`)
    function addLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue,
        uint256 deadline
    ) external returns (uint256 totalUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares);

    /// @notice Query (off-chain simulation) for `addLiquidityUnderlyingToBuffer`.
    /// @dev Mirrors the mutating function minus `deadline` and does not modify state. The estimate may
    /// slightly overstate `totalUnderlyingIn` versus execution, because it prices the wrap using
    /// `previewMint` (rounded up) rather than the exact assets consumed by the actual mint.
    /// @param wrappedToken The ERC4626 wrapped token whose buffer is queried
    /// @param maxAmountUnderlyingIn Maximum total underlying to simulate spending (slippage cap)
    /// @param exactSharesToIssue Exact number of buffer shares to simulate minting
    /// @return totalUnderlyingIn Estimated total underlying that would be consumed (deposit plus wrap cost)
    /// @return amountWrappedIn Estimated wrapped tokens that would be deposited into the buffer
    /// @return issuedShares Buffer shares that would be minted (equal to `exactSharesToIssue`)
    function queryAddLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue
    ) external returns (uint256 totalUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares);
}
