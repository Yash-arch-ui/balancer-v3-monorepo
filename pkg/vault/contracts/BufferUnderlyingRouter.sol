// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IBufferUnderlyingRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IBufferUnderlyingRouter.sol";
import { RouterCommon } from "./RouterCommon.sol";

/**
 * @title BufferUnderlyingRouter
 * @notice Router that adds liquidity to ERC4626 buffers from underlying tokens only.
 * @dev The user supplies only the underlying token. The router computes the proportional
 * underlying/wrapped split for `exactSharesToIssue`, wraps the required portion via the
 * ERC4626 token itself, adds liquidity to the buffer, and refunds any dust.
 *
 * Frontrun protection: `exactSharesToIssue` fixes the shares out, and
 * `maxAmountUnderlyingIn` bounds the total underlying spent. If the buffer is manipulated
 * so the operation becomes more expensive, the transaction reverts.
 */

contract BufferUnderlyingRouter is IBufferUnderlyingRouter, RouterCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    struct SplitResult {
        uint256 underlyingIn;
        uint256 wrappedIn;
        uint256 underlyingForWrap;
        uint256 totalUnderlyingNeeded;
    }

    struct SettleResult {
        uint256 mintedWrapped;
        uint256 assetsUsedForWrap;
        uint256 actualUnderlyingIn;
        uint256 actualWrappedIn;
    }

    /// @notice The total underlying required exceeds the caller's `maxAmountUnderlyingIn`.
    error UnderlyingAmountInAboveMax(uint256 amountNeeded, uint256 maxAmountUnderlyingIn);
    /// @notice `exactSharesToIssue` was zero — nothing to do, and downstream token transfers
    /// may behave inconsistently (revert vs silent no-op) for zero-value transfers.
    error ZeroSharesToIssue();

    constructor(
        IVault vault,
        IWETH weth,
        IPermit2 permit2,
        string memory routerVersion
    ) RouterCommon(vault, weth, permit2, routerVersion) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /*******************************************************************************
                                External entrypoints
    *******************************************************************************/

    /// @inheritdoc IBufferUnderlyingRouter
    function addLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue,
        uint256 deadline
    )
        external
        saveSender(msg.sender)
        returns (uint256 amountUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares)
    {
        // Fail fast before unlocking the Vault.
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) {
            revert SwapDeadline();
        }

        return
            abi.decode(
                _vault.unlock(
                    abi.encodeCall(
                        BufferUnderlyingRouter.addLiquidityUnderlyingToBufferHook,
                        (wrappedToken, maxAmountUnderlyingIn, exactSharesToIssue, msg.sender)
                    )
                ),
                (uint256, uint256, uint256)
            );
    }

    /// @inheritdoc IBufferUnderlyingRouter
    function queryAddLiquidityUnderlyingToBuffer(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue
    )
        external
        saveSender(msg.sender)
        returns (uint256 amountUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares)
    {
        return
            abi.decode(
                _vault.quote(
                    abi.encodeCall(
                        BufferUnderlyingRouter.queryAddLiquidityUnderlyingToBufferHook,
                        (wrappedToken, maxAmountUnderlyingIn, exactSharesToIssue)
                    )
                ),
                (uint256, uint256, uint256)
            );
    }

    /*******************************************************************************
                                    Vault hooks
    *******************************************************************************/
    /**
     * @notice Hook for adding liquidity to a buffer from underlying only. Can only be called by the Vault.
     * @dev Runs inside the Vault's unlocked context (msg.sender is the Vault; this router is the locker).
     *
     * Flow: pull underlying from the user -> wrap the proportional amount into the wrapped
     * token -> deposit both into the buffer for exact shares -> settle debts with the Vault ->
     * refund any dust (on both the underlying and wrapped legs) back to the user.
     *
     * @param wrappedToken The ERC4626 wrapped token whose buffer receives liquidity
     * @param maxAmountUnderlyingIn Cap on total underlying spent (proportional part + wrap cost)
     * @param exactSharesToIssue Exact buffer shares to mint to `sharesOwner`
     * @param sharesOwner The original `msg.sender` of the entrypoint; pays tokens, receives shares
     * @return amountUnderlyingIn Actual underlying deposited into the buffer
     * @return amountWrappedIn Actual wrapped tokens deposited into the buffer
     * @return issuedShares Buffer shares issued (equals `exactSharesToIssue`)
     */
    function addLiquidityUnderlyingToBufferHook(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue,
        address sharesOwner
    )
        external
        nonReentrant
        onlyVault
        returns (uint256 amountUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares)
    {
        if (exactSharesToIssue == 0) {
            revert ZeroSharesToIssue();
        }
        IERC20 underlyingToken = IERC20(wrappedToken.asset());

        // Compute the proportional underlying/wrapped split for `exactSharesToIssue`, mirroring
        // the Vault's own math (rounded up, in the Vault's favor). `split` is grouped into a
        // struct to reduce local variable count and avoid a "stack too deep" compiler error.
        SplitResult memory split;
        (split.underlyingIn, split.wrappedIn, split.underlyingForWrap) = _computeSplit(
            wrappedToken,
            exactSharesToIssue
        );
        split.totalUnderlyingNeeded = split.underlyingIn + split.underlyingForWrap;

        // Frontrun / slippage guard: revert if the buffer has moved enough that the true cost
        // now exceeds what the caller is willing to pay.
        if (split.totalUnderlyingNeeded > maxAmountUnderlyingIn) {
            revert UnderlyingAmountInAboveMax(split.totalUnderlyingNeeded, maxAmountUnderlyingIn);
        }

        // Pull the full underlying amount from the user into THIS ROUTER (not the Vault).
        // Physical custody is required here because the wrap step below spends part of these
        // funds via an external call to the wrapped token; `_takeTokenIn` cannot be used since
        // it forwards funds directly to the Vault and settles immediately, leaving the router
        // with nothing to fund the mint.
        _permit2.transferFrom(
            sharesOwner,
            address(this),
            split.totalUnderlyingNeeded.toUint160(),
            address(underlyingToken)
        );

        // Wrap: mint exactly `split.wrappedIn` wrapped tokens. ERC4626 `mint` returns the actual
        // assets consumed, which is guaranteed <= `previewMint` per EIP-4626. Results are grouped
        // into `settle` for the same stack-depth reason as `split` above.
        SettleResult memory settle;
        settle.mintedWrapped = split.wrappedIn;

        underlyingToken.forceApprove(address(wrappedToken), split.underlyingForWrap);
        settle.assetsUsedForWrap = wrappedToken.mint(settle.mintedWrapped, address(this));
        underlyingToken.forceApprove(address(wrappedToken), 0);

        // Add liquidity to the buffer. The Vault mints `exactSharesToIssue` shares to `sharesOwner`
        // and reports the ACTUAL underlying/wrapped amounts consumed, which are bounded above by
        // the maxes passed in (`split.underlyingIn`, `settle.mintedWrapped`) but may be lower if
        // the buffer ratio shifted between `_computeSplit` and this call.
        (settle.actualUnderlyingIn, settle.actualWrappedIn) = _vault.addLiquidityToBuffer(
            wrappedToken,
            split.underlyingIn,
            settle.mintedWrapped,
            exactSharesToIssue,
            sharesOwner
        );
        issuedShares = exactSharesToIssue;

        // Settle both debts with the Vault. Tokens move router -> Vault here, so a manual
        // safeTransfer + settle() pair is the correct pattern (as opposed to `_takeTokenIn`,
        // which is only for pulling funds directly from an external user).
        underlyingToken.safeTransfer(address(_vault), settle.actualUnderlyingIn);
        _vault.settle(underlyingToken, settle.actualUnderlyingIn);

        IERC20(address(wrappedToken)).safeTransfer(address(_vault), settle.actualWrappedIn);
        _vault.settle(IERC20(address(wrappedToken)), settle.actualWrappedIn);

        // Refund dust to the user on both legs:
        //  - Underlying dust: what was pulled, minus what was sent to the Vault, minus what was
        //    spent wrapping.
        //  - Wrapped dust: what was minted, minus what was actually consumed by the Vault.
        // Both refunds transfer directly from the router's own balance (not via `_sendTokenOut`,
        // which draws from the Vault's reserves and is not applicable to router-held dust).
        uint256 underlyingRefund = split.totalUnderlyingNeeded - settle.actualUnderlyingIn - settle.assetsUsedForWrap;
        if (underlyingRefund > 0) {
            underlyingToken.safeTransfer(sharesOwner, underlyingRefund);
        }
        // Refund dust to the user. NOTE: `wrappedRefund` is defensive/theoretical under the
        // current single-transaction architecture — `actualWrappedIn` returned by the Vault
        // will always equal `mintedWrapped` exactly, since nothing can shift the buffer's
        // underlying/wrapped ratio between `_computeSplit` and this call within one atomic
        // transaction. This branch exists for correctness/future-proofing (e.g. if the Vault's
        // internal accounting logic ever changes), not because it's reachable today.

        uint256 wrappedRefund = settle.mintedWrapped - settle.actualWrappedIn;
        if (wrappedRefund > 0) {
            IERC20(address(wrappedToken)).safeTransfer(sharesOwner, wrappedRefund);
        }

        // Return TOTAL underlying spent (buffer deposit + wrap cost), not just the
        // buffer-deposit portion — this is the number callers actually need to reconcile
        // their real spend/slippage against.
        amountUnderlyingIn = settle.actualUnderlyingIn + settle.assetsUsedForWrap;
        amountWrappedIn = settle.actualWrappedIn;
    }

    /**
     * @notice Query hook, meant to be called only off-chain via `quote` (static call context).
     * @dev Performs the same math and Vault operation as the mutating hook, but takes no
     * tokens and settles nothing (query mode skips settlement checks).
     */
    function queryAddLiquidityUnderlyingToBufferHook(
        IERC4626 wrappedToken,
        uint256 maxAmountUnderlyingIn,
        uint256 exactSharesToIssue
    ) external onlyVault returns (uint256 amountUnderlyingIn, uint256 amountWrappedIn, uint256 issuedShares) {
        if (exactSharesToIssue == 0) {
            revert ZeroSharesToIssue();
        }

        uint256 underlyingForWrap;
        uint256 underlyingIn;
        (underlyingIn, amountWrappedIn, underlyingForWrap) = _computeSplit(wrappedToken, exactSharesToIssue);

        uint256 totalUnderlyingNeeded = underlyingIn + underlyingForWrap;
        if (totalUnderlyingNeeded > maxAmountUnderlyingIn) {
            revert UnderlyingAmountInAboveMax(totalUnderlyingNeeded, maxAmountUnderlyingIn);
        }

        (uint256 actualUnderlyingIn, uint256 actualWrappedIn) = _vault.addLiquidityToBuffer(
            wrappedToken,
            underlyingIn,
            amountWrappedIn,
            exactSharesToIssue,
            address(this)
        );
        issuedShares = exactSharesToIssue;

        // NOTE: unlike the mutating hook (which uses `assetsUsedForWrap`, the actual assets
        // consumed by mint()), this query uses `underlyingForWrap` (previewMint's quote),
        // since no real mint occurs here. previewMint rounds up per EIP-4626, so this query
        // may slightly OVERESTIMATE total spend vs. the real transaction — the safe direction
        // for a slippage preview, but worth knowing if reconciling exact numbers against a
        // real call to addLiquidityUnderlyingToBuffer.
        amountUnderlyingIn = actualUnderlyingIn + underlyingForWrap;
        amountWrappedIn = actualWrappedIn;
    }

    /*******************************************************************************
                                    Internal
    *******************************************************************************/

    /**
     * @dev Computes the proportional underlying/wrapped amounts for `exactSharesToIssue`,
     * plus the underlying required to mint the wrapped portion.
     * Rounds up to mirror the Vault's `addLiquidityToBuffer` math.
     */
    function _computeSplit(
        IERC4626 wrappedToken,
        uint256 exactSharesToIssue
    ) internal view returns (uint256 amountUnderlyingIn, uint256 amountWrappedIn, uint256 underlyingForWrap) {
        uint256 totalShares = _vault.getBufferTotalShares(wrappedToken);
        if (totalShares == 0) {
            revert IVaultErrors.BufferNotInitialized(wrappedToken);
        }

        (uint256 bufferUnderlying, uint256 bufferWrapped) = _vault.getBufferBalance(wrappedToken);

        amountUnderlyingIn = bufferUnderlying.mulDiv(exactSharesToIssue, totalShares, Math.Rounding.Ceil);
        amountWrappedIn = bufferWrapped.mulDiv(exactSharesToIssue, totalShares, Math.Rounding.Ceil);

        // Underlying needed to mint exactly `amountWrappedIn` (previewMint rounds up per EIP-4626).
        underlyingForWrap = wrappedToken.previewMint(amountWrappedIn);
    }
}
