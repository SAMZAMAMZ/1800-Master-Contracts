// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title MarketingAffiliateV22
/// @notice Secure affiliate payout contract for the 1800 lottery platform.
/// @dev Handles affiliate logic, blacklist, whitelist, emergency withdrawal, and owner controls.

import { IMarketingAffiliateContractV22 } from "./IMarketingAffiliateContractV22.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";

contract MarketingAffiliateV22 is
    IMarketingAffiliateContractV22,
    Ownable2Step,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    // --- State Variables ---
    IERC20 public immutable TOKEN;
    address public lotteryContract;

    mapping(address => bool) public blacklistedAffiliates;
    mapping(address => bool) public isApprovedAffiliate;

    // --- Custom Errors ---
    error ZeroAddress();
    error NotLotteryContract();
    error ZeroAmount();
    error InsufficientBalance();
    error CannotRecoverMainToken();

    // --- Events ---
    event AffiliateApproved(address indexed affiliate);
    event AffiliateBlacklisted(address indexed affiliate, bool blacklisted);
    event AffiliatePaid(address indexed affiliate, address indexed player, uint256 indexed drawNumber, uint256 amount);
    event AffiliateRemoved(address indexed affiliate);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event LotteryContractSet(address indexed newLotteryContract);
    event MarketingFundsWithdrawn(address indexed to, uint256 amount);
    event NomadMarketingFundsReceived(address indexed player, uint256 indexed drawNumber, uint256 amount);

    // --- Modifiers ---
    modifier onlyLottery() {
        if (msg.sender != lotteryContract) revert NotLotteryContract();
        _;
    }

    /// @notice Initialize contract with main token and owner.
    /// @param token_ ERC20 address for affiliate payout.
    /// @param initialOwner_ Contract owner (admin).
    constructor(
        address token_,
        address initialOwner_
    ) {
        if (token_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();
        _transferOwnership(initialOwner_);
        TOKEN = IERC20(token_);
    }

    /// @notice Called by the lottery on each ticket purchase to handle affiliate payout.
    /// @dev Will only pay approved, non-blacklisted affiliates, otherwise logs as nomad funds.
    function handleEntry(
        address player,
        address affiliate,
        uint256 amount,
        uint256 drawNumber
    ) external override nonReentrant onlyLottery whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        if (
            affiliate != address(0) &&
            affiliate != player &&
            !blacklistedAffiliates[affiliate] &&
            isApprovedAffiliate[affiliate]
        ) {
            TOKEN.safeTransfer(affiliate, amount);
            emit AffiliatePaid(affiliate, player, drawNumber, amount);
        } else {
            emit NomadMarketingFundsReceived(player, drawNumber, amount);
        }
    }

    /// @notice Approve or remove an affiliate from whitelist.
    function setAffiliateApproval(address affiliate, bool isApproved) external onlyOwner {
        if (affiliate == address(0)) revert ZeroAddress();
        isApprovedAffiliate[affiliate] = isApproved;
        if (isApproved) {
            emit AffiliateApproved(affiliate);
        } else {
            emit AffiliateRemoved(affiliate);
        }
    }

    /// @notice Set the lottery contract (once only or to update).
    function setLotteryContract(address lotteryContract_) external onlyOwner {
        if (lotteryContract_ == address(0)) revert ZeroAddress();
        lotteryContract = lotteryContract_;
        emit LotteryContractSet(lotteryContract_);
    }

    /// @notice Withdraw marketing funds from contract balance.
    function withdrawMarketingFunds(address to, uint256 amount)
        external onlyOwner nonReentrant whenNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (TOKEN.balanceOf(address(this)) < amount) revert InsufficientBalance();
        TOKEN.safeTransfer(to, amount);
        emit MarketingFundsWithdrawn(to, amount);
    }

    /// @notice Recover arbitrary ERC20 tokens (not the main payout token).
    function recoverERC20(address token_, address to, uint256 amount)
        external onlyOwner nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token_ == address(TOKEN)) revert CannotRecoverMainToken();
        IERC20(token_).safeTransfer(to, amount);
        emit ERC20Recovered(token_, to, amount);
    }

    /// @notice Blacklist or un-blacklist an affiliate.
    function setAffiliateBlacklist(address affiliate, bool status) external onlyOwner {
        if (affiliate == address(0)) revert ZeroAddress();
        blacklistedAffiliates[affiliate] = status;
        emit AffiliateBlacklisted(affiliate, status);
    }

    /// @notice Pause all affiliate payouts/admin actions.
    function pause() external onlyOwner { _pause(); }

    /// @notice Resume affiliate payouts/admin actions.
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Get contract's current token balance (for transparency).
    function marketingBalance() external view returns (uint256) {
        return TOKEN.balanceOf(address(this));
    }
}
