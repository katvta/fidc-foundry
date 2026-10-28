// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title FIDCErrors
 * @notice Library defining all custom errors used in the FIDC system
 * @dev Groups errors by their functional category
 */
library FIDCErrors {
    // --- Role and Permission Errors ---
    /// @notice Thrown when a validator is not approved
    error ValidatorNotApproved();
    /// @notice Thrown when a payable address is not approved
    error PayableNotApproved();
    /// @notice Thrown when an unauthorized investor attempts an operation
    error UnauthorizedInvestor();
    /// @notice Thrown when role assignment fails
    error RoleAssignmentFailed();
    /// @notice Thrown when role revocation fails
    error RoleRevocationFailed();
    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();
    /// @notice Thrown when an invalid investor type is provided
    error InvalidInvestorType(uint8 _type);

    // --- Validation Errors ---
    /// @notice Thrown when validation fails
    error ValidationFailed();
    /// @notice Thrown when grace period hasn't ended
    error GracePeriodNotEnded();
    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();
    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();
    /// @notice Thrown when allowance is insufficient
    error InsufficientAllowance();
    /// @notice Thrown when balance is insufficient
    error InsufficientBalance();
    /// @notice Thrown when liquidity is insufficient
    error InsufficientLiquidity();
    /// @notice Thrown when an unauthorized operation is attempted
    error Unauthorized();
    /// @notice Thrown when a transfer fails
    error TransferFailed();
    /// @notice Thrown when addresses are not associated
    error NotAssociated();

    // --- Operation Errors ---
    /// @notice Thrown when FIDC is invalid
    error InvalidFIDC();
    /// @notice Thrown when period is invalid
    error InvalidPeriod();
    /// @notice Thrown when yield is invalid
    error InvalidYield();
    /// @notice Thrown when status is invalid
    error InvalidStatus();
    /// @notice Thrown when item is already registered
    error AlreadyRegistered();
    /// @notice Thrown when FIDC amount is insufficient
    error InsufficientFIDCAmount();
    /// @notice Thrown when status is already active
    error StatusActive();
    /// @notice Thrown when contract is paused
    error ContractPaused();
    /// @notice Thrown when zero address is provided
    error ZeroAddress();
    /// @notice Thrown when fee is invalid
    error InvalidFee();
    /// @notice Thrown when grace period is invalid
    error InvalidGracePeriod();
    /// @notice Thrown when senior ratio is invalid
    error InvalidSeniorRatio();
    /// @notice Thrown when spread is invalid
    error InvalidSpread();
    /// @notice Thrown when contract is already paused
    error AlreadyPaused();
    /// @notice Thrown when contract is not paused
    error NotPaused();
    /// @notice Thrown when array is empty
    error EmptyArray();
    /// @notice Thrown when investment is not found
    error InvestmentNotFound();
    /// @notice Thrown when token is invalid
    error InvalidToken();
    /// @notice Thrown when position is not found
    error NoPosition();
    /// @notice Thrown when leftover amount is not found
    error NoLeftoverAmount();
    /// @notice Thrown when FIDC is already closed
    error FIDCAlreadyClosed();
    /// @notice Thrown when no valid investments are found
    error NoValidInvestments();
    /// @notice Thrown when collateral amount is invalid
    error InvalidCollateralAmount(uint256 requiredCollateral);
    /// @notice Thrown when array length is invalid
    error InvalidLength();
    /// @notice Thrown when PJ is invalid
    error InvalidPJ();
    /// @notice Thrown when purchase ID is already processed
    error PurchaseAlreadyProcessed(string purchaseId);
    /// @notice Thrown when compliance period has expired
    error CompliancePeriodExpired();
    /// @notice Thrown when max quotas is exceeded
    error MaxQuotasExceeded();
    /// @notice Thrown when project ID exists
    error ProjectIdExists();
    /// @notice Thrown when not tenant owner
    error NotTenantOwner();
    /// @notice Thrown when address is not whitelisted
    error NotWhitelisted();
    /// @notice Thrown when implementation is not set
    error ImplementationNotSet();
    /// @notice Thrown when token is incompatible
    error IncompatibleToken();
    /// @notice Thrown when investor is not found
    error InvestorNotFound();
    /// @notice Thrown when overpayment is detected
    error Overpayment();
    /// @notice Thrown when no debt is found
    error NoDebt();
    /// @notice Thrown when class is invalid
    error InvalidClass();
    /// @notice Thrown when collateral is not approved
    error CollateralNotApproved();
    /// @notice Thrown when FIDC address is not registered/known
    error FIDCNotRegistered(address fidcAddress);
    /// @notice Thrown when a class is not allowed to invest in a specific series
    error ClassNotAllowedInSeries();
}
