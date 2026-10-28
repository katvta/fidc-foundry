// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IFIDC_Optimized} from "../../interface/IFIDC_Optimized.sol";
import {IDebentureCollateral} from "../../interface/IDebentureCollateral.sol";
import {IUnifiedEscrow} from "../interface/IUnifiedEscrow.sol";
import {YieldCalculator} from "../../libraries/YieldCalculator.sol";
import {IFIDCFactoryManager} from "../../interface/IFIDCFactoryManager.sol";
import {FIDCManagerLib} from "../../libraries/FIDCManagerLib.sol";
import {FIDCErrors} from "../../libraries/FIDCErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title FIDCModuleLib
 * @notice Library for FIDC operations
 * @dev Diamond storage pattern with new anticipation structure
 */
library FIDCModuleLib {
    using SafeERC20 for IERC20;

    // Diamond storage slots
    bytes32 private constant STORAGE_SLOT_FIDC = keccak256("capitare.unified.fidc.v1");
    bytes32 private constant STORAGE_SLOT_REGISTRY = keccak256("capitare.unified.registry.v1");

    /* ═══════════════════════════════ STRUCTS ═══════════════════════════════ */

    /**
     * @notice Parameters for anticipation (improved version)
     * @dev Absolute collateral value (off-chain calculation)
     */
    struct AnticipationParams {
        uint256 fidcId; // 0 = create new FIDC, >0 = use existing
        address cedente; // Who is anticipating (legal entity)
        uint256 amount; // Amount to anticipate (WAD, 18 decimals)
        address colToken; // Collateral token (address(0) = internal receivable)
        uint256 collateralAmount; // ABSOLUTE collateral value (WAD, not %)
        address captationAddress; // Source contract for funds (address(0) = FIDC balance)
        string receivableHash; // Receivable document hash
        uint256 maturityDate; // Receivable maturity date
    }

    struct FIDCState {
        // Core addresses
        address factoryAddress;
        address fidcFactoryManager; // FIDC FactoryManager (must implement IFIDCFactoryManager)

        // Registry of created/registered FIDCs
        mapping(uint256 => address) fidcById; // fidcId -> fidcDiamond address
        mapping(address => bool) isKnownFIDC; // fidcDiamond -> is registered
        mapping(uint256 => address) recebivelByFidc; // fidcId -> receivable address

        // Vault per FIDC (each FIDC has its own vault)
        mapping(uint256 => address) vaultByFidc; // fidcId -> vault address

        // Whitelisted wallet per FIDC (alternative to vault)
        mapping(uint256 => address) whitelistedWalletByFidc; // fidcId -> whitelisted wallet address

        // Anticipations
        mapping(uint256 => AnticipationRecord) anticipations;
        uint256 nextAnticipationId;
    }

    struct RegistryState {
        // Sacados
        mapping(bytes32 => SacadoInfo) sacados;
        mapping(address => bytes32) sacadoPorCarteira;
        bytes32[] sacadoIds;

        // Cedentes
        mapping(bytes32 => CedenteInfo) cedentes;
        mapping(address => bytes32) cedentePorCarteira;
        bytes32[] cedenteIds;

        // Recebíveis
        mapping(bytes32 => RecebivelInfo) recebiveis;
        mapping(bytes32 => bytes32[]) recebiveisPorProprietario;

        // Link receivable to operation for correct accounting
        mapping(bytes32 => uint256) receivableToOperation; // receivableId -> operationId
        mapping(uint256 => bytes32) operationToReceivable; // operationId -> receivableId

        // Nonce to avoid receivableId collision
        uint256 recebivelNonce;
    }

    struct AnticipationRecord {
        uint256 operationId;
        bytes32 receivableId; // Link receivable to operation for correct accounting
        address fidcAddress; // FIDC contract address (instead of fidcId)
        address cedente;
        uint256 amount; // Original anticipated amount
        uint256 collateralAmount; // Total locked collateral (value, in native decimals)
        uint256 collateralRemaining; // Remaining collateral (updated on each compensation)
        address colToken;
        address captationAddress; // Address where funds came from (escrow/crowd/debenture/fidc or wallet)
        uint256 timestamp;
        bool active;
        CollateralTokenType collateralType;
        uint256 collateralTokenId;
        uint256 collateralTokenAmount;
        CollateralCustodyType collateralCustody;
        address collateralDestination;
        uint256 collateralExternalConsumed;
        bool collateralReleased; // true after NFT/ERC1155 locked in contract has been released to destination
    }

    /* ═══════════════════════════════ REGISTRY ENUMS ═══════════════════════════════ */

    enum StatusSacado {
        PENDENTE,
        APROVADO,
        REPROVADO,
        BLOQUEADO
    }

    enum StatusCedente {
        PENDENTE,
        APROVADO,
        REPROVADO,
        BLOQUEADO
    }

    enum StatusRecebivel {
        REGISTRADO,
        APROVADO_SACADO, // Debtor approved the receivable
        ANTECIPADO,
        PAGO,
        VENCIDO,
        CANCELADO
    }

    enum CollateralTokenType {
        NONE, // 0
        ERC20, // 1
        ERC721, // 2
        ERC1155 // 3
    }

    enum CollateralCustodyType {
        NONE,
        CONTRACT_LOCK,
        EXTERNAL_WALLET
    }

    /// @notice Collateral configuration for anticipation (type, id, amount, custody, destination)
    struct CollateralConfig {
        CollateralTokenType collateralType;
        uint256 collateralTokenId;
        uint256 collateralTokenAmount;
        CollateralCustodyType collateralCustody;
        address collateralDestination;
    }

    /// @notice Bundled parameters for anticipation at gateway (reduces stack depth)
    struct AnticipationRequest {
        bytes32 receivableId;
        uint256 anticipationAmount;
        address colToken;
        uint256 collateralAmount;
        address captationAddress;
        CollateralConfig collateral;
    }

    /// @notice Bundled params for anticipateWithReceivable (reduces stack depth at call site)
    struct AnticipationCallParams {
        uint256 fidcId;
        address fidcAddress;
        bytes32 recebivelId;
        uint256 valorAntecipacao;
        address colToken;
        uint256 collateralAmount;
        address captationAddress;
        CollateralTokenType collateralType;
        uint256 collateralTokenId;
        uint256 collateralTokenAmount;
        CollateralCustodyType collateralCustody;
        address collateralDestination;
    }

    /* ═══════════════════════════════ REGISTRY STRUCTS ═══════════════════════════════ */

    struct SacadoInfo {
        string cnpj;
        address carteiraSacado;
        uint256 limiteExposicao; // Exposure limit in WAD (18 decimals)
        uint256 exposicaoAtual; // Current exposure in WAD (18 decimals)
        StatusSacado status;
        uint256 dataRegistro;
        bool ativo;
    }

    struct CedenteInfo {
        string cnpj;
        address carteiraCedente;
        uint256 limiteAntecipacao; // Anticipation limit in WAD (18 decimals)
        uint256 exposicaoAtual; // Current exposure in WAD (18 decimals)
        StatusCedente status;
        uint256 dataRegistro;
        bool ativo;
    }

    struct RecebivelInfo {
        bytes32 proprietarioId; // Owner ID (debtor or creditor who registered)
        address proprietarioAddr; // Owner address
        address cedenteAddr; // Creditor address (who can anticipate)
        address sacadoAddr; // Debtor address (who will pay)
        string identificador; // NF-e key or unique identifier
        uint256 valorNominal; // Nominal value in WAD (18 decimals)
        uint256 valorRestante; // Remaining value in WAD (18 decimals)
        uint256 dataVencimento;
        StatusRecebivel status;
        uint256 dataRegistro;
        uint256 dataUltimoPagamento;
        bool ativo;
    }

    /* ═══════════════════════════════ EVENTS ═══════════════════════════════ */

    // Events removed from library - only UnifiedFactoryManager emits events
    // This avoids duplication and double counting in backend/indexer
    // Events are emitted only at Gateway (UnifiedFactoryManager)

    // ═══════════════════════════════ REGISTRY EVENTS ═══════════════════════════════

    event SacadoRegistered(bytes32 indexed sacadoId, string cnpj, address carteiraSacado, StatusSacado status);
    event CedenteRegistered(bytes32 indexed cedenteId, string cnpj, address carteiraCedente, StatusCedente status);
    event DebtorLimitUpdated(bytes32 indexed debtorId, uint256 oldLimit, uint256 newLimit);
    event CreditorLimitUpdated(bytes32 indexed creditorId, uint256 oldLimit, uint256 newLimit);
    event RecebivelRegistered(
        bytes32 indexed recebivelId,
        address indexed proprietario,
        address indexed cedente,
        address sacado,
        string identificador,
        uint256 valorNominal
    );
    event RecebivelAprovado(bytes32 indexed recebivelId, address indexed aprovador);
    event RecebivelAntecipado(bytes32 indexed recebivelId, uint256 indexed operationId, uint256 valorAntecipacao);
    event RecebivelPago(bytes32 indexed recebivelId, uint256 valorPagamento, uint256 valorRestante, bytes32 proofHash);

    /* ═══════════════════════════════ ERRORS ═══════════════════════════════ */

    error FIDCDoesNotExist(uint256 fidcId);
    error FIDCNotActive(uint256 fidcId);
    error InvalidCollateralAmount();
    error InsufficientCaptationBalance();
    error InvalidDebentureCollateral();
    error ZeroAddress();
    error ZeroAmount();
    error AnticipationNotActive(uint256 operationId); // Custom error for production
    error CollateralAlreadyReleased();
    error CollateralNotInContract(); // EXTERNAL_WALLET: nothing to release from factory
    error OperationNotClosed(); // Release only when !active (collateral fully compensated)
    error CallerNotFactory();

    /* ═══════════════════════════════ STORAGE ═══════════════════════════════ */

    function fidcState() internal pure returns (FIDCState storage s) {
        bytes32 slot = STORAGE_SLOT_FIDC;
        assembly {
            s.slot := slot
        }
    }

    function registryState() internal pure returns (RegistryState storage s) {
        bytes32 slot = STORAGE_SLOT_REGISTRY;
        assembly {
            s.slot := slot
        }
    }

    /* ═══════════════════════════════ HELPER FUNCTIONS ═══════════════════════════════ */

    /**
     * @notice Checks if an address is a valid escrow contract
     * @dev Returns real value of isAuthorized() instead of just checking if function exists
     * @param escrowAddress Address to check
     * @return isValid True if valid escrow contract AND authorized
     */
    function _isValidEscrow(address escrowAddress) private view returns (bool isValid) {
        if (escrowAddress == address(0)) return false;

        // Check if it's a contract (not a wallet)
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(escrowAddress)
        }
        if (codeSize == 0) return false; // It's a wallet, not a contract

        // Return real value of isAuthorized() instead of just true
        // If interface not implemented, returns false
        // Uses factoryAddress if configured, otherwise address(0) as fallback (not ideal but necessary)
        FIDCState storage s = fidcState();
        address authorizedAddress = s.factoryAddress != address(0) ? s.factoryAddress : address(0);
        try IUnifiedEscrow(escrowAddress).isAuthorized(authorizedAddress) returns (bool authorized) {
            return authorized; // Retorna valor real
        } catch {
            return false;
        }
    }

    /* ═══════════════════════════════ ADMIN ═══════════════════════════════ */

    function setFactoryAddress(address factory) internal {
        fidcState().factoryAddress = factory;
    }

    /**
     * @notice Sets vault for a specific FIDC
     * @param fidcId FIDC ID
     * @param vaultAddress Vault address (address(0) to clear)
     */
    function setVaultForFIDC(uint256 fidcId, address vaultAddress) internal {
        fidcState().vaultByFidc[fidcId] = vaultAddress;
    }

    /**
     * @notice Returns vault of a specific FIDC
     * @param fidcId FIDC ID
     * @return vaultAddress Vault address (address(0) if not configured)
     */
    function getVaultForFIDC(uint256 fidcId) internal view returns (address vaultAddress) {
        return fidcState().vaultByFidc[fidcId];
    }

    /**
     * @notice Returns configured captation address (vault or whitelisted wallet) for a FIDC
     * @param fidcId FIDC ID
     * @return captationAddress Vault address (priority) or whitelisted wallet address (address(0) if none configured)
     */
    function getCaptationAddressForFIDC(uint256 fidcId) internal view returns (address captationAddress) {
        address vault = getVaultForFIDC(fidcId);
        if (vault != address(0)) {
            return vault;
        }
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) return address(0);
        try IFIDC_Optimized(fidcAddress).getWhitelistedWallet() returns (address wallet) {
            return wallet;
        } catch {
            return address(0);
        }
    }

    function setFIDCFactoryManager(address factoryManager) internal {
        fidcState().fidcFactoryManager = factoryManager;
    }

    function getFIDCFactoryManager() internal view returns (address) {
        return fidcState().fidcFactoryManager;
    }

    /**
     * @notice Returns FIDC address by ID
     * @dev Single source of truth - queries FactoryManagerDiamond directly
     * @param fidcId FIDC ID
     * @return FIDC Diamond address
     */
    function getFIDC(uint256 fidcId) internal view returns (address) {
        address factoryManager = getFIDCFactoryManager();
        if (factoryManager == address(0)) revert ZeroAddress();
        return IFIDCFactoryManager(factoryManager).getFIDC(fidcId);
    }

    /// @notice Resolves the tenant owner of a FIDC via the factory manager.
    /// @dev AUDIT-FIX R2-C-02 enabler: lets the gateway key the penalty cap by tenant owner without
    ///      inlining the IFIDCFactoryManager call (EIP-170 budget on UnifiedFactoryManagerV3).
    function getTenantOwner(uint256 fidcId) internal view returns (address) {
        address factoryManager = getFIDCFactoryManager();
        if (factoryManager == address(0)) revert ZeroAddress();
        return IFIDCFactoryManager(factoryManager).getTenantOwner(fidcId);
    }

    /**
     * @notice Returns tenant contract (FIDC) address by ID
     * @dev Alias for getFIDC - same functionality, different name for clarity
     * @param fidcId FIDC ID
     * @return Tenant contract (FIDC Diamond) address
     */
    function getTenantContract(uint256 fidcId) internal view returns (address) {
        return getFIDC(fidcId);
    }

    /**
     * @notice Checks if a FIDC is known/registered
     * @dev Single source of truth - queries FactoryManagerDiamond directly
     * @param fidcAddress FIDC address
     * @return True if known
     */
    function isKnownFIDC(address fidcAddress) internal view returns (bool) {
        address factoryManager = getFIDCFactoryManager();
        if (factoryManager == address(0)) return false;
        return IFIDCFactoryManager(factoryManager).isFIDC(fidcAddress);
    }

    /**
     * @notice Validates that a FIDC is known/registered (reverts if not)
     * @dev Single source of truth - queries FactoryManagerDiamond directly
     * @param fidcAddress FIDC address
     */
    function assertKnownFIDC(address fidcAddress) internal view {
        address factoryManager = getFIDCFactoryManager();
        if (factoryManager == address(0)) revert ZeroAddress();
        if (!IFIDCFactoryManager(factoryManager).isFIDC(fidcAddress)) {
            revert FIDCErrors.FIDCNotRegistered(fidcAddress);
        }
    }

    /* ═══════════════════════════════ FIDC OPERATIONS ═══════════════════════════════ */

    /**
     * @notice Creates new FIDC (replaces debentures with series system)
     * @dev Delegates to FactoryManager which creates the FIDC
     */
    function createFIDC(
        string memory projectId,
        address tenantOwner,
        address stable,
        address manager,
        string memory fidcName,
        string memory ticker,
        uint32 juniorYieldBPS,
        uint32 grace,
        uint32 seniorYieldBPS,
        uint32 mezzYieldBPS,
        uint256 maxQuotas,
        uint256 maxSenior,
        uint256 maxMezz,
        uint256 maxJunior,
        uint32 feePlatform,
        address walletPlatform,
        uint256 assetPrice
    ) internal returns (uint256 fidcId, address fidcAddress, address recebivelAddress) {
        address fm = getFIDCFactoryManager();
        if (fm == address(0)) revert ZeroAddress();
        return IFIDCFactoryManager(fm)
            .createFIDC(
                projectId,
                tenantOwner,
                stable,
                manager,
                fidcName,
                ticker,
                juniorYieldBPS,
                grace,
                seniorYieldBPS,
                mezzYieldBPS,
                maxQuotas,
                maxSenior,
                maxMezz,
                maxJunior,
                feePlatform,
                walletPlatform,
                assetPrice
            );
    }

    /**
     * @notice Creates a new series in the FIDC (replaces debentures)
     * @dev Allows creating independent series within a FIDC
     * @dev Validates that fidcId exists before creating series
     * @param fidcId FIDC ID
     * @param serieId Unique series ID
     * @param maxQuotas Maximum quota limit (0 = unlimited)
     * @param allowSenior Whether Senior class can invest
     * @param allowMezz Whether Mezzanine class can invest
     * @param allowJunior Whether Junior class can invest
     * @dev ✅ PHASE 1: Added support for class restrictions per series
     */
    function createFIDCSeries(
        uint256 fidcId,
        string calldata serieId,
        uint256 maxQuotas,
        bool allowSenior,
        bool allowMezz,
        bool allowJunior
    ) internal {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        // Chamar diretamente no Diamond via interface IFIDC_Optimized
        IFIDC_Optimized(fidcAddress).createSeries(serieId, maxQuotas, allowSenior, allowMezz, allowJunior);
    }

    /**
     * @notice Updates maximum quota limit of a series
     */
    function updateFIDCSeriesMaxQuotas(uint256 fidcId, string calldata serieId, uint256 newMaxQuotas) internal {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        IFIDC_Optimized(fidcAddress).updateSeriesMaxQuotas(serieId, newMaxQuotas);
    }

    /**
     * @notice Deactivates a series (no longer allows investments)
     */
    function deactivateFIDCSeries(uint256 fidcId, string calldata serieId) internal {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        IFIDC_Optimized(fidcAddress).deactivateSeries(serieId);
    }

    /**
     * @notice Returns information of a specific series
     * @dev ✅ PHASE 1: Now also returns class restriction information
     */
    function getFIDCSeries(uint256 fidcId, string calldata serieId)
        internal
        view
        returns (
            string memory serieId_,
            uint256 totalCaptated,
            uint256 totalQuotas,
            uint256 maxQuotas,
            uint256 totalInvestments,
            bool active,
            uint256 createdAt,
            uint256 lastInvestmentAt,
            bool allowSenior,
            bool allowMezz,
            bool allowJunior
        )
    {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        FIDCManagerLib.SeriesInfo memory series = IFIDC_Optimized(fidcAddress).getSeries(serieId);
        return (
            series.serieId,
            series.totalCaptated,
            series.totalQuotas,
            series.maxQuotas,
            series.totalInvestments,
            series.active,
            series.createdAt,
            series.lastInvestmentAt,
            series.allowSenior,
            series.allowMezz,
            series.allowJunior
        );
    }

    /**
     * @notice Returns all series of the FIDC
     */
    function getAllFIDCSeries(uint256 fidcId) internal view returns (string[] memory) {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).getAllSeries();
    }

    /**
     * @notice Returns investors of a specific series
     */
    function getFIDCSeriesInvestors(uint256 fidcId, string calldata serieId) internal view returns (address[] memory) {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).getSeriesInvestors(serieId);
    }

    /**
     * @notice Returns detailed statistics per class of a series
     * @param fidcId FIDC ID
     * @param serieId Series ID
     * @return Statistics per class (captated, quotas, investors)
     * @dev ✅ PHASE 2: New function to query detailed information per class
     */
    function getFIDCSeriesClassStats(uint256 fidcId, string calldata serieId)
        internal
        view
        returns (FIDCManagerLib.SeriesClassStats memory)
    {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).getSeriesClassStats(serieId);
    }

    /**
     * @notice Returns list of investors of a specific class in a series
     * @param fidcId FIDC ID
     * @param serieId Series ID
     * @param classId Class ID (0=Senior, 1=Mezzanine, 2=Junior)
     * @return List of addresses of investors in the specified class
     * @dev ✅ PHASE 2: New function to query investors by class
     */
    function getFIDCSeriesInvestorsByClass(uint256 fidcId, string calldata serieId, uint8 classId)
        internal
        view
        returns (address[] memory)
    {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).getSeriesInvestorsByClass(serieId, classId);
    }

    /**
     * @notice Returns how many quotas remain in a series
     * @param fidcId FIDC ID
     * @param serieId Series ID
     * @return remaining Number of remaining quotas (type(uint256).max if unlimited)
     * @return isUnlimited true if the series is unlimited (maxQuotas == 0)
     * @dev ✅ PHASE 3: Helper function to facilitate querying remaining quotas
     */
    function getFIDCSeriesRemainingQuotas(uint256 fidcId, string calldata serieId)
        internal
        view
        returns (uint256 remaining, bool isUnlimited)
    {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).getSeriesRemainingQuotas(serieId);
    }

    /**
     * @notice Returns fill percentage of a series
     * @param fidcId FIDC ID
     * @param serieId Series ID
     * @return percentageBPS Percentage in basis points (0-10000, where 10000 = 100%)
     * @return isUnlimited true if the series is unlimited (maxQuotas == 0)
     * @dev ✅ PHASE 3: Helper function to facilitate querying fill percentage
     */
    function getFIDCSeriesFillPercentage(uint256 fidcId, string calldata serieId)
        internal
        view
        returns (uint256 percentageBPS, bool isUnlimited)
    {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).getSeriesFillPercentage(serieId);
    }

    /**
     * @notice Checks if a series is complete (reached maxQuotas)
     * @param fidcId FIDC ID
     * @param serieId Series ID
     * @return true if the series is complete (totalQuotas >= maxQuotas)
     * @dev ✅ PHASE 3: Helper function to check if series is complete
     */
    function isFIDCSeriesComplete(uint256 fidcId, string calldata serieId) internal view returns (bool) {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).isSeriesComplete(serieId);
    }

    /**
     * @notice Invests in FIDC with specific series
     * @dev Validates that fidcId exists before investing
     */
    function investInFIDC(
        uint256 fidcId,
        string calldata purchaseId,
        address owner,
        uint8 classId,
        uint256 value,
        string calldata serieId
    ) internal returns (uint256) {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).investValue(purchaseId, owner, classId, value, serieId);
    }

    /**
     * @notice Batch invests in FIDC with specific series
     * @dev Validates that fidcId exists before investing
     */
    function investBatchInFIDC(
        uint256 fidcId,
        string calldata purchaseId,
        address owner,
        uint8[] calldata classIds,
        uint256[] calldata values,
        string calldata serieId
    ) internal returns (uint256[] memory) {
        address fidcAddress = getFIDC(fidcId);
        if (fidcAddress == address(0)) revert FIDCDoesNotExist(fidcId);

        return IFIDC_Optimized(fidcAddress).investBatch(purchaseId, owner, classIds, values, serieId);
    }

    /**
     * @notice Captures and validates collateral
     * @dev Supports internal receivable, ERC20 tokens and debentures
     * @dev Standardizes everything in WAD - converts to native decimals before transferring
     *
     * @param cedente Creditor address
     * @param colToken Collateral token (address(0) = internal receivable)
     * @param collateralAmount Absolute collateral value (in WAD, 18 decimals)
     * @param fidcAddress FIDC contract address
     */
    function _handleCollateral(address cedente, address colToken, uint256 collateralAmount, address fidcAddress)
        private
    {
        if (colToken == address(0)) {
            // Internal receivable - mint via FIDC
            // FIDC already does this internally via anticipateWithRatio
            return;
        }

        // Convert from WAD to native token decimals before transferring
        uint8 colDecimals = IERC20Metadata(colToken).decimals();
        uint256 collateralNative = YieldCalculator.scaleFromWad(collateralAmount, colDecimals);

        // Normal ERC20 token - transfer to FIDC (in native decimals)
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(colToken).safeTransferFrom(cedente, fidcAddress, collateralNative);
    }

    function _lockNFTCollateral(
        CollateralTokenType collateralType,
        CollateralCustodyType collateralCustody,
        address from,
        address nftToken,
        uint256 tokenId,
        uint256 tokenAmount,
        address collateralDestination,
        address fidcAddress
    ) private {
        if (collateralType != CollateralTokenType.ERC721 && collateralType != CollateralTokenType.ERC1155) {
            return;
        }

        // CONTRACT_LOCK: NFT vai para o FIDC Diamond (cada FIDC guarda seu colateral). EXTERNAL_WALLET: vai para collateralDestination.
        address destination;
        if (collateralCustody == CollateralCustodyType.CONTRACT_LOCK) {
            destination = fidcAddress;
        } else if (collateralCustody == CollateralCustodyType.EXTERNAL_WALLET) {
            destination = collateralDestination;
        } else {
            revert InvalidCollateralAmount();
        }

        if (destination == address(0)) revert ZeroAddress();
        if (nftToken == address(0)) revert ZeroAddress();

        if (collateralType == CollateralTokenType.ERC721) {
            if (tokenAmount != 1) revert InvalidCollateralAmount();
            // slither-disable-next-line arbitrary-send-erc721
            IERC721(nftToken).safeTransferFrom(from, destination, tokenId);
        } else {
            if (tokenAmount == 0) revert InvalidCollateralAmount();
            // slither-disable-next-line arbitrary-send-erc1155
            IERC1155(nftToken).safeTransferFrom(from, destination, tokenId, tokenAmount, "");
        }
    }

    /**
     * @notice Transfers funds to creditor
     * @dev Source: FIDC vault (if configured), captationAddress or FIDC balance
     *
     * PRIORITY:
     * 1. If captationAddress is a valid escrow contract: uses escrow.authorizedTransfer()
     * 2. If captationAddress specified (but not escrow): uses transferFrom
     * 3. If FIDC vault configured and captationAddress == 0: uses FIDC vault
     * 4. Otherwise: uses FIDC's own balance
     *
     * @param cedente Creditor address (recipient)
     * @param amount Amount to transfer
     * @param colToken Collateral token
     * @param collateralAmount Collateral value (to calculate ratio)
     * @param captationAddress Source of funds (address(0) = try FIDC vault or FIDC balance)
     * @param fidcId FIDC ID (to get specific vault)
     * @param fidcAddress FIDC contract address
     */
    function _transferFunds(
        address cedente,
        uint256 amount,
        address colToken,
        uint256 collateralAmount,
        address captationAddress,
        uint256 fidcId,
        address fidcAddress
    ) private {
        FIDCState storage s = fidcState();
        address stableToken = IFIDC_Optimized(fidcAddress).getStableToken();

        // Get stableToken decimals
        uint8 stableDecimals = IERC20Metadata(stableToken).decimals();

        // Standardize everything in WAD - assume amount and collateralAmount always come in WAD
        // Convert to native decimals only for ERC20 transfers
        uint256 amountWad = amount; // Already in WAD
        uint256 collateralAmountWad = collateralAmount; // Already in WAD
        uint256 amountNative = YieldCalculator.scaleFromWad(amount, stableDecimals); // For transfers

        // ✅ PRECISION: Calculate ratio using WAD values to ensure precision
        // Ratio is in percentage (100 = 100%, 118 = 118%, etc.)
        uint256 ratioWad = (collateralAmountWad * 100) / amountWad;
        require(ratioWad >= 100 && ratioWad <= 300, "Invalid collateral ratio");
        uint16 calculatedRatio = uint16(ratioWad);

        // PRIORITY 1: If captationAddress is a valid escrow contract, use authorizedTransfer()
        if (captationAddress != address(0) && _isValidEscrow(captationAddress)) {
            // Validate that captationAddress (escrow) is authorized
            IUnifiedEscrow escrow = IUnifiedEscrow(captationAddress);
            // Use s.factoryAddress instead of address(this) in library
            address caller = s.factoryAddress != address(0) ? s.factoryAddress : address(this);
            if (!escrow.isAuthorized(caller)) {
                revert InsufficientCaptationBalance();
            }

            // Validate that escrow has sufficient balance (use amountNative for comparison)
            uint256 escrowBalance = escrow.getAvailableBalance(stableToken);
            if (escrowBalance < amountNative) {
                revert InsufficientCaptationBalance();
            }

            // Transfer via escrow (use amountNative for transfer)
            bool success = escrow.authorizedTransfer(stableToken, cedente, amountNative);
            if (!success) {
                revert InsufficientCaptationBalance();
            }

            // Register anticipation in FIDC (without transferring from its balance)
            // Uses anticipateWithRatioSkipTransfer because funds already transferred by vault/escrow
            // Passes amountWad (in WAD) to anticipateWithRatioSkipTransfer
            IFIDC_Optimized(fidcAddress).anticipateWithRatioSkipTransfer(cedente, amountWad, colToken, calculatedRatio);
        }
        // PRIORITY 2: If captationAddress specified (but not escrow), use transferFrom
        else if (captationAddress != address(0)) {
            // Real spender is UnifiedFactoryManager (who executes transferFrom)
            // factoryAddress must be configured to UnifiedFactoryManager address
            if (s.factoryAddress == address(0)) {
                revert ZeroAddress(); // Factory address must be configured
            }
            address spender = s.factoryAddress; // UnifiedFactoryManager needs allowance

            // Validate sufficient approval (use amountNative for comparison)
            uint256 allowance = IERC20(stableToken).allowance(captationAddress, spender);
            if (allowance < amountNative) {
                revert InsufficientCaptationBalance();
            }

            // Validate sufficient balance (use amountNative for comparison)
            uint256 balance = IERC20(stableToken).balanceOf(captationAddress);
            if (balance < amountNative) {
                revert InsufficientCaptationBalance();
            }

            // Transfer from captationAddress to cedente (use amountNative for transfer)
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(stableToken).safeTransferFrom(captationAddress, cedente, amountNative);

            // Register anticipation in FIDC (without transferring from its balance)
            // Uses anticipateWithRatioSkipTransfer because funds already transferred from wallet
            // Passes amountWad (in WAD) to anticipateWithRatioSkipTransfer
            IFIDC_Optimized(fidcAddress).anticipateWithRatioSkipTransfer(cedente, amountWad, colToken, calculatedRatio);
        }
        // PRIORITY 3: If captationAddress == 0, try vault or whitelisted wallet
        // PRIORITY 4: If captationAddress == 0 and no vault/wallet, use FIDC's own balance
        if (captationAddress == address(0)) {
            address fidcVault = s.vaultByFidc[fidcId];
            address whitelistedWallet = address(0);
            if (fidcAddress != address(0)) {
                try IFIDC_Optimized(fidcAddress).getWhitelistedWallet() returns (address wallet) {
                    whitelistedWallet = wallet;
                } catch {}
            }

            // PRIORITY 3a: Use FIDC vault if configured and valid escrow
            if (fidcVault != address(0) && _isValidEscrow(fidcVault)) {
                // Validate that vault is authorized
                IUnifiedEscrow escrow = IUnifiedEscrow(fidcVault);
                address caller = s.factoryAddress != address(0) ? s.factoryAddress : address(this);
                if (!escrow.isAuthorized(caller)) {
                    revert InsufficientCaptationBalance();
                }

                // Validate that vault has sufficient balance
                uint256 vaultBalance = escrow.getAvailableBalance(stableToken);
                if (vaultBalance < amountNative) {
                    revert InsufficientCaptationBalance();
                }

                // Transfer via FIDC vault
                bool success = escrow.authorizedTransfer(stableToken, cedente, amountNative);
                if (!success) {
                    revert InsufficientCaptationBalance();
                }

                // Register anticipation in FIDC (without transferring from its balance)
                IFIDC_Optimized(fidcAddress)
                    .anticipateWithRatioSkipTransfer(cedente, amountWad, colToken, calculatedRatio);
                return; // Exit function after transferring via vault
            }
            // PRIORITY 3b: Use whitelisted wallet if configured (and no vault)
            else if (whitelistedWallet != address(0)) {
                // Validate that factory address is configured
                if (s.factoryAddress == address(0)) {
                    revert ZeroAddress();
                }
                address spender = s.factoryAddress;

                // Validate sufficient approval
                uint256 allowance = IERC20(stableToken).allowance(whitelistedWallet, spender);
                if (allowance < amountNative) {
                    revert InsufficientCaptationBalance();
                }

                // Validate sufficient balance
                uint256 balance = IERC20(stableToken).balanceOf(whitelistedWallet);
                if (balance < amountNative) {
                    revert InsufficientCaptationBalance();
                }

                // Transfer from whitelisted wallet to cedente
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(stableToken).safeTransferFrom(whitelistedWallet, cedente, amountNative);

                // Register anticipation in FIDC (without transferring from its balance)
                IFIDC_Optimized(fidcAddress)
                    .anticipateWithRatioSkipTransfer(cedente, amountWad, colToken, calculatedRatio);
                return; // Exit function after transferring via whitelisted wallet
            }
            // PRIORITY 4: No vault/wallet configured, use FIDC's own balance
            IFIDC_Optimized(fidcAddress).anticipateWithRatio(cedente, amountWad, colToken, calculatedRatio);
        }
    }

    /**
     * @notice DEBTOR REGISTRATION - Function to register approved debtors
     * @dev Minimal on-chain data after off-chain validation
     *
     * @param cnpj Debtor's CNPJ
     * @param carteiraSacado Debtor's wallet address
     * @param limiteExposicao Total exposure limit in stable tokens (WAD)
     * @param status Debtor's status
     */
    function registerDebtor(string calldata cnpj, address carteiraSacado, uint256 limiteExposicao, StatusSacado status)
        external
    {
        RegistryState storage s = registryState();
        // Validation done in UnifiedFactoryManager

        bytes32 sacadoId = keccak256(abi.encodePacked(cnpj));
        require(s.sacados[sacadoId].carteiraSacado == address(0), "Debtor already registered");
        require(s.sacadoPorCarteira[carteiraSacado] == bytes32(0), "Wallet already registered");

        s.sacados[sacadoId] = SacadoInfo({
            cnpj: cnpj,
            carteiraSacado: carteiraSacado,
            limiteExposicao: limiteExposicao,
            exposicaoAtual: 0,
            status: status,
            dataRegistro: block.timestamp,
            ativo: true
        });

        s.sacadoPorCarteira[carteiraSacado] = sacadoId;
        s.sacadoIds.push(sacadoId);

        emit SacadoRegistered(sacadoId, cnpj, carteiraSacado, status);
    }

    /**
     * @notice CREDITOR REGISTRATION - Function to register approved creditors
     * @dev Minimal on-chain data after off-chain validation
     *
     * @param cnpj Creditor's CNPJ
     * @param carteiraCedente Creditor's wallet address
     * @param limiteAntecipacao Anticipation limit in stable tokens (WAD)
     * @param status Creditor's status
     */
    function registerCreditor(
        string calldata cnpj,
        address carteiraCedente,
        uint256 limiteAntecipacao,
        StatusCedente status
    ) external {
        RegistryState storage s = registryState();
        // Validation done in UnifiedFactoryManager

        bytes32 cedenteId = keccak256(abi.encodePacked(cnpj));
        require(s.cedentes[cedenteId].carteiraCedente == address(0), "Creditor already registered");
        require(s.cedentePorCarteira[carteiraCedente] == bytes32(0), "Wallet already registered");

        s.cedentes[cedenteId] = CedenteInfo({
            cnpj: cnpj,
            carteiraCedente: carteiraCedente,
            limiteAntecipacao: limiteAntecipacao,
            exposicaoAtual: 0,
            status: status,
            dataRegistro: block.timestamp,
            ativo: true
        });

        s.cedentePorCarteira[carteiraCedente] = cedenteId;
        s.cedenteIds.push(cedenteId);

        emit CedenteRegistered(cedenteId, cnpj, carteiraCedente, status);
    }

    /**
     * @notice UPDATES DEBTOR EXPOSURE LIMIT
     * @dev Allows increasing or decreasing exposure limit of a registered debtor
     *
     * @param sacadoId Debtor ID (keccak256(cnpj))
     * @param novoLimite New exposure limit (WAD)
     */
    function updateDebtorExposureLimit(bytes32 sacadoId, uint256 novoLimite) external {
        RegistryState storage s = registryState();

        require(s.sacados[sacadoId].carteiraSacado != address(0), "Debtor not registered");
        require(novoLimite >= s.sacados[sacadoId].exposicaoAtual, "New limit must be >= current exposure");

        uint256 limiteAnterior = s.sacados[sacadoId].limiteExposicao;
        s.sacados[sacadoId].limiteExposicao = novoLimite;

        emit DebtorLimitUpdated(sacadoId, limiteAnterior, novoLimite);
    }

    /**
     * @notice UPDATES CREDITOR ANTICIPATION LIMIT
     * @dev Allows increasing or decreasing anticipation limit of a registered creditor
     *
     * @param cedenteId Creditor ID (keccak256(cnpj))
     * @param novoLimite New anticipation limit (WAD)
     */
    function updateCreditorAnticipationLimit(bytes32 cedenteId, uint256 novoLimite) external {
        RegistryState storage s = registryState();

        require(s.cedentes[cedenteId].carteiraCedente != address(0), "Cedente not registered");
        require(novoLimite >= s.cedentes[cedenteId].exposicaoAtual, "New limit must be >= current exposure");

        uint256 limiteAnterior = s.cedentes[cedenteId].limiteAntecipacao;
        s.cedentes[cedenteId].limiteAntecipacao = novoLimite;

        emit CreditorLimitUpdated(cedenteId, limiteAnterior, novoLimite);
    }

    /**
     * @notice ADMIN REGISTERS RECEIVABLE ON BEHALF OF DEBTOR
     * @dev Allows admin to register receivable without rate limiting and without needing to be the debtor
     *
     * @param debtorWallet Debtor's wallet address
     * @param creditorAddr Creditor address that can anticipate
     * @param identificador Unique identifier (NF-e key or similar)
     * @param valorNominal Nominal value in stable tokens (WAD)
     * @param dataVencimento Maturity date (timestamp)
     * @return recebivelId Unique receivable ID
     */
    function adminRegisterReceivable(
        address debtorWallet,
        address creditorAddr,
        string calldata identificador,
        uint256 valorNominal,
        uint256 dataVencimento
    ) external returns (bytes32 recebivelId) {
        RegistryState storage s = registryState();

        // ✅ SECURITY: Validate basic inputs
        require(debtorWallet != address(0), "Invalid debtor address");
        require(creditorAddr != address(0), "Invalid creditor address");
        require(bytes(identificador).length > 0 && bytes(identificador).length <= 100, "Invalid identifier length");
        require(dataVencimento > block.timestamp, "Maturity date must be in future");

        // ✅ SECURITY: Validate that debtor is registered
        bytes32 sacadoId = s.sacadoPorCarteira[debtorWallet];
        require(sacadoId != bytes32(0), "Debtor not registered");
        require(s.sacados[sacadoId].ativo, "Debtor not active");
        require(s.sacados[sacadoId].status == StatusSacado.APROVADO, "Debtor not approved");

        // ✅ SECURITY: Validate that creditor is registered
        bytes32 cedenteId = s.cedentePorCarteira[creditorAddr];
        require(cedenteId != bytes32(0), "Creditor not registered");
        require(s.cedentes[cedenteId].ativo, "Creditor not active");

        // ✅ SECURITY: Validate term (dataVencimento already validated above, so subtraction is safe)
        // Note: Removed 365 day limit - allows receivables of any future term
        uint256 prazo = (dataVencimento - block.timestamp) / 1 days;
        require(prazo > 0, "Invalid term"); // Only validates it's in the future

        // ✅ SECURITY: Validate value
        require(valorNominal > 0 && valorNominal <= type(uint128).max, "Invalid nominal value");

        // Check debtor exposure
        require(s.sacados[sacadoId].limiteExposicao >= s.sacados[sacadoId].exposicaoAtual, "Invalid current exposure");
        uint256 novaExposicao = s.sacados[sacadoId].exposicaoAtual + valorNominal;
        require(novaExposicao >= s.sacados[sacadoId].exposicaoAtual, "Exposure overflow");
        require(novaExposicao <= s.sacados[sacadoId].limiteExposicao, "Exceeds debtor exposure limit");

        // #3: Create unique receivable ID with nonce to avoid collision
        // Use incremental nonce to ensure uniqueness even in same block
        recebivelId = keccak256(abi.encodePacked(debtorWallet, creditorAddr, identificador, ++s.recebivelNonce));

        // Check uniqueness (prevents overwrite)
        require(s.recebiveis[recebivelId].dataRegistro == 0, "Receivable ID already exists");

        // ✅ EFFECTS: Update state
        s.recebiveis[recebivelId] = RecebivelInfo({
            proprietarioId: sacadoId,
            proprietarioAddr: debtorWallet,
            cedenteAddr: creditorAddr,
            sacadoAddr: debtorWallet,
            identificador: identificador,
            valorNominal: valorNominal,
            valorRestante: valorNominal,
            dataVencimento: dataVencimento,
            status: StatusRecebivel.APROVADO_SACADO, // Already approved automatically
            dataRegistro: block.timestamp,
            dataUltimoPagamento: 0,
            ativo: true
        });

        // Index
        s.recebiveisPorProprietario[sacadoId].push(recebivelId);

        // Update debtor exposure
        s.sacados[sacadoId].exposicaoAtual = novaExposicao;

        // ✅ Emit event
        emit RecebivelRegistered(recebivelId, debtorWallet, creditorAddr, debtorWallet, identificador, valorNominal);
        emit RecebivelAprovado(recebivelId, debtorWallet);
    }

    /**
     * @notice DEBTOR APPROVES RECEIVABLE - Debtor approves receivable registered by creditor
     * @dev Allows debtor to approve receivables registered by creditors
     *
     * @param recebivelId Receivable ID to approve
     */
    function debtorApproveReceivable(bytes32 recebivelId) external {
        RegistryState storage s = registryState();

        RecebivelInfo storage recebivel = s.recebiveis[recebivelId];
        require(recebivel.ativo, "Receivable not active");
        require(recebivel.status == StatusRecebivel.REGISTRADO, "Receivable not pending approval");

        // Validate that caller is the correct debtor
        require(msg.sender == recebivel.sacadoAddr, "Only debtor can approve");

        // Validate that caller is registered debtor
        bytes32 sacadoId = s.sacadoPorCarteira[msg.sender];
        require(sacadoId != bytes32(0), "Not registered as debtor");
        require(s.sacados[sacadoId].ativo, "Debtor not active");
        require(s.sacados[sacadoId].status == StatusSacado.APROVADO, "Debtor not approved");

        // Check debtor exposure with overflow validation
        require(s.sacados[sacadoId].limiteExposicao >= s.sacados[sacadoId].exposicaoAtual, "Invalid current exposure");
        uint256 novaExposicao = s.sacados[sacadoId].exposicaoAtual + recebivel.valorNominal;
        require(novaExposicao >= s.sacados[sacadoId].exposicaoAtual, "Exposure overflow"); // Overflow check
        require(novaExposicao <= s.sacados[sacadoId].limiteExposicao, "Exceeds debtor exposure limit");

        // Approve receivable
        recebivel.status = StatusRecebivel.APROVADO_SACADO;

        // Update debtor exposure
        s.sacados[sacadoId].exposicaoAtual = novaExposicao;

        emit RecebivelAprovado(recebivelId, msg.sender);
    }

    /**
     * @notice VALIDATES RECEIVABLE FOR ANTICIPATION
     * @dev Validates if a receivable can be anticipated
     *
     * @param recebivelId Receivable ID
     * @param valorAntecipacao Requested anticipation amount (native decimals)
     * @return valido True if valid
     * @return motivo Reason if invalid
     */
    function validateReceivableForAnticipation(bytes32 recebivelId, uint256 valorAntecipacao)
        external
        view
        returns (bool valido, string memory motivo)
    {
        RegistryState storage s = registryState();

        RecebivelInfo memory recebivel = s.recebiveis[recebivelId];
        if (!recebivel.ativo) return (false, "RECEIVABLE_INACTIVE");

        // Receivable must be approved by debtor
        if (recebivel.status != StatusRecebivel.APROVADO_SACADO) {
            return (false, "RECEIVABLE_NOT_APPROVED");
        }

        if (valorAntecipacao > recebivel.valorRestante) {
            return (false, "VALUE_EXCEEDS_RECEIVABLE");
        }

        // Validate creditor
        bytes32 cedenteId = s.cedentePorCarteira[recebivel.cedenteAddr];
        if (cedenteId == bytes32(0)) return (false, "CREDITOR_INVALID");

        CedenteInfo memory cedente = s.cedentes[cedenteId];
        if (!cedente.ativo || cedente.status != StatusCedente.APROVADO) {
            return (false, "CREDITOR_INVALID");
        }

        // Check creditor exposure limit
        if (cedente.exposicaoAtual + valorAntecipacao > cedente.limiteAntecipacao) {
            return (false, "CREDITOR_LIMIT_EXCEEDED");
        }

        // #4: Check term (prevent underflow)
        // Check before subtracting to avoid revert in Solidity 0.8+
        if (recebivel.dataVencimento <= block.timestamp) {
            return (false, "TERM_INVALID");
        }
        uint256 prazoRestante = (recebivel.dataVencimento - block.timestamp) / 1 days;
        if (prazoRestante == 0) {
            return (false, "TERM_INVALID");
        }

        return (true, "");
    }

    /**
     * @notice ANTICIPATION WITH APPROVED RECEIVABLE (struct overload - reduces stack depth)
     */
    function anticipateWithReceivable(AnticipationCallParams calldata p) external returns (uint256 operationId) {
        return _anticipateWithReceivableImpl(p);
    }

    /**
     * @notice ANTICIPATION WITH APPROVED RECEIVABLE (scalar params - for backward compatibility)
     */
    function anticipateWithReceivable(
        uint256 fidcId,
        address fidcAddress,
        bytes32 recebivelId,
        uint256 valorAntecipacao,
        address colToken,
        uint256 collateralAmount,
        address captationAddress,
        CollateralTokenType collateralType,
        uint256 collateralTokenId,
        uint256 collateralTokenAmount,
        CollateralCustodyType collateralCustody,
        address collateralDestination
    ) external returns (uint256 operationId) {
        AnticipationCallParams memory p = AnticipationCallParams({
            fidcId: fidcId,
            fidcAddress: fidcAddress,
            recebivelId: recebivelId,
            valorAntecipacao: valorAntecipacao,
            colToken: colToken,
            collateralAmount: collateralAmount,
            captationAddress: captationAddress,
            collateralType: collateralType,
            collateralTokenId: collateralTokenId,
            collateralTokenAmount: collateralTokenAmount,
            collateralCustody: collateralCustody,
            collateralDestination: collateralDestination
        });
        return _anticipateWithReceivableImpl(p);
    }

    /**
     * @dev Internal implementation of anticipation logic (uses struct to avoid stack-too-deep)
     */
    function _anticipateWithReceivableImpl(AnticipationCallParams memory p) internal returns (uint256 operationId) {
        RegistryState storage s = registryState();

        // ✅ FIX HIGH: Basic input validations
        if (p.fidcAddress == address(0)) revert ZeroAddress();
        if (p.valorAntecipacao == 0) revert ZeroAmount();
        if (p.collateralAmount == 0) revert ZeroAmount();

        if (
            p.collateralType == CollateralTokenType.ERC20 || p.collateralType == CollateralTokenType.ERC721
                || p.collateralType == CollateralTokenType.ERC1155
        ) {
            if (p.colToken == address(0)) revert ZeroAddress();
        }
        if (p.collateralType == CollateralTokenType.ERC721) {
            if (p.collateralTokenAmount != 1) revert InvalidCollateralAmount();
        } else if (p.collateralType == CollateralTokenType.ERC1155) {
            if (p.collateralTokenAmount == 0) revert InvalidCollateralAmount();
        }

        if (p.collateralType == CollateralTokenType.ERC721 || p.collateralType == CollateralTokenType.ERC1155) {
            if (
                p.collateralCustody != CollateralCustodyType.CONTRACT_LOCK
                    && p.collateralCustody != CollateralCustodyType.EXTERNAL_WALLET
            ) {
                revert InvalidCollateralAmount();
            }
            if (p.collateralCustody == CollateralCustodyType.EXTERNAL_WALLET && p.collateralDestination == address(0)) {
                revert ZeroAddress();
            }
        }

        // Get stable token and decimals BEFORE validating to convert values
        address stableToken = IFIDC_Optimized(p.fidcAddress).getStableToken();
        uint8 stableDecimals = IERC20Metadata(stableToken).decimals();

        // Convert values from native decimals to WAD (for internal use with FIDC)
        uint256 valorAntecipacaoWad = YieldCalculator.scaleToWad(p.valorAntecipacao, stableDecimals);
        uint256 collateralAmountWad = YieldCalculator.scaleToWad(p.collateralAmount, stableDecimals);

        // Validate receivable
        RecebivelInfo storage recebivel = s.recebiveis[p.recebivelId];
        require(recebivel.ativo, "RECEIVABLE_INACTIVE");
        require(recebivel.status == StatusRecebivel.APROVADO_SACADO, "RECEIVABLE_NOT_APPROVED");
        // Compare in native decimals (recebivel.valorRestante is in native)
        require(p.valorAntecipacao <= recebivel.valorRestante, "VALUE_EXCEEDS_RECEIVABLE");

        // Validate registered creditor (uses recebivel.cedenteAddr, not msg.sender, as admin can execute)
        bytes32 cedenteId = s.cedentePorCarteira[recebivel.cedenteAddr];
        require(cedenteId != bytes32(0), "Creditor not registered");

        CedenteInfo storage cedente = s.cedentes[cedenteId];
        require(cedente.ativo && cedente.status == StatusCedente.APROVADO, "Creditor not approved");

        // Check creditor exposure limit with overflow validation
        require(cedente.limiteAntecipacao >= cedente.exposicaoAtual, "Invalid creditor exposure");
        uint256 novaExposicaoCedente = cedente.exposicaoAtual + p.valorAntecipacao; // Use native value
        require(novaExposicaoCedente >= cedente.exposicaoAtual, "Creditor exposure overflow"); // Overflow check
        require(novaExposicaoCedente <= cedente.limiteAntecipacao, "CREDITOR_LIMIT_EXCEEDED");

        // ✅ SECURITY: Validate that FIDC is known/registered
        assertKnownFIDC(p.fidcAddress);

        // Validate FIDC is a valid contract (already obtained above)

        // Transfer funds using WAD values (for _transferFunds)
        // This function decides which method to use (anticipateWithRatio or anticipateWithRatioSkipTransfer)
        _transferFunds(
            recebivel.cedenteAddr,
            valorAntecipacaoWad, // Pass in WAD
            p.colToken,
            collateralAmountWad, // Pass in WAD
            p.captationAddress,
            p.fidcId, // Pass fidcId to use vault per FIDC
            p.fidcAddress
        );

        // Lock NFT collateral if applicable (ERC721/1155). CONTRACT_LOCK → NFT vai para o FIDC Diamond (fidcAddress).
        if (p.collateralType == CollateralTokenType.ERC721 || p.collateralType == CollateralTokenType.ERC1155) {
            _lockNFTCollateral(
                p.collateralType,
                p.collateralCustody,
                recebivel.cedenteAddr,
                p.colToken,
                p.collateralTokenId,
                p.collateralTokenAmount,
                p.collateralDestination,
                p.fidcAddress
            );
        }

        // ✅ CRITICAL FIX: Use 1-based IDs to avoid collision with mapping default (0)
        // If starting at 0, receivableToOperation[recebivelId] = 0 is indistinguishable from "not set"
        operationId = ++fidcState().nextAnticipationId; // First ID will be 1
        fidcState().anticipations[operationId] = AnticipationRecord({
            operationId: operationId,
            receivableId: p.recebivelId, // Link receivable to operation
            fidcAddress: p.fidcAddress,
            cedente: recebivel.cedenteAddr,
            amount: p.valorAntecipacao, // Store in native decimals (for backend)
            collateralAmount: p.collateralAmount, // Store in native decimals (for backend)
            collateralRemaining: p.collateralAmount, // Initially equal to total
            colToken: p.colToken,
            captationAddress: p.captationAddress,
            timestamp: block.timestamp,
            active: true,
            collateralType: p.collateralType,
            collateralTokenId: p.collateralTokenId,
            collateralTokenAmount: p.collateralTokenAmount,
            collateralCustody: p.collateralCustody,
            collateralDestination: p.collateralDestination,
            collateralExternalConsumed: 0,
            collateralReleased: false
        });

        // Link receivable to operation for correct accounting
        s.receivableToOperation[p.recebivelId] = operationId;
        s.operationToReceivable[operationId] = p.recebivelId;

        // Event removed - UnifiedFactoryManager emits the event

        // Update creditor exposure (already validated above)
        cedente.exposicaoAtual = novaExposicaoCedente;

        // Update receivable status
        recebivel.status = StatusRecebivel.ANTECIPADO;
        recebivel.valorRestante -= p.valorAntecipacao; // Use value in native decimals

        emit RecebivelAntecipado(p.recebivelId, operationId, p.valorAntecipacao);
    }

    /**
     * @notice REGISTER RECEIVABLE PAYMENT
     * @dev Registers partial or full payment of receivable
     *
     * @param recebivelId Receivable ID
     * @param valorPagamento Payment amount
     * @param proofHash Payment proof hash
     */
    function registerReceivablePayment(bytes32 recebivelId, uint256 valorPagamento, bytes32 proofHash) external {
        RegistryState storage s = registryState();
        // Validation done in UnifiedFactoryManager

        RecebivelInfo storage recebivel = s.recebiveis[recebivelId];
        require(recebivel.ativo, "Receivable not active");
        require(valorPagamento > 0, "Payment amount must be positive");
        require(valorPagamento <= recebivel.valorRestante, "Payment exceeds remaining value");
        require(recebivel.valorNominal > 0, "Invalid nominal value");

        // Calculate paid percentage with full precision (avoid divide-before-multiply)
        uint256 percentualPago = Math.mulDiv(valorPagamento, 10000, recebivel.valorNominal);
        require(percentualPago <= 10000, "Invalid percentage");

        // Validate creditor exists
        bytes32 cedenteId = s.cedentePorCarteira[recebivel.cedenteAddr];
        require(cedenteId != bytes32(0), "Creditor not found");
        require(s.cedentes[cedenteId].ativo, "Creditor inactive");

        // ✅ FIX CRITICAL BUG #2: Release exposure from specific operation, not total creditor exposure
        // Find operationId linked to this receivable
        uint256 operationId = s.receivableToOperation[recebivelId];

        uint256 exposicaoLiberadaCedente = 0;
        uint256 exposicaoLiberadaSacado = 0;

        FIDCState storage fs = fidcState();
        if (operationId > 0 && fs.anticipations[operationId].active) {
            // Calculate exposure to release from specific operation
            AnticipationRecord storage anticipation = fs.anticipations[operationId];
            uint256 exposicaoOperacao = anticipation.amount;

            // Release proportional to receivable payment
            exposicaoLiberadaCedente = Math.mulDiv(exposicaoOperacao, percentualPago, 10000);
            if (exposicaoLiberadaCedente > s.cedentes[cedenteId].exposicaoAtual) {
                exposicaoLiberadaCedente = s.cedentes[cedenteId].exposicaoAtual;
            }
        } else {
            // Fallback: if no linked operation, use old method (compatibility)
            exposicaoLiberadaCedente = Math.mulDiv(s.cedentes[cedenteId].exposicaoAtual, percentualPago, 10000);
        }
        require(s.cedentes[cedenteId].exposicaoAtual >= exposicaoLiberadaCedente, "Exposicao insuficiente");

        // Liberar exposição do sacado proporcionalmente ao pagamento
        bytes32 sacadoId = recebivel.proprietarioId;
        if (sacadoId != bytes32(0) && s.sacados[sacadoId].ativo) {
            // Calcular exposição do sacado a liberar (proporcional ao valor nominal do recebível)
            exposicaoLiberadaSacado = Math.mulDiv(recebivel.valorNominal, percentualPago, 10000);
            if (exposicaoLiberadaSacado > s.sacados[sacadoId].exposicaoAtual) {
                exposicaoLiberadaSacado = s.sacados[sacadoId].exposicaoAtual;
            }
        }

        // ✅ CHECKS-EFFECTS-INTERACTIONS: Effects primeiro
        recebivel.valorRestante -= valorPagamento;
        recebivel.dataUltimoPagamento = block.timestamp;

        if (recebivel.valorRestante == 0) {
            recebivel.status = StatusRecebivel.PAGO;
        }

        // Liberar exposição do cedente (da operação específica)
        s.cedentes[cedenteId].exposicaoAtual -= exposicaoLiberadaCedente;

        // Liberar exposição do sacado
        if (exposicaoLiberadaSacado > 0) {
            s.sacados[sacadoId].exposicaoAtual -= exposicaoLiberadaSacado;
        }

        // ✅ Emissão de evento por último
        emit RecebivelPago(recebivelId, valorPagamento, recebivel.valorRestante, proofHash);
    }

    /* ═══════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════ */

    /**
     * @notice Query debtor information by ID
     */
    function getDebtor(bytes32 sacadoId) external view returns (SacadoInfo memory) {
        return registryState().sacados[sacadoId];
    }

    /**
     * @notice Query debtor information by wallet
     */
    function getDebtorByWallet(address carteira) external view returns (SacadoInfo memory) {
        RegistryState storage s = registryState();
        bytes32 sacadoId = s.sacadoPorCarteira[carteira];
        return s.sacados[sacadoId];
    }

    /**
     * @notice Query creditor information by ID
     */
    function getCreditor(bytes32 cedenteId) external view returns (CedenteInfo memory) {
        return registryState().cedentes[cedenteId];
    }

    /**
     * @notice Query creditor information by wallet
     */
    function getCreditorByWallet(address carteira) external view returns (CedenteInfo memory) {
        RegistryState storage s = registryState();
        bytes32 cedenteId = s.cedentePorCarteira[carteira];
        return s.cedentes[cedenteId];
    }

    /**
     * @notice Query receivable information
     */
    function getReceivable(bytes32 recebivelId) external view returns (RecebivelInfo memory) {
        return registryState().recebiveis[recebivelId];
    }

    /**
     * @notice List all registered debtors
     */
    function getDebtors() external view returns (bytes32[] memory) {
        return registryState().sacadoIds;
    }

    /**
     * @notice List all registered creditors
     */
    function getCreditors() external view returns (bytes32[] memory) {
        return registryState().cedenteIds;
    }

    /**
     * @notice List receivables by owner
     */
    function getReceivablesByOwner(bytes32 proprietarioId) external view returns (bytes32[] memory) {
        return registryState().recebiveisPorProprietario[proprietarioId];
    }

    /**
     * @notice Receivable compensation with collateral burning
     * @dev Returns actual collateral burned value for deterministic synchronization
     *
     * COMPLETE FLOW:
     * 1. Find anticipation by operationId
     * 2. Validate that anticipation is active
     * 3. Validate that collateralAmount does not exceed remaining collateral
     * 4. Call FIDC.compensateFor(payAmountWad, payer, debtor) which:
     *    - Receives payment from payer directly (via safeTransferFrom)
     *    - Burns proportional collateral automatically (via _compensateInternal)
     *    - Updates debtor exposure
     *    - Returns actual collateral burned value in WAD
     * 5. Convert burned value from WAD to native decimals
     * 6. Update collateralRemaining in record with ACTUAL returned value (in native)
     *
     * EXAMPLE:
     * - Total value to compensate: 120,000 (native stable, 6 decimals)
     * - Current payment: 1,200 (native stable) + 10% penalty = 1,320 (native stable)
     * - payAmount: 1,320 (native stable token, 6 decimals for USDC)
     * - collateralAmount: 1,200 (native colToken, 6 for USDC if colToken==0, or ERC20 token decimals)
     * - Return: actual burned value in native colToken (may differ slightly due to rounding)
     *
     * NOTE: Can be called multiple times for the same operationId (installment payment)
     *
     * IMPORTANT:
     * - payAmountNative must be in native stable token decimals (6 for USDC)
     * - collateralAmountNative must be in native colToken decimals (6 for USDC, 18 for WETH, etc.)
     * - If colToken == address(0) (internal receivable), collateralAmountNative is in native stable token decimals (e.g., 6 for USDC)
     * - Payer must have approval for FIDC Diamond before calling this function
     *
     * @param operationId Anticipation operation ID
     * @param payAmountNative Total amount to pay in native stable token decimals (6 for USDC)
     * @param collateralAmountNative Expected collateral amount to burn in native colToken decimals (for validation)
     * @param payer Address paying (debtor) - must have allowance for FIDC
     * @return collateralBurnedNative Actual collateral burned value in native colToken decimals
     */
    function compensateFor(uint256 operationId, uint256 payAmountNative, uint256 collateralAmountNative, address payer)
        internal
        returns (uint256 collateralBurnedNative)
    {
        FIDCState storage s = fidcState();

        // Basic validations
        if (payer == address(0)) revert ZeroAddress();
        if (payAmountNative == 0) revert ZeroAmount();
        if (collateralAmountNative == 0) revert InvalidCollateralAmount();

        // Find anticipation
        AnticipationRecord storage anticipation = s.anticipations[operationId];
        if (!anticipation.active) {
            revert AnticipationNotActive(operationId); // Custom error for production
        }

        // Validate that collateral to burn does not exceed remaining (both in native)
        require(collateralAmountNative <= anticipation.collateralRemaining, "Collateral amount exceeds remaining");

        // Validate that FIDC is a valid contract
        address fidcAddress = anticipation.fidcAddress;
        address stableToken = address(0);
        try IFIDC_Optimized(fidcAddress).getStableToken() returns (address token) {
            stableToken = token;
        } catch {
            revert FIDCDoesNotExist(0);
        }

        // ✅ COMPENSATION FLOW WITH COLLATERAL BURNING
        //
        // CURRENT FLOW:
        // 1. This function converts payAmountNative to WAD
        // 2. Calls FIDC.compensateFor(payAmountWad, payer, debtor)
        // 3. FIDC receives payment from payer directly (via safeTransferFrom)
        //    - Payer must have approval for FIDC Diamond
        // 4. FIDC burns proportional collateral automatically (via _compensateInternal)
        // 5. FIDC updates debtor exposure
        // 6. FIDC returns actual collateral burned value in WAD
        // 7. This function converts burnedWad to native
        // 8. This function updates collateralRemaining with actual returned value (in native)
        //
        // NOTE: Payment stays in FIDC after compensation (to distribute to investors via distributeWithYields)
        // If transfer to captationAddress is needed, it should be done separately via withdraw

        // Convert payAmount from native decimals to WAD (for FIDC)
        // payAmount comes in native stable token decimals (6 for USDC) from UnifiedFactoryManager
        uint8 stableDecimals = IERC20Metadata(stableToken).decimals();
        uint256 payAmountWad = YieldCalculator.scaleToWad(payAmountNative, stableDecimals);

        // ✅ CRITICAL FIX (PRODUCTION): Get collateral decimals correctly
        // In real flow, when colToken == address(0) (internal receivable),
        // the "collateralAmountNative" that Gateway passes is IN NATIVE STABLE DECIMALS (e.g., 6 for USDC),
        // and NOT in 18/WAD. So the conversion burnedWad -> native needs to use stableDecimals.
        // Otherwise, get ERC20 token decimals
        uint8 collateralDecimals;
        if (
            anticipation.colToken == address(0) || anticipation.collateralType == CollateralTokenType.ERC721
                || anticipation.collateralType == CollateralTokenType.ERC1155
        ) {
            collateralDecimals = stableDecimals;
        } else {
            collateralDecimals = IERC20Metadata(anticipation.colToken).decimals();
        }

        // ✅ NEW LOGIC: Call FIDC.compensateFor() which returns debt vs interest breakdown
        // FIDC will:
        // 1. Receive payment from payer (via safeTransferFrom) - converts WAD to native internally
        // 2. Separate what is debt (related to collateral) from what is interest (excess)
        // 3. Burn collateral proportional ONLY to debt (not to interest)
        // 4. Update debtor exposure
        // 5. Return breakdown: debtPaidWad, interestPaidWad, collateralBurnedWad, debtFullyPaid
        // Use burnedWad and debtFullyPaid (close operation when debt is fully paid even if collateral dust remains)
        (,, uint256 burnedWad, bool debtFullyPaid) =
            IFIDC_Optimized(fidcAddress).compensateFor(payAmountWad, payer, anticipation.cedente);

        // ✅ NEW LOGIC: Collateral is burned only proportionally to debt
        // Interest does not affect collateral, only paid to FIDC

        // ✅ CRITICAL FIX: Convert WAD -> native using correct collateral decimals (collateralDecimals)
        // collateralRemaining is stored in native colToken decimals
        // burnedWad is in WAD (18 decimals), needs to convert to native colToken decimals
        // Note: when colToken==0, collateralDecimals = stableDecimals (consistent with flow)
        uint256 burnedNative = YieldCalculator.scaleFromWad(burnedWad, collateralDecimals);

        // ✅ CRITICAL FIX: Use REAL burn returned by FIDC, not caller input
        // collateralAmountNative is only a maximum limit (security validation)
        // This ensures record stays synchronized with what was actually burned
        require(burnedNative <= collateralAmountNative, "Burn exceeds expected");

        // Update collateralRemaining with ACTUALLY burned value (deterministic)
        // Note: burnedNative <= collateralRemaining is already guaranteed by:
        // - collateralAmountNative <= anticipation.collateralRemaining (validation above)
        // - burnedNative <= collateralAmountNative (require above)
        anticipation.collateralRemaining -= burnedNative;

        // If collateral is held in an external wallet (off-chain custody), track logical utilization
        if (anticipation.collateralCustody == CollateralCustodyType.EXTERNAL_WALLET) {
            anticipation.collateralExternalConsumed += burnedNative;
        }

        // Return actual value burned by FIDC (for synchronization)
        collateralBurnedNative = burnedNative;

        // If collateral fully burned or FIDC reports debt fully paid, mark as inactive (allows release of dust for NFT/ERC1155)
        if (anticipation.collateralRemaining == 0 || debtFullyPaid) {
            anticipation.active = false;
        }

        // Event removed - UnifiedFactoryManager emits the event
        // Return actual burned value (in native)
        return collateralBurnedNative;
    }

    /**
     * @notice Mark collateral as released after the factory has transferred NFT/ERC1155 to destination
     * @dev Only callable by the factory (msg.sender == factoryAddress). Called by UnifiedFactoryManager after
     *      it has performed the actual transfer. Prevents double-release.
     * @param operationId Anticipation operation ID
     */
    function setCollateralReleased(uint256 operationId) external {
        FIDCState storage s = fidcState();
        // Allow: Unified proxy (factory), delegatecall context, or Factory Diamond (fidcFactoryManager)
        if (msg.sender != s.factoryAddress && msg.sender != s.fidcFactoryManager && address(this) != s.factoryAddress) {
            revert CallerNotFactory();
        }
        AnticipationRecord storage anticipation = s.anticipations[operationId];
        if (anticipation.operationId == 0) revert AnticipationNotActive(operationId);
        if (anticipation.collateralReleased) revert CollateralAlreadyReleased();
        anticipation.collateralReleased = true;
    }

    /* ═══════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════ */

    function getAnticipation(uint256 operationId) external view returns (AnticipationRecord memory) {
        return fidcState().anticipations[operationId];
    }
}

