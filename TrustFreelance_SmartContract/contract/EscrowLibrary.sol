// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Custom errors for library
error ArrayLengthMismatch();

library EscrowLibrary {
    function calculateFee(uint256 amount, uint256 feePercentage) 
        internal 
        pure 
        returns (uint256 platformFee, uint256 freelancerAmount) 
    {
        platformFee = (amount * feePercentage) / 100;
        freelancerAmount = amount - platformFee;
    }
    
    function validateMilestoneArrays(
        uint256 descriptionsLength,
        uint256 amountsLength,
        uint256 dueDatesLength
    ) internal pure {
        if (descriptionsLength != amountsLength || amountsLength != dueDatesLength) {
            revert ArrayLengthMismatch();
        }
    }
    
    function calculateTotalAmount(uint256[] memory amounts) 
        internal 
        pure 
        returns (uint256 total) 
    {
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
    
    function isValidAddress(address addr) internal pure returns (bool) {
        return addr != address(0);
    }
    
    function isDeadlineValid(uint256 deadline) internal view returns (bool) {
        return deadline > block.timestamp;
    }
}
