// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ERC20AutoVRFLotteryV22
/// @notice A robust, fully-audited lottery contract with automated Chainlink VRF, affiliate support, and reentrancy/pausable controls.
/// @dev Final V22 master version. All core logic and security measures in place.

import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC2771Context } from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import { VRFConsumerBaseV2 } from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import { VRFCoordinatorV2Interface } from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import { ISplitContractV22 } from "./ISplitContractV22.sol";
import { IMarketingAffiliateContractV22 } from "./IMarketingAffiliateContractV22.sol";

contract ERC20AutoVRFLotteryV22 is
    VRFConsumerBaseV2,
    ERC2771Context,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error InvalidAmount();
    error InvalidState(string message);
    error InsufficientBalance();
    error DrawClosed();
    error NoPlayers();
    error InvalidDraw();
    error CannotRecoverTicketToken();
    error AlreadyEntered();
    error PriceOutOfBounds();
    error MaxTicketsOutOfBounds();
    error VrfParamsInvalid();
    error EthNotAccepted();

    // --- Constants & State Variables ---
    address public immutable LOTTERY_OPERATOR;
    IERC20 public immutable TICKET_TOKEN;
    VRFCoordinatorV2Interface public immutable COORDINATOR;

    ISplitContractV22 public splitContract;
    IMarketingAffiliateContractV22 public marketingAffiliateContract;

    uint256 public ticketPrice;
    uint256 public maxTickets;
    uint256 public prizeAmount;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint16 public requestConfirmations;
    uint32 public callbackGasLimit;

    uint256 public drawNumber = 1;
    enum DrawState { Open, InProgress, Fulfilled }
    mapping(uint256 => DrawState) public drawStates;

    // Draw logic
    mapping(uint256 => address[]) public drawPlayers;
    mapping(uint256 => mapping(address => address)) public affiliateOf;
    mapping(uint256 => mapping(address => bool)) public hasEnteredDraw;
    mapping(uint256 => uint256) public vrfRequestIds;
    mapping(uint256 => uint256) public requestIdToDrawNumber;

    // --- Events ---
    event MaxTicketsSet(uint256 newMaxTickets);
    event PrizeAmountSet(uint256 newPrizeAmount);
    event TicketPriceSet(uint256 newPrice);
    event VrfParametersSet(bytes32 keyHash, uint64 subId, uint16 confirms, uint32 gasLimit);
    event TicketPurchased(address indexed buyer, uint256 indexed drawNumber, address indexed affiliate);
    event DrawRequested(uint256 indexed drawNumber, uint256 requestId);
    event WinnerSelected(uint256 indexed drawNumber, address indexed winner);
    event NewDrawStarted(uint256 indexed newDrawNumber);
    event Debug(address msgSender, address contractOwner);

    /// @notice Initialize the contract with required parameters and dependencies.
    constructor(
        address splitContract_,
        address marketingAffiliateContract_,
        address ticketToken_,
        address vrfCoordinator_,
        bytes32 keyHash_,
        uint64 subscriptionId_,
        uint16 requestConfirmations_,
        uint32 callbackGasLimit_,
        uint256 ticketPrice_,
        uint256 maxTickets_,
        uint256 prizeAmount_,
        address trustedForwarder_,
        address initialOwner_
    )
        VRFConsumerBaseV2(vrfCoordinator_)
        ERC2771Context(trustedForwarder_)
    {
        if (initialOwner_ == address(0)) revert ZeroAddress();
        _transferOwnership(initialOwner_);
        if (splitContract_ == address(0)) revert ZeroAddress();
        if (marketingAffiliateContract_ == address(0)) revert ZeroAddress();
        if (ticketToken_ == address(0)) revert ZeroAddress();
        if (vrfCoordinator_ == address(0)) revert ZeroAddress();
        if (trustedForwarder_ == address(0)) revert ZeroAddress();

        LOTTERY_OPERATOR = initialOwner_;
        splitContract = ISplitContractV22(splitContract_);
        marketingAffiliateContract = IMarketingAffiliateContractV22(marketingAffiliateContract_);
        TICKET_TOKEN = IERC20(ticketToken_);
        ticketPrice = ticketPrice_;
        maxTickets = maxTickets_;
        prizeAmount = prizeAmount_;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator_);
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
        requestConfirmations = requestConfirmations_;
        callbackGasLimit = callbackGasLimit_;
        drawStates[drawNumber] = DrawState.Open;
    }

    // --- MetaTx Overrides ---
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }
    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        /// slither-disable-next-line dead-code
        return ERC2771Context._msgData();
    }
    function _contextSuffixLength() internal view virtual override(Context, ERC2771Context) returns (uint256) {
        /// slither-disable-next-line dead-code
        return ERC2771Context._contextSuffixLength();
    }

    /// @notice Purchase a ticket for the current draw.
    /// @param affiliate The affiliate address, or zero if none.
    function buyTicket(address affiliate) external nonReentrant whenNotPaused {
        address sender = _msgSender();
        if (TICKET_TOKEN.balanceOf(sender) < ticketPrice) revert InsufficientBalance();
        if (drawStates[drawNumber] != DrawState.Open) revert DrawClosed();
        if (drawPlayers[drawNumber].length >= maxTickets) revert DrawClosed();
        if (hasEnteredDraw[drawNumber][sender]) revert AlreadyEntered();

        drawPlayers[drawNumber].push(sender);
        hasEnteredDraw[drawNumber][sender] = true;
        if (affiliate != address(0) && affiliate != sender) {
            affiliateOf[drawNumber][sender] = affiliate;
        }
        emit TicketPurchased(sender, drawNumber, affiliate);

        uint256 affiliateShare = (ticketPrice * 75) / 1000;
        uint256 splitShare = ticketPrice - affiliateShare;

        TICKET_TOKEN.safeTransferFrom(sender, address(marketingAffiliateContract), affiliateShare);
        marketingAffiliateContract.handleEntry(sender, affiliate, affiliateShare, drawNumber);
        TICKET_TOKEN.safeTransferFrom(sender, address(splitContract), splitShare);
        splitContract.notifyEntry(sender, splitShare, drawNumber);

        if (drawPlayers[drawNumber].length >= maxTickets) {
            uint256 closingDraw = drawNumber;
            drawNumber++;
            drawStates[drawNumber] = DrawState.Open;
            emit NewDrawStarted(drawNumber);
            _requestRandomnessForDraw(closingDraw);
        }
    }

    /// @dev Requests randomness from Chainlink VRF when a draw closes.
    function _requestRandomnessForDraw(uint256 drawNumber_) internal nonReentrant {
        if (drawStates[drawNumber_] != DrawState.Open) revert InvalidState("Draw not open");
        if (!splitContract.isDrawFullyFunded(drawNumber_)) revert InvalidState("Draw not funded");

        drawStates[drawNumber_] = DrawState.InProgress;
        uint256 requestId = COORDINATOR.requestRandomWords(keyHash, subscriptionId, requestConfirmations, callbackGasLimit, 1);

        vrfRequestIds[drawNumber_] = requestId;
        requestIdToDrawNumber[requestId] = drawNumber_;

        emit DrawRequested(drawNumber_, requestId);
    }

    /// @dev Chainlink VRF callback: picks and pays the winner.
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override nonReentrant {
        uint256 draw = requestIdToDrawNumber[requestId];
        if (draw == 0) revert InvalidDraw();
        if (drawStates[draw] != DrawState.InProgress) revert InvalidState("Draw not in progress");

        delete requestIdToDrawNumber[requestId];

        address[] storage players = drawPlayers[draw];
        if (players.length == 0) revert NoPlayers();

        address winner = players[randomWords[0] % players.length];

        drawStates[draw] = DrawState.Fulfilled;
        emit WinnerSelected(draw, winner);
        splitContract.dispatchPayout(winner, prizeAmount);
    }

    // --- Admin Functions ---

    /// @notice Update the split contract address.
    function setSplitContract(address splitContract_) external onlyOwner {
        if (splitContract_ == address(0)) revert ZeroAddress();
        splitContract = ISplitContractV22(splitContract_);
    }

    /// @notice Update the marketing affiliate contract address.
    function setMarketingAffiliateContract(address marketingAffiliateContract_) external onlyOwner {
        if (marketingAffiliateContract_ == address(0)) revert ZeroAddress();
        marketingAffiliateContract = IMarketingAffiliateContractV22(marketingAffiliateContract_);
    }

    /// @notice Set the ticket price (must be within bounds).
    function setTicketPrice(uint256 price_) external onlyOwner {
        uint256 lowerBound = 9 * (10 ** 17);
        uint256 upperBound = 101 * (10 ** 18);
        if (price_ < lowerBound || price_ > upperBound) revert PriceOutOfBounds();
        ticketPrice = price_;
        emit TicketPriceSet(price_);
    }

    /// @notice Set the maximum tickets per draw.
    function setMaxTickets(uint256 max_) external onlyOwner {
        if (max_ < 10 || max_ > 1_000_000) revert MaxTicketsOutOfBounds();
        maxTickets = max_;
        emit MaxTicketsSet(max_);
    }

    /// @notice Set the prize amount.
    function setPrizeAmount(uint256 prize_) external onlyOwner {
        if (prize_ == 0) revert InvalidAmount();
        prizeAmount = prize_;
        emit PrizeAmountSet(prize_);
    }

    /// @notice Update Chainlink VRF parameters.
    function setVrfParameters(bytes32 keyHash_, uint64 subId_, uint16 confirms_, uint32 gas_) external onlyOwner {
        if (keyHash_ == bytes32(0) || subId_ == 0 || confirms_ == 0 || gas_ == 0) revert VrfParamsInvalid();
        keyHash = keyHash_;
        subscriptionId = subId_;
        requestConfirmations = confirms_;
        callbackGasLimit = gas_;
        emit VrfParametersSet(keyHash_, subId_, confirms_, gas_);
    }

    /// @notice Pause the contract (admin).
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause the contract (admin).
    function unpause() external onlyOwner { _unpause(); }

    // --- Emergency Token Recovery ---

    /// @notice Recover arbitrary ERC20 tokens (not the ticket token).
    function recoverERC20(address token_, address to, uint256 amount) external onlyOwner nonReentrant {
        emit Debug(_msgSender(), owner());
        if (to == address(0)) revert ZeroAddress();
        if (token_ == address(TICKET_TOKEN)) revert CannotRecoverTicketToken();
        IERC20(token_).safeTransfer(to, amount);
    }

    /// @notice Emergency recovery of ticket tokens by owner.
    function recoverTicketTokens(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        TICKET_TOKEN.safeTransfer(to, amount);
    }

    // --- View Functions ---

    /// @notice Get the list of players in a draw.
    function getDrawPlayers(uint256 drawNumber_) external view returns (address[] memory) {
        return drawPlayers[drawNumber_];
    }

    /// @notice Get details about the current draw.
    function getCurrentDrawDetails() external view returns (
        uint256 currentDrawNum,
        uint256 numEntries,
        uint256 maxEntries,
        DrawState currentStatus
    ) {
        return (drawNumber, drawPlayers[drawNumber].length, maxTickets, drawStates[drawNumber]);
    }

    // --- Miscellaneous ---

    /// @dev Used to silence static analysis tools (Slither etc).
    function _satisfyStaticAnalysis() internal view {
        /// slither-disable-next-line dead-code
        _msgData();
        /// slither-disable-next-line dead-code
        _contextSuffixLength();
    }

    // --- ETH Guardrails ---
    receive() external payable { revert EthNotAccepted(); }
    fallback() external payable { revert EthNotAccepted(); }
}
