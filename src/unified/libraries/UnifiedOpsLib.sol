// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {FIDCModuleLib} from "./FIDCModuleLib.sol";
import {IFIDC_Optimized} from "../../interface/IFIDC_Optimized.sol";
import {IUnifiedEscrow} from "../interface/IUnifiedEscrow.sol";
import {IUnifiedFactory} from "../interface/IUnifiedFactory.sol";
import {IFIDCFactoryManager} from "../../interface/IFIDCFactoryManager.sol";
import {YieldCalculator} from "../../libraries/YieldCalculator.sol";

/// @notice Minimal self-view into the gateway's per-tenant penalty cap (AUDIT-FIX R2-C-02).
/// @dev Implemented by UnifiedFactoryManagerV3; absent on V2 (handled via try/catch fallback to global MAX).
interface IPenaltyCapView {
    function getEffectivePenaltyCap(address tenant) external view returns (uint256);
}

/**
 * @title UnifiedOpsLib
 * @notice External library for heavy operations — keeps UnifiedFactoryManagerV2 under EIP-170 limit
 * @dev Called via DELEGATECALL, executes in caller's storage context
 */
library UnifiedOpsLib {
    error InvalidInput();
    error IsBlacklisted(address addr);
    /// @notice AUDIT-FIX R2-C-02: penaltyBPS exceeded the FIDC tenant owner's effective cap.
    error PenaltyCapExceeded();

    /// @dev Storage layout of UnifiedFactoryManagerV3 (UUPS proxy slots, not ERC-7201).
    ///      slot 1 = fidcFactoryManager; slot 7 = wrappersAuthorized; slot 8 = penaltyCapByTenant.
    uint256 private constant _SLOT_FIDC_FACTORY_MANAGER = 1;
    uint256 private constant _SLOT_WRAPPERS_AUTHORIZED = 7;
    uint256 private constant _SLOT_PENALTY_CAP_BY_TENANT = 8;
    bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;
    uint256 private constant _MAX_PENALTY_BPS = 5000;

    /* ─────────────── V3 SETTERS (EIP-170 offload) ─────────────── */

    /// @notice Writes `wrappersAuthorized[fidcId]` after DEFAULT_ADMIN_ROLE or tenant-owner check.
    /// @dev Must be DELEGATECALLed from UnifiedFactoryManagerV3 so storage slots align.
    function setWrapperAuthorization(uint256 fidcId, bool authorized) external {
        _requireAdminOrTenantOwner(fidcId);
        bytes32 slot = keccak256(abi.encode(fidcId, _SLOT_WRAPPERS_AUTHORIZED));
        assembly {
            sstore(slot, authorized)
        }
        emit IUnifiedFactory.WrapperAuthorizationUpdated(fidcId, authorized);
    }

    /// @notice Writes `penaltyCapByTenant[msg.sender]`. Cap must be <= 5000 BPS; 0 clears.
    function setTenantPenaltyCap(uint256 cap) external {
        if (cap > _MAX_PENALTY_BPS) revert InvalidInput();
        bytes32 slot = keccak256(abi.encode(msg.sender, _SLOT_PENALTY_CAP_BY_TENANT));
        assembly {
            sstore(slot, cap)
        }
        emit IUnifiedFactory.TenantPenaltyCapUpdated(msg.sender, cap);
    }

    function isWrapperAuthorized(uint256 fidcId) external view returns (bool authorized) {
        bytes32 slot = keccak256(abi.encode(fidcId, _SLOT_WRAPPERS_AUTHORIZED));
        assembly {
            authorized := sload(slot)
        }
    }

    function getEffectivePenaltyCap(address tenant) external view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(tenant, _SLOT_PENALTY_CAP_BY_TENANT));
        uint256 cap;
        assembly {
            cap := sload(slot)
        }
        return cap == 0 ? _MAX_PENALTY_BPS : cap;
    }

    function _requireAdminOrTenantOwner(uint256 fidcId) private view {
        if (IAccessControl(address(this)).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender)) return;
        address fm;
        assembly {
            fm := sload(_SLOT_FIDC_FACTORY_MANAGER)
        }
        if (fm == address(0)) revert InvalidInput();
        if (msg.sender != IFIDCFactoryManager(fm).getTenantOwner(fidcId)) revert InvalidInput();
    }

    /// @notice Batch anticipation (1..N) with per-item + batch events. DELEGATECALL from V3.
    /// @dev Caller must already enforce `onlyTenantOwner` / pause / reentrancy on the gateway.
    ///      Also enforces gateway `blacklist` (slot 4) on each receivable's cedente.
    function anticipateBatchEncoded(uint256 fidcId, bytes[] calldata encodedRequests)
        external
        returns (uint256[] memory operationIds)
    {
        uint256 len = encodedRequests.length;
        if (len == 0) revert IUnifiedFactory.EmptyBatch();
        operationIds = new uint256[](len);
        for (uint256 i; i < len;) {
            FIDCModuleLib.AnticipationRequest memory req =
                abi.decode(encodedRequests[i], (FIDCModuleLib.AnticipationRequest));
            FIDCModuleLib.RecebivelInfo memory rec = FIDCModuleLib.getReceivable(req.receivableId);
            if (_isBlacklisted(rec.cedenteAddr)) revert IsBlacklisted(rec.cedenteAddr);
            operationIds[i] = _anticipateFromEncoded(fidcId, req);
            emit IUnifiedFactory.AnticipationExecuted(
                operationIds[i],
                FIDCModuleLib.getFIDC(fidcId),
                rec.cedenteAddr,
                req.anticipationAmount,
                req.collateralAmount,
                req.colToken,
                req.captationAddress
            );
            unchecked {
                ++i;
            }
        }
        emit IUnifiedFactory.BatchAnticipationExecuted(fidcId, len, operationIds);
    }

    /// @notice Single operator setter. DELEGATECALL from V3 (writes slot-6 mapping).
    function setFIDCOperator(uint256 fidcId, address operator, bool authorized) external {
        _requireAdminOrTenantOwner(fidcId);
        if (operator == address(0)) revert InvalidInput();
        bytes32 outer = keccak256(abi.encode(fidcId, uint256(6)));
        bytes32 slot = keccak256(abi.encode(operator, outer));
        assembly {
            sstore(slot, authorized)
        }
        emit IUnifiedFactory.FIDCOperatorUpdated(fidcId, operator, authorized);
    }

    /// @notice Operator batch setter. DELEGATECALL from V3 (writes slot-6 mapping).
    function setFIDCOperatorsBatch(uint256 fidcId, address[] calldata operators, bool[] calldata authorized) external {
        _requireAdminOrTenantOwner(fidcId);
        uint256 len = operators.length;
        if (len == 0) revert IUnifiedFactory.EmptyBatch();
        if (len != authorized.length) revert IUnifiedFactory.ArrayLengthMismatch();
        for (uint256 i; i < len;) {
            if (operators[i] == address(0)) revert InvalidInput();
            bytes32 outer = keccak256(abi.encode(fidcId, uint256(6)));
            bytes32 slot = keccak256(abi.encode(operators[i], outer));
            bool auth = authorized[i];
            assembly {
                sstore(slot, auth)
            }
            emit IUnifiedFactory.FIDCOperatorUpdated(fidcId, operators[i], auth);
            unchecked {
                ++i;
            }
        }
    }

    function _isBlacklisted(address addr) private view returns (bool flagged) {
        bytes32 slot = keccak256(abi.encode(addr, uint256(4)));
        assembly {
            flagged := sload(slot)
        }
    }

    /* ─────────────── PREFUND FOR DISTRIBUTION ─────────────── */

    function prefundForDistribution(
        uint256 fidcId,
        address fidcDiamond,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS
    ) external {
        address cap = FIDCModuleLib.getCaptationAddressForFIDC(fidcId);
        if (cap == address(0)) {
            _emitFunding(fidcId, fidcDiamond, 0, "fidc");
            return;
        }
        (address stableToken, uint256 needed) =
            _getTotalNeededNative(fidcDiamond, serieId, seniorYieldBPS, mezzYieldBPS, juniorYieldBPS, batchPercentBPS);
        if (needed == 0) {
            _emitFunding(fidcId, fidcDiamond, 0, "fidc");
            return;
        }
        if (_tryTransferFromCaptation(fidcId, fidcDiamond, cap, stableToken, needed)) return;
        uint256 fidcBal = IERC20(stableToken).balanceOf(fidcDiamond);
        if (fidcBal >= needed) {
            _emitFunding(fidcId, fidcDiamond, 0, "fidc");
        } else {
            _emitFunding(fidcId, address(0), needed, "insufficient");
        }
    }

    function prefundForExplicit(uint256 fidcId, address fidcDiamond, uint256[] calldata netAmounts) external {
        uint256 totalNeededNative;
        uint256 len = netAmounts.length;
        for (uint256 i; i < len;) {
            totalNeededNative += netAmounts[i];
            unchecked {
                ++i;
            }
        }

        address stableToken = IFIDC_Optimized(fidcDiamond).getStableToken();
        _prefundNativeAmount(fidcId, fidcDiamond, stableToken, totalNeededNative);
    }

    function _prefundNativeAmount(uint256 fidcId, address fidcDiamond, address stableToken, uint256 totalNeededNative)
        private
    {
        if (totalNeededNative == 0) {
            _emitFunding(fidcId, fidcDiamond, 0, "fidc");
            return;
        }

        uint256 fidcBal = IERC20(stableToken).balanceOf(fidcDiamond);
        if (fidcBal >= totalNeededNative) {
            _emitFunding(fidcId, fidcDiamond, 0, "fidc");
            return;
        }

        uint256 shortfall = totalNeededNative - fidcBal;
        address cap = FIDCModuleLib.getCaptationAddressForFIDC(fidcId);
        if (cap != address(0) && _tryTransferFromCaptation(fidcId, fidcDiamond, cap, stableToken, shortfall)) {
            return;
        }

        fidcBal = IERC20(stableToken).balanceOf(fidcDiamond);
        if (fidcBal >= totalNeededNative) {
            _emitFunding(fidcId, fidcDiamond, 0, "fidc");
        } else {
            _emitFunding(fidcId, address(0), totalNeededNative - fidcBal, "insufficient");
        }
    }

    function _emitFunding(uint256 fidcId, address source, uint256 amount, string memory sourceType) private {
        // Emit via assembly to avoid importing the full interface event
        // Event: DistributionFundingSource(uint256 indexed fidcId, address indexed fundingSource, uint256 amount, string sourceType)
        bytes32 eventSig = IUnifiedFactory.DistributionFundingSource.selector;
        bytes memory data = abi.encode(amount, sourceType);
        assembly {
            log3(add(data, 0x20), mload(data), eventSig, fidcId, source)
        }
    }

    function _getTotalNeededNative(
        address fidcDiamond,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS
    ) private view returns (address stableToken, uint256 totalNeededNative) {
        (bool ok, bytes memory ret) = fidcDiamond.staticcall(
            abi.encodeWithSelector(
                IFIDC_Optimized.calculateDistributionWithYieldsBatch.selector,
                serieId,
                seniorYieldBPS,
                mezzYieldBPS,
                juniorYieldBPS,
                batchPercentBPS,
                uint256(0)
            )
        );
        if (!ok || ret.length < 192) return (address(0), 0);

        uint256 sVNA;
        uint256 mVNA;
        uint256 jVNA;
        uint256 sDist;
        uint256 mDist;
        uint256 jDist;
        assembly {
            let p := add(ret, 0x20)
            sVNA := mload(p)
            mVNA := mload(add(p, 0x20))
            jVNA := mload(add(p, 0x40))
            sDist := mload(add(p, 0x60))
            mDist := mload(add(p, 0x80))
            jDist := mload(add(p, 0xa0))
        }

        stableToken = IFIDC_Optimized(fidcDiamond).getStableToken();
        uint8 dec = IERC20Metadata(stableToken).decimals();
        uint256 totalWad = sDist + mDist + jDist;
        if (totalWad == 0) {
            totalWad = (sVNA * seniorYieldBPS + mVNA * mezzYieldBPS + jVNA * juniorYieldBPS) / YieldCalculator.PRECISION;
        }
        totalNeededNative = YieldCalculator.scaleFromWad(totalWad, dec);
    }

    function _tryTransferFromCaptation(
        uint256 fidcId,
        address fidcDiamond,
        address cap,
        address stableToken,
        uint256 needed
    ) private returns (bool) {
        if (_isVaultAuthorized(cap)) {
            try IUnifiedEscrow(cap).getAvailableBalance(stableToken) returns (uint256 bal) {
                if (bal >= needed) {
                    if (IUnifiedEscrow(cap).authorizedTransfer(stableToken, fidcDiamond, needed)) {
                        _emitFunding(fidcId, cap, needed, "vault");
                        return true;
                    }
                }
            } catch {}
        }
        uint256 walletBal = IERC20(stableToken).balanceOf(cap);
        uint256 allow = IERC20(stableToken).allowance(cap, address(this));
        if (walletBal >= needed && allow >= needed) {
            (bool ok, bytes memory rd) =
                stableToken.call(abi.encodeWithSelector(IERC20.transferFrom.selector, cap, fidcDiamond, needed));
            if (ok && (rd.length == 0 || abi.decode(rd, (bool)))) {
                _emitFunding(fidcId, cap, needed, "wallet");
                return true;
            }
        }
        return false;
    }

    function _isVaultAuthorized(address cap) private view returns (bool) {
        uint256 cs;
        assembly { cs := extcodesize(cap) }
        if (cs == 0) return false;
        try IUnifiedEscrow(cap).isAuthorized(address(this)) returns (bool auth) {
            return auth;
        } catch {
            return false;
        }
    }

    /* ─────────────── BATCH COMPENSATION ─────────────── */

    /// @dev Storage slot for blacklist mapping - must match V2's storage layout
    /// V2 layout: companyAdmin(0), fidcFactoryManager(1), defaultProjectManager(2),
    ///            accountRegistry(3), blacklist(4), tenantToProjectManager(5), fidcOperators(6)
    /// With OZ upgradeable namespaced storage, actual slots depend on inheritance.
    /// We pass blacklist check results from the caller instead.

    function executeBatchCompensation(
        uint256 fidcId,
        uint256[] calldata operationIds,
        uint256[] calldata payAmounts,
        uint256[] calldata collateralAmounts,
        address payer,
        bool isLate,
        uint256 penaltyBPS
    ) external returns (uint256 totalPaid, uint256 totalPenalty) {
        uint256 len = operationIds.length;
        if (len == 0) revert IUnifiedFactory.EmptyBatch();
        if (len != payAmounts.length || len != collateralAmounts.length) {
            revert IUnifiedFactory.ArrayLengthMismatch();
        }
        // AUDIT-FIX R2-C-02: bound penaltyBPS by the FIDC tenant OWNER's effective cap (never msg.sender),
        // so a delegated/compromised operator key cannot exceed the cap the tenant chose. Runs in the
        // gateway storage context (delegatecall). V2 (no per-tenant cap) falls back to the global MAX.
        address tOwner = FIDCModuleLib.getTenantOwner(fidcId);
        try IPenaltyCapView(address(this)).getEffectivePenaltyCap(tOwner) returns (uint256 cap) {
            if (penaltyBPS > cap) revert PenaltyCapExceeded();
        } catch {
            if (penaltyBPS > 5000) revert PenaltyCapExceeded();
        }
        address fidcAddress = FIDCModuleLib.getFIDC(fidcId);
        for (uint256 i; i < len;) {
            (uint256 paid, uint256 penalty) = _compensateOne(
                fidcAddress, operationIds[i], payAmounts[i], collateralAmounts[i], payer, isLate, penaltyBPS
            );
            totalPaid += paid;
            totalPenalty += penalty;
            unchecked {
                ++i;
            }
        }
    }

    function _compensateOne(
        address fidcAddress,
        uint256 operationId,
        uint256 payAmount,
        uint256 collateralAmount,
        address payer,
        bool isLate,
        uint256 penaltyBPS
    ) private returns (uint256 actualPay, uint256 penalty) {
        FIDCModuleLib.AnticipationRecord memory ant = FIDCModuleLib.getAnticipation(operationId);
        if (fidcAddress != ant.fidcAddress) revert InvalidInput();
        penalty = isLate ? (payAmount * penaltyBPS) / 10000 : 0;
        actualPay = payAmount + penalty;
        // Pass only base amount to compensateFor (FIDC caps at outstanding debt)
        FIDCModuleLib.compensateFor(operationId, payAmount, collateralAmount, payer);
        // Transfer penalty separately (payer must approve factory for penalty)
        if (penalty > 0) {
            address st = IFIDC_Optimized(fidcAddress).getStableToken();
            (bool ok, bytes memory rd) =
                st.call(abi.encodeWithSelector(IERC20.transferFrom.selector, payer, fidcAddress, penalty));
            if (!ok || (rd.length > 0 && !abi.decode(rd, (bool)))) revert InvalidInput();
        }
        // Emit per-item event via assembly (library can't reference contract events directly)
        bytes32 sig = IUnifiedFactory.AnticipationCompensated.selector;
        address fa = ant.fidcAddress;
        address ced = ant.cedente;
        bytes memory evData = abi.encode(actualPay, ant.captationAddress);
        assembly { log4(add(evData, 0x20), mload(evData), sig, operationId, fa, ced) }
    }

    /* ─────────────── BATCH RECEIVABLE REGISTRATION ─────────────── */

    function registerReceivableBatch(
        address[] calldata debtorWallets,
        address[] calldata creditorAddrs,
        string[] calldata identifiers,
        uint256[] calldata nominalValues,
        uint256[] calldata dueDates
    ) external returns (bytes32[] memory receivableIds) {
        uint256 len = debtorWallets.length;
        if (len == 0) revert IUnifiedFactory.EmptyBatch();
        if (
            len != creditorAddrs.length || len != identifiers.length || len != nominalValues.length
                || len != dueDates.length
        ) revert IUnifiedFactory.ArrayLengthMismatch();
        receivableIds = new bytes32[](len);
        for (uint256 i; i < len;) {
            receivableIds[i] = FIDCModuleLib.adminRegisterReceivable(
                debtorWallets[i], creditorAddrs[i], identifiers[i], nominalValues[i], dueDates[i]
            );
            unchecked {
                ++i;
            }
        }
    }

    /* ─────────────── COLLATERAL RELEASE ─────────────── */

    /// @notice Releases NFT/ERC1155 collateral held by the FIDC Diamond back to a destination.
    /// @dev    Body offloaded from UnifiedFactoryManagerV3.executeReleaseCollateralByFactoryManager
    ///         to free EIP-170 bytecode budget for V3 setters. Behavior is byte-equivalent to V2.
    ///         Callable only from a context where `msg.sender == fidcFactoryManager` (gateway invariant).
    function executeReleaseCollateral(uint256 fidcId, uint256 operationId, address destination) external {
        if (msg.sender != FIDCModuleLib.getFIDCFactoryManager()) revert InvalidInput();
        FIDCModuleLib.AnticipationRecord memory ant = FIDCModuleLib.getAnticipation(operationId);
        if (FIDCModuleLib.getFIDC(fidcId) != ant.fidcAddress) revert InvalidInput();
        if (destination == address(0)) revert InvalidInput();
        if (ant.active) revert InvalidInput();
        if (ant.collateralReleased) revert InvalidInput();
        if (ant.collateralCustody != FIDCModuleLib.CollateralCustodyType.CONTRACT_LOCK) revert InvalidInput();
        if (
            ant.collateralType != FIDCModuleLib.CollateralTokenType.ERC721
                && ant.collateralType != FIDCModuleLib.CollateralTokenType.ERC1155
        ) revert InvalidInput();
        IFIDC_Optimized(ant.fidcAddress)
            .releaseCollateralTo(ant.colToken, ant.collateralTokenId, ant.collateralTokenAmount, destination);
        FIDCModuleLib.setCollateralReleased(operationId);

        // Emit CollateralReleased(uint256 indexed operationId, address indexed fidcAddress,
        //                         address indexed destination, address colToken, uint256 tokenId, uint256 tokenAmount)
        bytes32 sig = IUnifiedFactory.CollateralReleased.selector;
        address fa = ant.fidcAddress;
        address colToken = ant.colToken;
        uint256 tokenId = ant.collateralTokenId;
        uint256 tokenAmount = ant.collateralTokenAmount;
        bytes memory data = abi.encode(colToken, tokenId, tokenAmount);
        assembly {
            log4(add(data, 0x20), mload(data), sig, operationId, fa, destination)
        }
    }

    /* ─────────────── ENCODED ANTICIPATION ─────────────── */

    function anticipateFromEncoded(uint256 fidcId, FIDCModuleLib.AnticipationRequest memory req)
        external
        returns (uint256 operationId)
    {
        return _anticipateFromEncoded(fidcId, req);
    }

    function _anticipateFromEncoded(uint256 fidcId, FIDCModuleLib.AnticipationRequest memory req)
        private
        returns (uint256 operationId)
    {
        if (req.anticipationAmount == 0 || req.collateralAmount == 0) revert InvalidInput();
        address fa = FIDCModuleLib.getFIDC(fidcId);
        if (fa == address(0)) revert InvalidInput();
        FIDCModuleLib.RecebivelInfo memory rec = FIDCModuleLib.getReceivable(req.receivableId);
        if (!rec.ativo) revert InvalidInput();
        if (
            req.anticipationAmount > rec.valorRestante
                || (req.collateralAmount * 10000) / req.anticipationAmount < 10000
        ) revert InvalidInput();

        FIDCModuleLib.CollateralConfig memory col = req.collateral;
        operationId = FIDCModuleLib.anticipateWithReceivable(
            FIDCModuleLib.AnticipationCallParams({
                fidcId: fidcId,
                fidcAddress: fa,
                recebivelId: req.receivableId,
                valorAntecipacao: req.anticipationAmount,
                colToken: req.colToken,
                collateralAmount: req.collateralAmount,
                captationAddress: req.captationAddress,
                collateralType: col.collateralType,
                collateralTokenId: col.collateralTokenId,
                collateralTokenAmount: col.collateralTokenAmount,
                collateralCustody: col.collateralCustody,
                collateralDestination: col.collateralDestination
            })
        );
    }
}
