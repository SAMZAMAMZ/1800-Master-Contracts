// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
ISplitContractV22 

interface ISplitContractV22 {
    function notifyEntry(address player, uint256 amount, uint256 drawNumber) external;
    function dispatchPayout(address winner, uint256 amount) external;
    function isDrawFullyFunded(uint256 drawNumber) external view returns (bool);
}
