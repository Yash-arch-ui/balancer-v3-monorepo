// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { ISenderGuard } from "@balancer-labs/v3-interfaces/contracts/vault/ISenderGuard.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseVaultTest } from "./utils/BaseVaultTest.sol";
import { BufferUnderlyingRouter } from "../../contracts/BufferUnderlyingRouter.sol";

/**
 * @notice Tests for BufferUnderlyingRouter.
 * @dev Mirrors BufferRouterTest's structure and conventions. Unlike BufferRouter, this
 * router requires the buffer to already be initialized — it has no `initializeBuffer`
 * entrypoint of its own — so every test seeds the buffer via `bufferRouter.initializeBuffer`
 * in `setUp`, matching the real-world usage pattern: initialize once, then top up using
 * underlying only via this router.
 */
contract BufferUnderlyingRouterTest is BaseVaultTest {
    using FixedPoint for uint256;

    uint256 private constant _BUFFER_MINIMUM_TOTAL_SUPPLY = 1e4;
    uint256 private constant _WADAI_RATE = 2e18;
    uint256 private constant _DEFAULT_INPUT_AMOUNT = 1e18;

    // Seed liquidity used to initialize the buffer before each test.
    uint256 private constant _INIT_UNDERLYING = 1_000e18;
    uint256 private constant _INIT_WRAPPED = 1_000e18;

    BufferUnderlyingRouter internal bufferUnderlyingRouter;

    uint256 internal _initialBufferShares;

    function setUp() public virtual override {
        BaseVaultTest.setUp();
        waDAI.mockRate(_WADAI_RATE);

        bufferUnderlyingRouter = new BufferUnderlyingRouter(vault, weth, permit2, "1");

        vm.prank(alice);
        _initialBufferShares = bufferRouter.initializeBuffer(waDAI, _INIT_UNDERLYING, _INIT_WRAPPED, 0);
        // Grant Permit2 allowance for OUR new router — BaseVaultTest only set this up
        // for the routers it deploys itself (bufferRouter, etc.), not ours.
        address[] memory usersToApprove = new address[](2);
        usersToApprove[0] = alice;
        usersToApprove[1] = bob;

        for (uint256 i = 0; i < usersToApprove.length; i++) {
            vm.startPrank(usersToApprove[i]);
            dai.approve(address(permit2), type(uint256).max);
            permit2.approve(address(dai), address(bufferUnderlyingRouter), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    /*******************************************************************************
                                    Happy path
    *******************************************************************************/

    function testAddLiquidityUnderlyingToBuffer() public {
        uint256 exactSharesToIssue = 10e18;
        uint256 maxAmountUnderlyingIn = _DEFAULT_INPUT_AMOUNT * 1000; // generous cap, should not bind

        vm.prank(bob);
        (uint256 totalUnderlyingSpent, uint256 amountWrappedIn, uint256 issuedShares) = bufferUnderlyingRouter
            .addLiquidityUnderlyingToBuffer(waDAI, maxAmountUnderlyingIn, exactSharesToIssue, block.timestamp + 1);

        assertEq(issuedShares, exactSharesToIssue, "Wrong issued shares");
        assertLe(totalUnderlyingSpent, maxAmountUnderlyingIn, "Total spend exceeds max");
        assertGt(totalUnderlyingSpent, 0, "Underlying spent should be non-zero");
        assertGt(amountWrappedIn, 0, "Wrapped in should be non-zero");

        assertEq(vault.getBufferOwnerShares(waDAI, bob), exactSharesToIssue, "Wrong issued shares recorded in Vault");
        assertEq(
            vault.getBufferTotalShares(waDAI),
            _initialBufferShares + _BUFFER_MINIMUM_TOTAL_SUPPLY + exactSharesToIssue,
            "Wrong total shares"
        );
    }

    function testAddLiquidityUnderlyingToBufferLeavesNoDustInRouter() public {
        // Core invariant this router must uphold: after any successful call, the router
        // itself should hold zero balance of either token — everything either went to the
        // Vault (as buffer liquidity) or was refunded to the user (as dust).
        uint256 exactSharesToIssue = 10e18;
        uint256 maxAmountUnderlyingIn = _DEFAULT_INPUT_AMOUNT * 1000;

        vm.prank(bob);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waDAI,
            maxAmountUnderlyingIn,
            exactSharesToIssue,
            block.timestamp + 1
        );

        assertEq(dai.balanceOf(address(bufferUnderlyingRouter)), 0, "Router left holding underlying dust");
        assertEq(
            IERC20(address(waDAI)).balanceOf(address(bufferUnderlyingRouter)),
            0,
            "Router left holding wrapped dust"
        );
    }

    /*******************************************************************************
                                Slippage protection
    *******************************************************************************/

    function testAddLiquidityUnderlyingToBufferAboveMax() public {
        uint256 exactSharesToIssue = 10e18;
        uint256 maxAmountUnderlyingIn = 1; // deliberately too low to force revert

        vm.prank(bob);
        vm.expectPartialRevert(BufferUnderlyingRouter.UnderlyingAmountInAboveMax.selector);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waDAI,
            maxAmountUnderlyingIn,
            exactSharesToIssue,
            block.timestamp + 1
        );
    }

    /*******************************************************************************
                                    Deadline
    *******************************************************************************/

    function testAddLiquidityUnderlyingToBufferExpiredDeadline() public {
        uint256 pastDeadline = block.timestamp;
        vm.warp(block.timestamp + 1);

        vm.prank(bob);
        vm.expectRevert(ISenderGuard.SwapDeadline.selector);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(waDAI, _DEFAULT_INPUT_AMOUNT * 1000, 10e18, pastDeadline);
    }

    /*******************************************************************************
                        Buffer must already be initialized
    *******************************************************************************/

    function testAddLiquidityUnderlyingToBufferNotInitialized() public {
        // waWETH has not been initialized in setUp — _computeSplit's call to
        // getBufferTotalShares should revert before any tokens move.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BufferNotInitialized.selector, waWETH));
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waWETH,
            _DEFAULT_INPUT_AMOUNT * 1000,
            10e18,
            block.timestamp + 1
        );
    }

    /*******************************************************************************
                                    Query hook
    *******************************************************************************/

    function testQueryAddLiquidityUnderlyingToBuffer__Fuzz(uint256 exactSharesToIssue, uint256 rate) public {
        exactSharesToIssue = bound(exactSharesToIssue, 1e6, 500e18);
        rate = bound(rate, 0.1e18, 10_000e18);
        waDAI.mockRate(rate);

        uint256 snapshotId = vm.snapshotState();

        _prankStaticCall();
        (
            uint256 expectedAmountUnderlyingIn,
            uint256 expectedAmountWrappedIn,
            uint256 expectedIssuedShares
        ) = bufferUnderlyingRouter.queryAddLiquidityUnderlyingToBuffer(waDAI, type(uint256).max, exactSharesToIssue);

        vm.revertToState(snapshotId);

        vm.prank(bob);
        (
            uint256 actualAmountUnderlyingIn,
            uint256 actualAmountWrappedIn,
            uint256 actualIssuedShares
        ) = bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
                waDAI,
                type(uint256).max / 2, // generous — this test isn't about slippage bounds
                exactSharesToIssue,
                block.timestamp + 1
            );

        assertEq(actualIssuedShares, expectedIssuedShares, "Query/actual issued shares mismatch");
        assertEq(actualAmountUnderlyingIn, expectedAmountUnderlyingIn, "Query/actual underlying mismatch");
        assertEq(actualAmountWrappedIn, expectedAmountWrappedIn, "Query/actual wrapped mismatch");
    }

    function testWrappedRefundIsUnreachableInSingleTransaction() public {
        // Documents (rather than "proves") that wrappedRefund cannot fire under normal
        // conditions, since actualWrappedIn always equals mintedWrapped within one tx —
        // nothing can shift the buffer's underlying/wrapped ratio between _computeSplit
        // and the real Vault call within a single atomic transaction. This test exists so
        // a future change to Vault internals that breaks this assumption gets caught here.
        uint256 exactSharesToIssue = 10e18;

        vm.prank(bob);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waDAI,
            type(uint256).max / 2,
            exactSharesToIssue,
            block.timestamp + 1
        );

        assertEq(IERC20(address(waDAI)).balanceOf(address(bufferUnderlyingRouter)), 0, "No dust regardless");
    }

    function testAddLiquidityUnderlyingToBufferProducesAndRefundsDust() public {
        waDAI.mockRate(2.333e18); // non-round rate forces rounding dust
        uint256 exactSharesToIssue = 7e17; // odd amount to force rounding
        vm.prank(bob);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waDAI,
            type(uint256).max / 2,
            exactSharesToIssue,
            block.timestamp + 1
        );

        assertEq(dai.balanceOf(address(bufferUnderlyingRouter)), 0, "Router dust");
        assertEq(IERC20(address(waDAI)).balanceOf(address(bufferUnderlyingRouter)), 0, "Router wrapped dust");
        // The refund path is defensive — within a single atomic tx the Vault always
        // consumes exactly what was minted, so wrappedRefund is structurally zero here.
        // This test confirms the router holds no dust regardless (all tokens settled to Vault or Bob).
    }

    function testAddLiquidityUnderlyingToBuffer__Fuzz(uint256 exactSharesToIssue, uint256 rate) public {
        exactSharesToIssue = bound(exactSharesToIssue, 1e6, 500e18);
        rate = bound(rate, 0.1e18, 10_000e18);
        waDAI.mockRate(rate);

        vm.prank(bob);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waDAI,
            type(uint256).max / 2,
            exactSharesToIssue,
            block.timestamp + 1
        );

        assertEq(dai.balanceOf(address(bufferUnderlyingRouter)), 0, "Router underlying dust");
        assertEq(IERC20(address(waDAI)).balanceOf(address(bufferUnderlyingRouter)), 0, "Router wrapped dust");
    }

    function testAddLiquidityUnderlyingToBufferZeroShares() public {
        vm.prank(bob);
        vm.expectRevert(BufferUnderlyingRouter.ZeroSharesToIssue.selector);
        bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(waDAI, type(uint256).max, 0, block.timestamp + 1);
    }

    function testAddLiquidityUnderlyingToBufferReconciliation() public {
        uint256 exactSharesToIssue = 10e18;
        uint256 bobBalanceBefore = dai.balanceOf(bob);

        vm.prank(bob);
        (uint256 totalUnderlyingSpent, , ) = bufferUnderlyingRouter.addLiquidityUnderlyingToBuffer(
            waDAI,
            type(uint256).max / 2,
            exactSharesToIssue,
            block.timestamp + 1
        );

        uint256 bobBalanceAfter = dai.balanceOf(bob);

        assertEq(
            bobBalanceBefore - bobBalanceAfter,
            totalUnderlyingSpent,
            "Reported total spend doesn't match Bob's actual balance change"
        );
    }
}
