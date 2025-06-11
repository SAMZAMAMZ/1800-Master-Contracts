// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
IMarketingAffiliateContractV22 

/**
 * @title IMarketingAffiliateContractV22
 * @notice Interface for the MarketingAffiliateV22 contract.
 */
interface IMarketingAffiliateContractV22 {
    /**
     * @notice The function called by the Lottery contract to process an affiliate share.
     */
    function handleEntry(address player, address affiliate, uint256 amount, uint256 drawNumber) external;
}
