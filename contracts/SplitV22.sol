// SPDX-License-Identifier: MIT
pragma solidity 0.8.20; // Pragma locked for security

import { ISplitContractV22 } from "./ISplitContractV22.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// UPDATED: Using Ownable2Step for consistency and safety
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// UPDATED: Inheriting from Ownable2Step
contract SplitV22 is ISplitContractV22, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable TOKEN;
    address public lotteryContract;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public prizeBps;
    uint256 public adminBps;
    uint256 public gasBps;
    uint256 public vrfBps;
    uint256 public overheadBps;

    mapping(uint256 => uint256) public totalReceivedPerDraw;
    uint256 public requiredAmountPerDraw;
    mapping(bytes32 => uint256) public internalBalances;

    // UPDATED: Changed constants to private to save gas
    bytes32 private constant ADMIN = keccak256("admin");
    bytes32 private constant GAS = keccak256("gas");
    bytes32 private constant VRF = keccak256("vrf");
    bytes32 private constant OVERHEAD = keccak256("overhead");

    address public adminWallet;
    address public gasWallet;
    address public vrfWallet;
    address public overheadWallet;

    // ... (Custom Errors and Events are the same) ...
    error ZeroAddress();
    error NotLotteryContract();
    error ZeroAmount();
    error InvalidBps();
    error InvalidShareKey();
    error WalletNotSet();
    error InsufficientInternalBalance();
    error InsufficientContractBalance();
    error CannotRescueMainToken();
    event EntryReceived(address indexed player, uint256 amount, uint256 indexed drawNumber);
    event FundsSplit(uint256 indexed drawNumber, uint256 amountForNonPrizeSplits);
    event WinnerPayout(address indexed winner, uint256 amount);
    event LotteryContractSet(address indexed lotteryContract);
    event ShareFundsWithdrawn(bytes32 indexed share, address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event BpsUpdated(uint256 prizeBps, uint256 adminBps, uint256 gasBps, uint256 vrfBps, uint256 overheadBps);
    event RequiredAmountPerDrawUpdated(uint256 newAmount);
    event WalletUpdated(bytes32 indexed share, address indexed newWallet);
    event PrizeTokensWithdrawn(address indexed to, uint256 amount);

    modifier onlyLottery() {
        if (msg.sender != lotteryContract) revert NotLotteryContract();
        _;
    }

    // Constructor is already correct for Ownable2Step workaround
    constructor(
        address token_,
        uint256 requiredAmountPerDraw_,
        address initialOwner_,
        uint256 prizeBps_,
        uint256 adminBps_,
        uint256 gasBps_,
        uint256 vrfBps_,
        uint256 overheadBps_
    ) {
        if (token_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();
        if (prizeBps_ + adminBps_ + gasBps_ + vrfBps_ + overheadBps_ != BASIS_POINTS) revert InvalidBps();
        
        _transferOwnership(initialOwner_);
        
        TOKEN = IERC20(token_);
        requiredAmountPerDraw = requiredAmountPerDraw_;
        prizeBps = prizeBps_;
        adminBps = adminBps_;
        gasBps = gasBps_;
        vrfBps = vrfBps_;
        overheadBps = overheadBps_;
    }

    // UPDATED: nonReentrant is now the first modifier
    function notifyEntry(address player, uint256 amount, uint256 drawNumber) external override nonReentrant onlyLottery {
        if (amount == 0) revert ZeroAmount();
        totalReceivedPerDraw[drawNumber] += amount;
        emit EntryReceived(player, amount, drawNumber);
        _splitNonPrizeFunds(amount, drawNumber);
    }

    // UPDATED: nonReentrant is now the first modifier
    function dispatchPayout(address winner, uint256 prizeAmountToWinner) external override nonReentrant onlyLottery {
        if (winner == address(0)) revert ZeroAddress();
        if (TOKEN.balanceOf(address(this)) < prizeAmountToWinner) revert InsufficientContractBalance();
        TOKEN.safeTransfer(winner, prizeAmountToWinner);
        emit WinnerPayout(winner, prizeAmountToWinner);
    }
    
    // ... (the rest of the contract is the same) ...
     function _splitNonPrizeFunds(uint256 amount, uint256 drawNumber) internal {
        uint256 adminShare = (amount * adminBps) / BASIS_POINTS;
        uint256 gasShare = (amount * gasBps) / BASIS_POINTS;
        uint256 vrfShare = (amount * vrfBps) / BASIS_POINTS;
        uint256 overheadShare = (amount * overheadBps) / BASIS_POINTS;
        if (adminShare > 0) internalBalances[ADMIN] += adminShare;
        if (gasShare > 0) internalBalances[GAS] += gasShare;
        if (vrfShare > 0) internalBalances[VRF] += vrfShare;
        if (overheadShare > 0) internalBalances[OVERHEAD] += overheadShare;
        emit FundsSplit(drawNumber, adminShare + gasShare + vrfShare + overheadShare);
    }
    function setLotteryContract(address lotteryContract_) external onlyOwner {
        if (lotteryContract_ == address(0)) revert ZeroAddress();
        lotteryContract = lotteryContract_;
        emit LotteryContractSet(lotteryContract_);
    }
    function setWallet(bytes32 share, address wallet) external onlyOwner {
        if (!_isValidShare(share)) revert InvalidShareKey();
        if (wallet == address(0)) revert ZeroAddress();
        if (share == ADMIN) adminWallet = wallet;
        else if (share == GAS) gasWallet = wallet;
        else if (share == VRF) vrfWallet = wallet;
        else if (share == OVERHEAD) overheadWallet = wallet;
        emit WalletUpdated(share, wallet);
    }
    function withdrawShareFunds(bytes32 share, uint256 amount) external onlyOwner nonReentrant {
        if (!_isValidShare(share)) revert InvalidShareKey();
        if (amount == 0) revert ZeroAmount();
        address walletToPay;
        if (share == ADMIN) walletToPay = adminWallet;
        else if (share == GAS) walletToPay = gasWallet;
        else if (share == VRF) walletToPay = vrfWallet;
        else if (share == OVERHEAD) walletToPay = overheadWallet;
        if (walletToPay == address(0)) revert WalletNotSet();
        if (internalBalances[share] < amount) revert InsufficientInternalBalance();
        internalBalances[share] -= amount;
        TOKEN.safeTransfer(walletToPay, amount);
        emit ShareFundsWithdrawn(share, walletToPay, amount);
    }
    function emergencyWithdrawPrizeTokens(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (TOKEN.balanceOf(address(this)) < amount) revert InsufficientContractBalance();
        TOKEN.safeTransfer(to, amount);
        emit PrizeTokensWithdrawn(to, amount);
    }
    function setBps(uint256 prizeBps_, uint256 adminBps_, uint256 gasBps_, uint256 vrfBps_, uint256 overheadBps_) external onlyOwner {
        if (prizeBps_ + adminBps_ + gasBps_ + vrfBps_ + overheadBps_ != BASIS_POINTS) revert InvalidBps();
        prizeBps = prizeBps_;
        adminBps = adminBps_;
        gasBps = gasBps_;
        vrfBps = vrfBps_;
        overheadBps = overheadBps_;
        emit BpsUpdated(prizeBps_, adminBps_, gasBps_, vrfBps_, overheadBps_);
    }
    function setRequiredAmountPerDraw(uint256 requiredAmountPerDraw_) external onlyOwner {
        if (requiredAmountPerDraw_ == 0) revert ZeroAmount();
        requiredAmountPerDraw = requiredAmountPerDraw_;
        emit RequiredAmountPerDrawUpdated(requiredAmountPerDraw_);
    }
    function rescueTokens(address token_, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token_ == address(TOKEN)) revert CannotRescueMainToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token_).safeTransfer(to, amount);
        emit ERC20Rescued(token_, to, amount);
    }
    function _isValidShare(bytes32 share) internal pure returns (bool) {
        return share == ADMIN || share == GAS || share == VRF || share == OVERHEAD;
    }
    function isDrawFullyFunded(uint256 drawNumber) external view override returns (bool) {
        return totalReceivedPerDraw[drawNumber] >= requiredAmountPerDraw;
    }

}
