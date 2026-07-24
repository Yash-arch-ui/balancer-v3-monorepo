// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Test-only ERC4626 wrapper that deliberately consumes LESS underlying than
 * `previewMint` quotes. Used to genuinely exercise BufferUnderlyingRouter's wrapped-dust
 * refund path, which is unreachable with a well-behaved wrapper (mint always consumes
 * exactly what it quoted, so there's nothing left over to refund).
 */
contract ImperfectERC4626Mock is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public discountBps; // e.g. 500 = 5% under-consumption

    constructor(
        IERC20 underlying,
        string memory name,
        string memory symbol,
        uint256 _discountBps
    ) ERC20(name, symbol) ERC4626(underlying) {
        discountBps = _discountBps;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 quotedAssets = previewMint(shares);
        uint256 actualAssets = quotedAssets - (quotedAssets * discountBps) / 10_000;

        address caller = _msgSender();
        IERC20(asset()).safeTransferFrom(caller, address(this), actualAssets);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, actualAssets, shares);
        return actualAssets;
    }
}
