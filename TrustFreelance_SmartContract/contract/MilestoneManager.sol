// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Custom errors for MilestoneManager
error InvalidMilestoneIndex();
error MilestoneAlreadyCompleted();
error MilestoneDeadlinePassed();
error MilestoneNotCompleted();
error MilestoneAlreadyApproved();

contract MilestoneManager {
    struct Milestone {
        string description;
        uint256 amount;
        bool completed;
        bool approved;
        uint256 dueDate;
    }
    
    mapping(bytes32 => Milestone[]) public milestones;
    
    event MilestoneCompleted(bytes32 indexed escrowId, uint256 milestoneIndex);
    event MilestoneApproved(bytes32 indexed escrowId, uint256 milestoneIndex);
    
    function addMilestones(
        bytes32 escrowId,
        string[] memory descriptions,
        uint256[] memory amounts,
        uint256[] memory dueDates
    ) external {
        for (uint256 i = 0; i < descriptions.length; i++) {
            milestones[escrowId].push(Milestone({
                description: descriptions[i],
                amount: amounts[i],
                completed: false,
                approved: false,
                dueDate: dueDates[i]
            }));
        }
    }
    
    function completeMilestone(bytes32 escrowId, uint256 milestoneIndex) external {
        if (milestoneIndex >= milestones[escrowId].length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = milestones[escrowId][milestoneIndex];
        if (milestone.completed) revert MilestoneAlreadyCompleted();
        if (block.timestamp > milestone.dueDate) revert MilestoneDeadlinePassed();
        
        milestone.completed = true;
        emit MilestoneCompleted(escrowId, milestoneIndex);
    }
    
    function approveMilestone(
        bytes32 escrowId, 
        uint256 milestoneIndex,
        address freelancer,
        address platformWallet,
        uint256 platformFeePercentage,
        IERC20 token,
        bool isTokenEscrow
    ) external {
        if (milestoneIndex >= milestones[escrowId].length) revert InvalidMilestoneIndex();
        
        Milestone storage milestone = milestones[escrowId][milestoneIndex];
        if (!milestone.completed) revert MilestoneNotCompleted();
        if (milestone.approved) revert MilestoneAlreadyApproved();
        
        milestone.approved = true;
        
        uint256 platformFee = (milestone.amount * platformFeePercentage) / 100;
        uint256 freelancerAmount = milestone.amount - platformFee;
        
        if (isTokenEscrow) {
            token.transfer(freelancer, freelancerAmount);
            token.transfer(platformWallet, platformFee);
        } else {
            payable(freelancer).transfer(freelancerAmount);
            payable(platformWallet).transfer(platformFee);
        }
        
        emit MilestoneApproved(escrowId, milestoneIndex);
    }
    
    function getMilestones(bytes32 escrowId) external view returns (Milestone[] memory) {
        return milestones[escrowId];
    }
    
    function getMilestoneCount(bytes32 escrowId) external view returns (uint256) {
        return milestones[escrowId].length;
    }
    
    function getMilestone(bytes32 escrowId, uint256 index) external view returns (Milestone memory) {
        if (index >= milestones[escrowId].length) revert InvalidMilestoneIndex();
        return milestones[escrowId][index];
    }
}

