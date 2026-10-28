// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FIDCModuleLib} from "./libraries/FIDCModuleLib.sol";
import {UnifiedOpsLib} from "./libraries/UnifiedOpsLib.sol";
import {IFIDC_Optimized} from "../interface/IFIDC_Optimized.sol";
import {ICapitareVault} from "./interface/ICapitareVault.sol";
import {IFactoryManagerYields, IUnifiedFactory} from "./interface/IUnifiedFactory.sol";
import {IFIDCFactoryManager} from "../interface/IFIDCFactoryManager.sol"; // used by onlyTenantOwner / _dia

/**
 * @title UnifiedFactoryManagerV3
 * @notice UUPS upgrade from V2 — adds reserved storage for Fase 4 (wrappers) and Fase 7 (per-tenant penalty cap),
 *         plus hardening of the assembly forward used by `createFIDC` (signature mismatch detection).
 * @dev Storage layout strictly preserved from V2 (slots 0-6). New mappings consume two slots from V2's __gap.
 *      Setters for the new mappings are intentionally NOT included in this version. They will be added in
 *      Fase 4 (`setWrapperAuthorization`) and Fase 7 (`setTenantPenaltyCap`) when the consuming logic ships.
 *      This keeps the V2→V3 upgrade strictly additive (storage-only) and minimizes the EIP-170 bytecode delta.
 * @author @Afonsodalvi — mobiup
 */
contract UnifiedFactoryManagerV3 is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    IUnifiedFactory
{
    using SafeERC20 for IERC20;

    /* ═══════════════════════ STORAGE V1 (DO NOT REORDER) ═══════════════════════ */

    address public companyAdmin; // slot 0
    address public fidcFactoryManager; // slot 1
    address public defaultProjectManager; // slot 2
    address public accountRegistry; // slot 3

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant ACCESS_CONTROLLER_ROLE = keccak256("ACCESS_CONTROLLER_ROLE");

    mapping(address => bool) public blacklist; // slot 4
    mapping(address => address) public tenantToProjectManager; // slot 5

    /* ═══════════════════════ STORAGE V2 (DO NOT REORDER) ═══════════════════════ */

    mapping(uint256 => mapping(address => bool)) public fidcOperators; // slot 6

    /* ═══════════════════════ STORAGE V3 (consumes 2 __gap slots) ═══════════════════════ */

    /// @notice Whitelist of FIDCs that authorize ERC-4626 wrappers (Fase 4) to invest on their behalf.
    /// @dev    Was __gap[0] in V2 (slot 7). Reading from V2 returned 0 (false). Safe upgrade.
    /// @dev    `internal` to keep EIP-170 budget. External read shipped via library getter in Fase 4.
    mapping(uint256 => bool) internal wrappersAuthorized; // slot 7

    /// @notice Per-tenant cap on penaltyBPS in compensateForBatch (Fase 7). 0 = fallback to MAX_PENALTY_BPS.
    /// @dev    Was __gap[1] in V2 (slot 8). Reading from V2 returned 0. Safe upgrade.
    /// @dev    `internal` to keep EIP-170 budget. External read shipped via library getter in Fase 7.
    mapping(address => uint256) internal penaltyCapByTenant; // slot 8

    /// @dev Gap reduced from 49 (V2) to 47 (V3). Slots 9-55 reserved for future upgrades.
    uint256[47] private __gap;

    /* ═══════════════════════ MODIFIERS ═══════════════════════ */

    modifier notBlacklisted(address addr) {
        if (blacklist[addr]) revert IsBlacklisted(addr);
        _;
    }

    modifier onlyTenantOwner(uint256 fidcId) {
        if (!fidcOperators[fidcId][msg.sender]) {
            address fm = fidcFactoryManager;
            if (fm == address(0)) revert InvalidInput();
            address o = IFIDCFactoryManager(fm).getTenantOwner(fidcId);
            if (o == address(0) || msg.sender != o) revert InvalidInput();
        }
        _;
    }

    /* ═══════════════════════ CONSTRUCTOR & INIT ═══════════════════════ */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _companyAdmin, address _fidcFactoryManager, address _defaultProjectManager)
        external
        initializer
    {
        if (_companyAdmin == address(0)) revert InvalidInput();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _companyAdmin);
        _grantRole(ACCESS_CONTROLLER_ROLE, _companyAdmin);
        _grantRole(PAUSER_ROLE, _companyAdmin);
        companyAdmin = _companyAdmin;
        fidcFactoryManager = _fidcFactoryManager;
        defaultProjectManager = _defaultProjectManager;
        FIDCModuleLib.setFactoryAddress(address(this));
        FIDCModuleLib.setFIDCFactoryManager(_fidcFactoryManager);
        emit CompanyAdminUpdated(_companyAdmin);
        emit ManagerInitialized(address(this));
    }

    /* ═══════════════════════ INTERNAL HELPERS ═══════════════════════ */

    function _dia(uint256 fidcId) internal view returns (address d) {
        address fm = fidcFactoryManager;
        if (fm == address(0)) revert InvalidInput();
        d = IFIDCFactoryManager(fm).getFIDC(fidcId);
        if (d == address(0)) revert InvalidInput();
    }

    function _fwd(address t, bytes memory cd) internal {
        (bool ok, bytes memory ret) = t.call(cd);
        assembly {
            if iszero(ok) { revert(add(ret, 0x20), mload(ret)) }
            return(add(ret, 0x20), mload(ret))
        }
    }

    function _fwdView(address t, bytes memory cd) internal view {
        (bool ok, bytes memory ret) = t.staticcall(cd);
        assembly {
            if iszero(ok) { revert(add(ret, 0x20), mload(ret)) }
            return(add(ret, 0x20), mload(ret))
        }
    }

    /* ═══════════════════════ FIDC CORE ═══════════════════════ */

    /// @notice Creates a new FIDC by forwarding the call payload to FactoryManagerDiamond.
    /// @dev    V3 hardens the assembly forward: enforces that the target returns exactly 96 bytes
    ///         (the ABI-encoding of `(uint256, address, address)`). Any other shape implies a signature
    ///         mismatch (e.g. a FactoryManagerDiamond upgrade that altered `createFIDC` return type)
    ///         and reverts with `CreateFIDCSignatureMismatch()`. This prevents silent data corruption
    ///         that would have been produced by `abi.decode` of malformed return data.
    function createFIDC(
        string memory,
        address,
        address,
        address,
        string memory,
        string memory,
        uint32,
        uint32,
        uint32,
        uint32,
        uint256,
        uint256,
        uint256,
        uint256,
        uint32,
        address,
        uint256
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused returns (uint256, address, address) {
        if (fidcFactoryManager == address(0)) revert InvalidInput();
        bytes memory ret;
        address fm = fidcFactoryManager;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let dataSize := calldatasize()
            calldatacopy(ptr, 0, dataSize)
            let success := call(gas(), fm, 0, ptr, dataSize, 0, 0)
            let retSize := returndatasize()
            ret := ptr
            mstore(ret, retSize)
            returndatacopy(add(ret, 0x20), 0, retSize)
            mstore(0x40, add(ret, and(add(add(retSize, 0x20), 0x1f), not(0x1f))))
            if iszero(success) { revert(add(ret, 0x20), retSize) }
        }
        // V3 hardening: verify ABI shape before decode. 96 = 3 * 32 bytes (uint256, address, address).
        // Reuses InvalidInput() (already in IUnifiedFactory) to stay under EIP-170 budget.
        if (ret.length != 96) revert InvalidInput();
        (uint256 fidcId, address fidcAddress, address recebivelAddress) = abi.decode(ret, (uint256, address, address));
        emit FIDCCreated(fidcId, fidcAddress, recebivelAddress);
        return (fidcId, fidcAddress, recebivelAddress);
    }

    function compensateFor(
        uint256 fidcId,
        uint256 operationId,
        uint256 payAmount,
        uint256 collateralAmount,
        address payer
    ) external onlyTenantOwner(fidcId) whenNotPaused nonReentrant notBlacklisted(payer) {
        FIDCModuleLib.AnticipationRecord memory ant = FIDCModuleLib.getAnticipation(operationId);
        if (FIDCModuleLib.getFIDC(fidcId) != ant.fidcAddress) revert InvalidInput();
        if (blacklist[ant.cedente]) revert IsBlacklisted(ant.cedente);
        FIDCModuleLib.compensateFor(operationId, payAmount, collateralAmount, payer);
        emit AnticipationCompensated(operationId, ant.fidcAddress, ant.cedente, payAmount, ant.captationAddress);
    }

    function executeReleaseCollateralByFactoryManager(uint256 fidcId, uint256 operationId, address destination)
        external
        whenNotPaused
        nonReentrant
    {
        // V3: body offloaded to UnifiedOpsLib.executeReleaseCollateral to free EIP-170 budget.
        // Behavior + access control + event are byte-equivalent to V2.
        UnifiedOpsLib.executeReleaseCollateral(fidcId, operationId, destination);
    }

    /* ═══════════════════════ REGISTRY ═══════════════════════ */

    function registerDebtor(
        string calldata cnpj,
        address debtorWallet,
        uint256 maxExposure,
        FIDCModuleLib.StatusSacado status
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        FIDCModuleLib.registerDebtor(cnpj, debtorWallet, maxExposure, status);
    }

    function registerCreditor(
        string calldata cnpj,
        address creditorWallet,
        uint256 maxAnticipation,
        FIDCModuleLib.StatusCedente status
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        FIDCModuleLib.registerCreditor(cnpj, creditorWallet, maxAnticipation, status);
    }

    function updateDebtorLimit(string calldata cnpj, uint256 newLimit)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        FIDCModuleLib.updateDebtorExposureLimit(keccak256(abi.encodePacked(cnpj)), newLimit);
    }

    function updateCreditorLimit(string calldata cnpj, uint256 newLimit)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        FIDCModuleLib.updateCreditorAnticipationLimit(keccak256(abi.encodePacked(cnpj)), newLimit);
    }

    function debtorApproveReceivable(bytes32 receivableId) external whenNotPaused notBlacklisted(msg.sender) {
        FIDCModuleLib.debtorApproveReceivable(receivableId);
    }

    function adminRegisterReceivable(
        address debtorWallet,
        address creditorAddr,
        string calldata identifier,
        uint256 nominalValue,
        uint256 dueDate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused returns (bytes32) {
        return FIDCModuleLib.adminRegisterReceivable(debtorWallet, creditorAddr, identifier, nominalValue, dueDate);
    }

    function anticipateWithReceivable(uint256 fidcId, FIDCModuleLib.AnticipationRequest calldata req)
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        nonReentrant
        returns (uint256 operationId)
    {
        FIDCModuleLib.RecebivelInfo memory rec = FIDCModuleLib.getReceivable(req.receivableId);
        if (blacklist[rec.cedenteAddr]) revert IsBlacklisted(rec.cedenteAddr);
        operationId = UnifiedOpsLib.anticipateFromEncoded(fidcId, req);
        emit AnticipationExecuted(
            operationId,
            FIDCModuleLib.getFIDC(fidcId),
            rec.cedenteAddr,
            req.anticipationAmount,
            req.collateralAmount,
            req.colToken,
            req.captationAddress
        );
    }

    function registerReceivablePayment(bytes32 receivableId, uint256 paymentAmount, bytes32 proofHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        FIDCModuleLib.registerReceivablePayment(receivableId, paymentAmount, proofHash);
    }

    function validateReceivableForAnticipation(bytes32 receivableId, uint256 anticipationAmount)
        external
        view
        returns (bool valid, string memory reason)
    {
        return FIDCModuleLib.validateReceivableForAnticipation(receivableId, anticipationAmount);
    }

    /* ═══════════════════════ VIEW FUNCTIONS ═══════════════════════ */

    function getDebtor(bytes32 id) external view returns (FIDCModuleLib.SacadoInfo memory) {
        return FIDCModuleLib.getDebtor(id);
    }

    function getDebtorByWallet(address w) external view returns (FIDCModuleLib.SacadoInfo memory) {
        return FIDCModuleLib.getDebtorByWallet(w);
    }

    function getCreditor(bytes32 id) external view returns (FIDCModuleLib.CedenteInfo memory) {
        return FIDCModuleLib.getCreditor(id);
    }

    function getCreditorByWallet(address w) external view returns (FIDCModuleLib.CedenteInfo memory) {
        return FIDCModuleLib.getCreditorByWallet(w);
    }

    function getReceivable(bytes32 id) external view returns (FIDCModuleLib.RecebivelInfo memory) {
        return FIDCModuleLib.getReceivable(id);
    }

    function getVaultForFIDC(uint256 fidcId) external view returns (address) {
        return FIDCModuleLib.getVaultForFIDC(fidcId);
    }

    function getTenantContract(uint256 fidcId) external view returns (address) {
        return FIDCModuleLib.getTenantContract(fidcId);
    }

    function getAnticipation(uint256 opId) external view returns (FIDCModuleLib.AnticipationRecord memory) {
        return FIDCModuleLib.getAnticipation(opId);
    }

    /* ═══════════════════════ DISTRIBUTION (assembly-forwarded) ═══════════════════════ */

    function distributeWithYieldsBatch(
        uint256 fidcId,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS
    )
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        returns (uint256, uint256, uint256, bool, uint256, uint256, bool, uint256, uint256, bool)
    {
        address d = _dia(fidcId);
        UnifiedOpsLib.prefundForDistribution(
            fidcId, d, serieId, seniorYieldBPS, mezzYieldBPS, juniorYieldBPS, batchPercentBPS
        );
        _fwd(
            d,
            abi.encodeWithSelector(
                IFIDC_Optimized.distributeWithYieldsBatchUnified.selector,
                serieId,
                seniorYieldBPS,
                mezzYieldBPS,
                juniorYieldBPS,
                batchPercentBPS
            )
        );
    }

    function distributeWithYieldsBatchAt(
        uint256 fidcId,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint64 periodEnd
    )
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        returns (uint256, uint256, uint256, bool, uint256, uint256, bool, uint256, uint256, bool)
    {
        _fwd(
            _dia(fidcId),
            abi.encodeWithSelector(
                IFIDC_Optimized.distributeWithYieldsBatchUnifiedAt.selector,
                serieId,
                seniorYieldBPS,
                mezzYieldBPS,
                juniorYieldBPS,
                batchPercentBPS,
                periodEnd
            )
        );
    }

    function amortizePrincipalBatchAt(
        uint256 fidcId,
        string calldata serieId,
        uint256 batchPercentBPS,
        uint256 maxAmortizationNative,
        uint64 periodEnd
    )
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        returns (uint256, uint256, uint256, bool, uint256, uint256, bool, uint256, uint256, bool)
    {
        _fwd(
            _dia(fidcId),
            abi.encodeWithSelector(
                IFIDC_Optimized.amortizePrincipalBatchUnifiedAt.selector,
                serieId,
                batchPercentBPS,
                maxAmortizationNative,
                periodEnd
            )
        );
    }

    /// @notice G1 — Forwarder p/ distribuição EXPLÍCITA (net por investidor,
    /// pós-retenção IR/IOF, calculado off-chain igual ao fan-out XRPL). Dá
    /// paridade EVM↔XRPL para séries com PF. O gateway tenta completar o
    /// prefund do Diamond via vault/wallet de captação antes do forward; se a
    /// fonte não tiver saldo/allowance suficiente, o facet reverte por
    /// InsufficientLiquidity sem pagar parcialmente. Idempotente por payoutId.
    function distributeExplicit(
        uint256 fidcId,
        string calldata serieId,
        address[] calldata investors,
        uint256[] calldata netAmounts,
        uint64 periodEnd,
        bytes32 payoutId
    ) external onlyTenantOwner(fidcId) whenNotPaused returns (uint256 total, uint256 count) {
        address d = _dia(fidcId);
        UnifiedOpsLib.prefundForExplicit(fidcId, d, netAmounts);
        _fwd(
            d,
            abi.encodeWithSelector(
                IFIDC_Optimized.distributeExplicit.selector, serieId, investors, netAmounts, periodEnd, payoutId
            )
        );
    }

    function calculateDistributionWithYieldsBatch(
        uint256 fidcId,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            bool,
            address[] memory,
            uint8[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        _fwdView(
            _dia(fidcId),
            abi.encodeWithSelector(
                IFIDC_Optimized.calculateDistributionWithYieldsBatch.selector,
                serieId,
                seniorYieldBPS,
                mezzYieldBPS,
                juniorYieldBPS,
                batchPercentBPS,
                startIndex
            )
        );
    }

    /* ═══════════════════════ SERIES MANAGEMENT ═══════════════════════ */

    function createFIDCSeries(
        uint256 fidcId,
        string calldata serieId,
        uint256 maxQuotas,
        bool allowSenior,
        bool allowMezz,
        bool allowJunior
    ) external onlyTenantOwner(fidcId) whenNotPaused {
        FIDCModuleLib.createFIDCSeries(fidcId, serieId, maxQuotas, allowSenior, allowMezz, allowJunior);
        emit FIDCSeriesCreated(fidcId, serieId, maxQuotas);
    }

    function updateFIDCSeriesMaxQuotas(uint256 fidcId, string calldata serieId, uint256 newMaxQuotas)
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
    {
        FIDCModuleLib.updateFIDCSeriesMaxQuotas(fidcId, serieId, newMaxQuotas);
        emit FIDCSeriesUpdated(fidcId, serieId, newMaxQuotas);
    }

    function deactivateFIDCSeries(uint256 fidcId, string calldata serieId)
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
    {
        FIDCModuleLib.deactivateFIDCSeries(fidcId, serieId);
        emit FIDCSeriesDeactivated(fidcId, serieId);
    }

    /* ═══════════════════════ INVEST ═══════════════════════ */

    function investValue(
        uint256 fidcId,
        string calldata purchaseId,
        address owner,
        uint8 classId,
        uint256 value,
        string calldata serieId
    ) external onlyTenantOwner(fidcId) whenNotPaused nonReentrant returns (uint256) {
        if (blacklist[owner]) revert IsBlacklisted(owner);
        return FIDCModuleLib.investInFIDC(fidcId, purchaseId, owner, classId, value, serieId);
    }

    function investBatch(
        uint256 fidcId,
        string calldata purchaseId,
        address owner,
        uint8[] calldata classIds,
        uint256[] calldata values,
        string calldata serieId
    ) external onlyTenantOwner(fidcId) whenNotPaused nonReentrant returns (uint256[] memory) {
        if (blacklist[owner]) revert IsBlacklisted(owner);
        return FIDCModuleLib.investBatchInFIDC(fidcId, purchaseId, owner, classIds, values, serieId);
    }

    /* ═══════════════════════ ADMIN ═══════════════════════ */

    function setAccountRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        accountRegistry = registry;
    }

    function setFIDCFactoryAddress() external onlyRole(DEFAULT_ADMIN_ROLE) {
        FIDCModuleLib.setFactoryAddress(address(this));
    }

    function setFIDCFactoryManager(address _fm) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_fm == address(0)) revert InvalidInput();
        address old = fidcFactoryManager;
        fidcFactoryManager = _fm;
        FIDCModuleLib.setFIDCFactoryManager(_fm);
        if (old != address(0)) emit SecurityAlert("FIDCFactoryManagerChanged", old, 0);
    }

    /* ═══════════════════════ VAULT & ESCROW ═══════════════════════ */

    function setFIDCVault(uint256 fidcId, address v) external onlyTenantOwner(fidcId) {
        FIDCModuleLib.setVaultForFIDC(fidcId, v);
        emit EscrowConfigured("fidc", v);
    }

    function transferFromVault(uint256 fidcId, address token, address to, uint256 amount, address customVaultAddr)
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        nonReentrant
    {
        address v = customVaultAddr != address(0) ? customVaultAddr : FIDCModuleLib.getVaultForFIDC(fidcId);
        if (v == address(0)) revert InvalidInput();
        ICapitareVault(v).authorizedTransfer(token, to, amount);
    }

    function collectFee(uint256 fidcId, uint256 amount, address manager)
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (amount == 0 || manager == address(0)) revert InvalidInput();
        address fa = FIDCModuleLib.getTenantContract(fidcId);
        if (fa == address(0)) revert InvalidInput();
        return IFIDC_Optimized(fa).collectFee(amount, manager);
    }

    /* ═══════════════════════ TENANT PROJECT MANAGER ═══════════════════════ */

    function setTenantProjectManager(address t, address pm) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0) || pm == address(0)) revert InvalidInput();
        tenantToProjectManager[t] = pm;
        emit TenantProjectManagerSet(t, pm);
    }

    function getTenantProjectManager(address t) external view returns (address) {
        return tenantToProjectManager[t];
    }

    /* ═══════════════════════ BLACKLIST ═══════════════════════ */

    function addToBlacklist(address addr, string calldata reason) external onlyRole(ACCESS_CONTROLLER_ROLE) {
        if (addr == address(0)) revert InvalidInput();
        blacklist[addr] = true;
        emit AddedToBlacklist(addr, reason);
    }

    function removeFromBlacklist(address addr, string calldata reason) external onlyRole(ACCESS_CONTROLLER_ROLE) {
        if (addr == address(0)) revert InvalidInput();
        blacklist[addr] = false;
        emit RemovedFromBlacklist(addr, reason);
    }

    function isBlacklisted(address addr) external view returns (bool) {
        return blacklist[addr];
    }

    /* ═══════════════════════ PAUSABLE & UPGRADE ═══════════════════════ */

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ═══════════════════════════════════════════════════════════════════ */
    /*                       V2 FEATURES (PRESERVED)                      */
    /* ═══════════════════════════════════════════════════════════════════ */

    /* ─────────────── OPERATOR MANAGEMENT ─────────────── */

    function setFIDCOperator(uint256 fidcId, address operator, bool authorized) external whenNotPaused {
        UnifiedOpsLib.setFIDCOperator(fidcId, operator, authorized);
    }

    function setFIDCOperatorsBatch(uint256 fidcId, address[] calldata operators, bool[] calldata authorized)
        external
        whenNotPaused
    {
        // Access control + storage write offloaded (EIP-170). Emits FIDCOperatorUpdated per item.
        UnifiedOpsLib.setFIDCOperatorsBatch(fidcId, operators, authorized);
    }

    function isFIDCOperator(uint256 fidcId, address operator) external view returns (bool) {
        return fidcOperators[fidcId][operator];
    }

    /* ─────────────── BATCH ANTICIPATION (1 or N) ─────────────── */

    /// @notice Anticipate one or more receivables in a single transaction
    /// @dev Each element in `encodedRequests` is an ABI-encoded AnticipationRequest.
    ///      For a single anticipation, pass an array with one element.
    ///      Designed to work with receivableIds returned by `adminRegisterReceivableBatch`.
    function anticipateWithReceivableBatchEncoded(uint256 fidcId, bytes[] calldata encodedRequests)
        external
        onlyTenantOwner(fidcId)
        whenNotPaused
        nonReentrant
        returns (uint256[] memory operationIds)
    {
        // Loop + events offloaded to UnifiedOpsLib (EIP-170). Selectors/ABI unchanged for queues.
        return UnifiedOpsLib.anticipateBatchEncoded(fidcId, encodedRequests);
    }

    /* ─────────────── BATCH RECEIVABLE REGISTRATION ─────────────── */

    function adminRegisterReceivableBatch(
        address[] calldata debtorWallets,
        address[] calldata creditorAddrs,
        string[] calldata identifiers,
        uint256[] calldata nominalValues,
        uint256[] calldata dueDates
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused returns (bytes32[] memory receivableIds) {
        receivableIds =
            UnifiedOpsLib.registerReceivableBatch(debtorWallets, creditorAddrs, identifiers, nominalValues, dueDates);
        emit BatchReceivablesRegistered(receivableIds.length, receivableIds);
    }

    /* ─────────────── BATCH COMPENSATION WITH PENALTY ─────────────── */

    function compensateForBatch(
        uint256 fidcId,
        uint256[] calldata operationIds,
        uint256[] calldata payAmounts,
        uint256[] calldata collateralAmounts,
        address payer,
        uint256 dueDate,
        uint256 penaltyBPS
    ) external onlyTenantOwner(fidcId) whenNotPaused nonReentrant notBlacklisted(payer) {
        // Length checks + R2-C-02 penalty cap live in UnifiedOpsLib (EIP-170).
        bool isLate = block.timestamp > dueDate;
        (uint256 totalPaid, uint256 totalPenalty) = UnifiedOpsLib.executeBatchCompensation(
            fidcId, operationIds, payAmounts, collateralAmounts, payer, isLate, penaltyBPS
        );
        emit BatchCompensated(fidcId, operationIds.length, isLate, penaltyBPS, totalPaid, totalPenalty);
    }

    /* ═══════════════════════════════════════════════════════════════════ */
    /*                       V3 NEW FEATURES                              */
    /* ═══════════════════════════════════════════════════════════════════ */

    /* ─────────────── WRAPPER AUTHORIZATION (Fase 4 enabler) ─────────────── */

    /// @notice Enables or disables ERC-4626 wrapper investment flow for a specific FIDC.
    /// @dev    AUDIT-FIX M-2: DEFAULT_ADMIN_ROLE or strict tenant owner ONLY (not operators).
    ///         Body offloaded to UnifiedOpsLib to keep this gateway under EIP-170.
    function setWrapperAuthorization(uint256 fidcId, bool authorized) external whenNotPaused {
        UnifiedOpsLib.setWrapperAuthorization(fidcId, authorized);
    }

    /// @notice Returns whether ERC-4626 wrappers are authorized to invest in the given FIDC.
    function isWrapperAuthorized(uint256 fidcId) external view returns (bool) {
        return UnifiedOpsLib.isWrapperAuthorized(fidcId);
    }

    /* ─────────────── TENANT PENALTY CAP (Fase 7) ─────────────── */

    /// @notice Sets a per-tenant cap on `penaltyBPS` accepted by `compensateForBatch`.
    /// @dev    Cap must be <= MAX_PENALTY_BPS. Zero clears (falls back to global cap).
    function setTenantPenaltyCap(uint256 cap) external {
        UnifiedOpsLib.setTenantPenaltyCap(cap);
    }

    /// @notice Returns the effective penalty cap for a tenant (custom value or global default).
    function getEffectivePenaltyCap(address tenant) public view returns (uint256) {
        return UnifiedOpsLib.getEffectivePenaltyCap(tenant);
    }
}
