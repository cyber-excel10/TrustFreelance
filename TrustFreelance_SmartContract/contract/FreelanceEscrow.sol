// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./EscrowLibrary.sol";
import "./MilestoneManager.sol";

error NotAuthorized();
error OnlyClientAllowed();
error OnlyFreelancerAllowed();
error EscrowNotExists();
error InvalidAddress();
error InvalidAmount();
error DeadlinePassed();
error EscrowAlreadyExists();
error InvalidEscrowStatus();
error WorkNotCompleted();
error DisputeAlreadyResolved();
error InvalidPercentage();
error FeeTooHigh();
error NoFundsToWithdraw();
error DirectPaymentNotAllowed();
error FunctionNotFound();

contract FreelanceEscrow is ReentrancyGuard, Ownable, Pausable {
    using EscrowLibrary for uint256;
    
    enum EscrowStatus { Created, Funded, WorkInProgress, WorkCompleted, Disputed, Released, Refunded, Cancelled }
    
    struct EscrowDetails {
        address client;
        address freelancer;
        uint256 amount;
        uint256 platformFee;
        uint256 freelancerAmount;
        EscrowStatus status;
        uint256 createdAt;
        uint256 deadline;
        bool clientApproved;
        bool freelancerCompleted;
        bool isTokenEscrow;
    }
    
    struct Dispute {
        address raisedBy;
        string reason;
        uint256 raisedAt;
        bool resolved;
        address resolvedBy;
        uint256 resolvedAt;
    }
    
    mapping(bytes32 => EscrowDetails) public escrows;
    mapping(bytes32 => Dispute) public disputes;
    mapping(address => uint256) public userEscrowCount;
    
    address public platformWallet;
    IERC20 public freelanceToken;
    MilestoneManager public milestoneManager;
    uint256 public platformFeePercentage = 20;
    uint256 public constant MAX_PLATFORM_FEE = 30;
    
    event EscrowCreated(bytes32 indexed escrowId, address indexed client, address indexed freelancer, uint256 amount, uint256 deadline, bool isTokenEscrow);
    event EscrowFunded(bytes32 indexed escrowId, uint256 amount, bool isTokenEscrow);
    event FundsReleased(bytes32 indexed escrowId, uint256 freelancerAmount, uint256 platformFee, bool isTokenEscrow);
    event FundsRefunded(bytes32 indexed escrowId, uint256 amount, bool isTokenEscrow);
    event DisputeRaised(bytes32 indexed escrowId, address indexed raisedBy, string reason);
    event DisputeResolved(bytes32 indexed escrowId, address indexed resolvedBy);
    event WorkCompleted(bytes32 indexed escrowId, address indexed freelancer);
    
    modifier onlyEscrowParties(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].client && msg.sender != escrows[escrowId].freelancer) {
            revert NotAuthorized();
        }
        _;
    }
    
    modifier onlyClient(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].client) revert OnlyClientAllowed();
        _;
    }
    
    modifier onlyFreelancer(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].freelancer) revert OnlyFreelancerAllowed();
        _;
    }
    
    modifier escrowExists(bytes32 escrowId) {
        if (escrows[escrowId].client == address(0)) revert EscrowNotExists();
        _;
    }
    
    constructor(address _platformWallet, address _freelanceToken) Ownable(msg.sender) {
        if (_platformWallet == address(0)) revert InvalidAddress();
        if (_freelanceToken == address(0)) revert InvalidAddress();
        
        platformWallet = _platformWallet;
        freelanceToken = IERC20(_freelanceToken);
        milestoneManager = new MilestoneManager();
    }
    
    function createEscrow(
        bytes32 escrowId,
        address freelancer,
        uint256 deadline,
        string[] memory milestoneDescriptions,
        uint256[] memory milestoneAmounts,
        uint256[] memory milestoneDueDates,
        bool useToken
    ) external payable whenNotPaused {
        if (freelancer == address(0)) revert InvalidAddress();
        if (freelancer == msg.sender) revert InvalidAddress();
        if (deadline <= block.timestamp) revert DeadlinePassed();
        if (escrows[escrowId].client != address(0)) revert EscrowAlreadyExists();
        
        uint256 amount;
        if (useToken) {
            if (msg.value != 0) revert InvalidAmount();
            amount = milestoneAmounts.length > 0 ? 
                EscrowLibrary.calculateTotalAmount(milestoneAmounts) : 
                freelanceToken.allowance(msg.sender, address(this));
            if (amount == 0) revert InvalidAmount();
            freelanceToken.transferFrom(msg.sender, address(this), amount);
        } else {
            if (msg.value == 0) revert InvalidAmount();
            amount = msg.value;
        }
        
        if (milestoneDescriptions.length > 0) {
            EscrowLibrary.validateMilestoneArrays(
                milestoneDescriptions.length,
                milestoneAmounts.length,
                milestoneDueDates.length
            );
            
            uint256 totalMilestoneAmount = EscrowLibrary.calculateTotalAmount(milestoneAmounts);
            if (totalMilestoneAmount != amount) revert InvalidAmount();
            
            milestoneManager.addMilestones(escrowId, milestoneDescriptions, milestoneAmounts, milestoneDueDates);
        }
        
        (uint256 platformFee, uint256 freelancerAmount) = EscrowLibrary.calculateFee(amount, platformFeePercentage);
        
        escrows[escrowId] = EscrowDetails({
            client: msg.sender,
            freelancer: freelancer,
            amount: amount,
            platformFee: platformFee,
            freelancerAmount: freelancerAmount,
            status: EscrowStatus.Funded,
            createdAt: block.timestamp,
            deadline: deadline,
            clientApproved: false,
            freelancerCompleted: false,
            isTokenEscrow: useToken
        });
        
        userEscrowCount[msg.sender]++;
        userEscrowCount[freelancer]++;
        
        emit EscrowCreated(escrowId, msg.sender, freelancer, amount, deadline, useToken);
        emit EscrowFunded(escrowId, amount, useToken);
    }
    
    function completeWork(bytes32 escrowId) external onlyFreelancer(escrowId) escrowExists(escrowId) whenNotPaused {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Funded && escrow.status != EscrowStatus.WorkInProgress) {
            revert InvalidEscrowStatus();
        }
        if (block.timestamp > escrow.deadline) revert DeadlinePassed();
        
        escrow.freelancerCompleted = true;
        escrow.status = EscrowStatus.WorkCompleted;
        emit WorkCompleted(escrowId, msg.sender);
    }
    
    function approveWork(bytes32 escrowId) external onlyClient(escrowId) escrowExists(escrowId) whenNotPaused {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.WorkCompleted) revert WorkNotCompleted();
        
        escrow.clientApproved = true;
        _releaseFunds(escrowId);
    }
    
    function _releaseFunds(bytes32 escrowId) internal {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.WorkCompleted) revert WorkNotCompleted();
        
        escrow.status = EscrowStatus.Released;
        
        if (escrow.isTokenEscrow) {
            freelanceToken.transfer(escrow.freelancer, escrow.freelancerAmount);
            freelanceToken.transfer(platformWallet, escrow.platformFee);
        } else {
            payable(escrow.freelancer).transfer(escrow.freelancerAmount);
            payable(platformWallet).transfer(escrow.platformFee);
        }
        
        emit FundsReleased(escrowId, escrow.freelancerAmount, escrow.platformFee, escrow.isTokenEscrow);
    }
    
    function requestRefund(bytes32 escrowId) external onlyClient(escrowId) escrowExists(escrowId) whenNotPaused {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Funded && escrow.status != EscrowStatus.WorkInProgress) {
            revert InvalidEscrowStatus();
        }
        if (block.timestamp <= escrow.deadline) revert DeadlinePassed();
        
        escrow.status = EscrowStatus.Refunded;
        
        if (escrow.isTokenEscrow) {
            freelanceToken.transfer(escrow.client, escrow.amount);
        } else {
            payable(escrow.client).transfer(escrow.amount);
        }
        
        emit FundsRefunded(escrowId, escrow.amount, escrow.isTokenEscrow);
    }
    
    function raiseDispute(bytes32 escrowId, string memory reason) external onlyEscrowParties(escrowId) escrowExists(escrowId) whenNotPaused {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.WorkCompleted && escrow.status != EscrowStatus.WorkInProgress) {
            revert InvalidEscrowStatus();
        }
        if (disputes[escrowId].resolved) revert DisputeAlreadyResolved();
        
        escrow.status = EscrowStatus.Disputed;
        disputes[escrowId] = Dispute({
            raisedBy: msg.sender,
            reason: reason,
            raisedAt: block.timestamp,
            resolved: false,
            resolvedBy: address(0),
            resolvedAt: 0
        });
        
        emit DisputeRaised(escrowId, msg.sender, reason);
    }
    
    function resolveDispute(
        bytes32 escrowId,
        bool releaseToFreelancer,
        uint256 freelancerPercentage
    ) external onlyOwner escrowExists(escrowId) {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Disputed) revert InvalidEscrowStatus();
        if (freelancerPercentage > 100) revert InvalidPercentage();
        
        disputes[escrowId].resolved = true;
        disputes[escrowId].resolvedBy = msg.sender;
        disputes[escrowId].resolvedAt = block.timestamp;
        
        if (releaseToFreelancer) {
            uint256 freelancerAmount = (escrow.amount * freelancerPercentage) / 100;
            uint256 clientRefund = escrow.amount - freelancerAmount;
            (uint256 platformFee, uint256 finalFreelancerAmount) = EscrowLibrary.calculateFee(freelancerAmount, platformFeePercentage);
            
            _transferFunds(escrow, escrow.freelancer, finalFreelancerAmount);
            _transferFunds(escrow, escrow.client, clientRefund);
            _transferFunds(escrow, platformWallet, platformFee);
            
            escrow.status = EscrowStatus.Released;
        } else {
            _transferFunds(escrow, escrow.client, escrow.amount);
            escrow.status = EscrowStatus.Refunded;
        }
        
        emit DisputeResolved(escrowId, msg.sender);
    }
    
    function _transferFunds(EscrowDetails storage escrow, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        if (escrow.isTokenEscrow) {
            freelanceToken.transfer(to, amount);
        } else {
            payable(to).transfer(amount);
        }
    }
    
    // Milestone functions that delegate to MilestoneManager
    function completeMilestone(bytes32 escrowId, uint256 milestoneIndex) 
        external 
        onlyFreelancer(escrowId) 
        escrowExists(escrowId) 
        whenNotPaused 
    {
        milestoneManager.completeMilestone(escrowId, milestoneIndex);
    }
    
    function approveMilestone(bytes32 escrowId, uint256 milestoneIndex)
        external
        onlyClient(escrowId)
        escrowExists(escrowId)
        whenNotPaused
    {
        EscrowDetails storage escrow = escrows[escrowId];
        milestoneManager.approveMilestone(
            escrowId,
            milestoneIndex,
            escrow.freelancer,
            platformWallet,
            platformFeePercentage,
            freelanceToken,
            escrow.isTokenEscrow
        );
    }
    
    // View functions
    function getEscrowDetails(bytes32 escrowId) external view returns (EscrowDetails memory) {
        return escrows[escrowId];
    }
    
    function getMilestones(bytes32 escrowId) external view returns (MilestoneManager.Milestone[] memory) {
        return milestoneManager.getMilestones(escrowId);
    }
    
    function getDispute(bytes32 escrowId) external view returns (Dispute memory) {
        return disputes[escrowId];
    }
    
    // Admin functions
    function setPlatformFeePercentage(uint256 _feePercentage) external onlyOwner {
        if (_feePercentage > MAX_PLATFORM_FEE) revert FeeTooHigh();
        platformFeePercentage = _feePercentage;
    }
    
    function setPlatformWallet(address _platformWallet) external onlyOwner {
        if (_platformWallet == address(0)) revert InvalidAddress();
        platformWallet = _platformWallet;
    }
    
    function setFreelanceToken(address _freelanceToken) external onlyOwner {
        if (_freelanceToken == address(0)) revert InvalidAddress();
        freelanceToken = IERC20(_freelanceToken);
    }

        function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw(bytes32 escrowId) external onlyOwner {
        EscrowDetails storage escrow = escrows[escrowId];
        if (escrow.amount == 0) revert NoFundsToWithdraw();
        
        uint256 amount = escrow.amount;
        escrow.amount = 0;
        escrow.status = EscrowStatus.Cancelled;
        
        _transferFunds(escrow, owner(), amount);
    }
    
    receive() external payable {
        revert DirectPaymentNotAllowed();
    }
    
    fallback() external payable {
        revert FunctionNotFound();
    }
}

