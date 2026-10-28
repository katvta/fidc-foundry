// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Interface para FactoryManager yields
 */
interface IFactoryManagerYields {
    function distributeWithYieldsBatchUnified(
        uint256 fidcId,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS
    )
        external
        returns (
            uint256 seniorDist,
            uint256 mezzDist,
            uint256 juniorDist,
            bool fullPayment,
            uint256 processedInvestors,
            uint256 nextCursor,
            bool wrapped,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            bool seriesMode
        );
}

/**
 * @title IUnifiedFactory
 * @notice Interface principal do UnifiedFactoryManager
 * @dev Contém eventos e erros para reduzir o tamanho do contrato principal
 */
interface IUnifiedFactory {
    /* ═══════════════════════════════ EVENTS ═══════════════════════════════ */

    // Crowdfunding (mantém compatibilidade)
    event ManagerInitialized(address indexed managerAddress);
    event CompanyAdminUpdated(address indexed newAdmin);
    event ProjectRegistered(string indexed projectUUID, address projectAddress);
    event ProjectUpgraded(string indexed projectUUID, address indexed oldAddress, address indexed newAddress);

    // FIDC (novos)
    event FIDCCreated(uint256 indexed fidcId, address indexed fidcAddress, address indexed receivable);
    event FIDCSeriesCreated(uint256 indexed fidcId, string indexed serieId, uint256 maxQuotas);
    event FIDCSeriesUpdated(uint256 indexed fidcId, string indexed serieId, uint256 newMaxQuotas);
    event FIDCSeriesDeactivated(uint256 indexed fidcId, string indexed serieId);
    event AnticipationExecuted(
        uint256 indexed operationId,
        address indexed fidcAddress,
        address indexed cedente,
        uint256 amount,
        uint256 collateralAmount,
        address colToken,
        address captationAddress
    );

    // Vault e Escrow (novos)
    event EscrowConfigured(string indexed moduleType, address indexed escrowAddress);
    event AnticipationCompensated(
        uint256 indexed operationId,
        address indexed fidcAddress,
        address indexed cedente,
        uint256 amount,
        address captationAddress
    );
    event CollateralReleased(
        uint256 indexed operationId,
        address indexed fidcAddress,
        address indexed destination,
        address colToken,
        uint256 tokenId,
        uint256 tokenAmount
    );

    // Security events
    event SecurityAlert(string alertType, address suspiciousAddress, uint256 amount);
    event AddedToBlacklist(address indexed addr, string reason);
    event RemovedFromBlacklist(address indexed addr, string reason);

    // Tenant Project Manager events
    event TenantProjectManagerSet(address indexed tenantAddress, address indexed projectManagerAddress);

    // Vault withdrawal events
    event FundsWithdrawnToVault(uint256 indexed fidcId, address indexed captationAddress, uint256 amount);
    event CompensationMovedToVault(uint256 indexed fidcId, address indexed captationAddress, uint256 amount);

    // Distribution funding events
    event DistributionFundingSource(
        uint256 indexed fidcId,
        address indexed fundingSource,
        uint256 amount,
        string sourceType // "vault", "wallet", or "fidc"
    );

    // Distribution cursor events (for logging)
    event DistributionCursorAutoReset(
        uint256 indexed fidcId, string serieId, bool seriesMode, uint256 previousCursor, uint256 totalInvestors
    );

    // FIDC Operator events (multi-admin)
    event FIDCOperatorUpdated(uint256 indexed fidcId, address indexed operator, bool authorized);

    // Batch operations events
    event BatchReceivablesRegistered(uint256 indexed count, bytes32[] receivableIds);
    event BatchCompensated(
        uint256 indexed fidcId, uint256 count, bool isLate, uint256 penaltyBPS, uint256 totalPaid, uint256 totalPenalty
    );
    event BatchAnticipationExecuted(uint256 indexed fidcId, uint256 count, uint256[] operationIds);

    // V3 events (wrapper authorization + tenant penalty cap)
    event WrapperAuthorizationUpdated(uint256 indexed fidcId, bool authorized);
    event TenantPenaltyCapUpdated(address indexed tenant, uint256 cap);

    /* ═══════════════════════════════ ERRORS ═══════════════════════════════ */

    error InvalidInput();
    error InvalidProjectAdmin();
    error NotCompanyAdmin(address addr);
    error AlreadyCompanyAdmin(address addr);
    error ProjectDoesntExist(string projectUUID);
    error ProjectAlreadyExists(string projectUUID);
    error RegistrationCooldown(uint256 remainingTime);
    error IsBlacklisted(address addr);
    error ArrayLengthMismatch();
    error EmptyBatch();
}

