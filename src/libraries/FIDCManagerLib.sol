// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFIDC_Optimized} from "../interface/IFIDC_Optimized.sol";
import {FIDCDistributionLib} from "./FIDCDistributionLib.sol";
import {YieldCalculator} from "./YieldCalculator.sol";
import {FIDCErrors} from "./FIDCErrors.sol";
import {IReceivable} from "../interface/IReceivable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @notice Minimal interface for tokens that support burn
 * @dev Used to attempt real burn before fallback to transfer
 * @dev ✅ FIX: Supports both burn() and burnFrom() for maximum compatibility
 */
interface IERC20BurnableLike {
    function burn(uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

library FIDCManagerLib {
    using SafeERC20 for IERC20;

    // keccak256("capitare.fidc.manager.state.v1")
    bytes32 private constant STORAGE_SLOT = 0xfb9d3f1c397cf4b61ad4966d6f4fb40b8dff7a9c2abb53c4d8906176493f5136;

    // ✅ FIX: Limit of collateral tokens per debtor (prevent DoS)
    uint256 private constant MAX_COLLATERAL_TOKENS_PER_DEBTOR = 10;

    // Role bits
    uint256 internal constant ROLE_ADMIN = 1 << 0;
    uint256 internal constant ROLE_SENIOR = 1 << 1; // S
    uint256 internal constant ROLE_MEZZ = 1 << 2; // M
    uint256 internal constant ROLE_JUNIOR = 1 << 3; // J
    uint256 internal constant ROLE_COLL = 1 << 4; // C (collateral operator)
    uint256 internal constant ROLE_PAY = 1 << 5; // P (payable, compensate)

    // Series management structs
    struct SeriesInfo {
        string serieId;
        uint256 totalCaptated; // Total captured in this series (WAD)
        uint256 totalQuotas; // Total quotas issued in this series
        uint256 maxQuotas; // Maximum quota limit (0 = unlimited)
        uint256 totalInvestments; // Number of investments in this series
        bool active; // If series is active
        uint256 createdAt; // Creation timestamp
        uint256 lastInvestmentAt; // Last investment timestamp
        // ✅ PHASE 1: Class restriction per series
        bool allowSenior; // If Senior class can invest in this series
        bool allowMezz; // If Mezzanine class can invest in this series
        bool allowJunior; // If Junior class can invest in this series
    }

    // NOTE (coverage hardening):
    // Group batch accumulators to reduce stack pressure when compiling without optimizer/viaIR.
    struct BatchSums {
        uint256 totalValue;
        uint256 totalTokens;
        uint256 addSTok;
        uint256 addMTok;
        uint256 addJTok;
    }

    // (reserved)

    // ✅ PHASE 2: Detailed statistics per class per series
    struct SeriesClassStats {
        uint256 seniorCaptated; // Total captured by Senior in this series (WAD)
        uint256 mezzCaptated; // Total captured by Mezzanine in this series (WAD)
        uint256 juniorCaptated; // Total captured by Junior in this series (WAD)
        uint256 seniorQuotas; // Total quotas issued to Senior in this series
        uint256 mezzQuotas; // Total quotas issued to Mezzanine in this series
        uint256 juniorQuotas; // Total quotas issued to Junior in this series
        uint256 seniorInvestors; // Number of unique Senior investors in this series
        uint256 mezzInvestors; // Number of unique Mezzanine investors in this series
        uint256 juniorInvestors; // Number of unique Junior investors in this series
        address[] seniorInvestorList; // List of Senior investors in this series
        address[] mezzInvestorList; // List of Mezzanine investors in this series
        address[] juniorInvestorList; // List of Junior investors in this series
    }

    struct VaultTransferConfig {
        address targetAddress; // Vault or destination wallet
        uint16 transferPercentBPS; // Percentage in basis points (2000 = 20%)
        bool enabled; // If transfer is enabled
    }

    struct CompCtx {
        uint256 payWad;
        uint256 principalPaidWad;
        uint256 burnedSumWad;
        uint256 totalLockedWad;
        uint256 colToBurnWad;
        uint8 stableDec;
    }

    /**
     * @notice Return structure for compensation with debt and interest breakdown
     */
    struct CompensationResult {
        uint256 debtPaidWad; // Amount paid as debt (related to collateral)
        uint256 interestPaidWad; // Amount paid as interest (excess over debt)
        uint256 collateralBurnedWad; // Collateral burned (proportional only to debt)
        bool debtFullyPaid; // If debt was fully paid
    }

    /**
     * @notice Amortization cycle plan (principal return) for batch processing
     * @dev Stored in FIDCManagerLib.State (diamond storage slot).
     *      - `periodEnd == 0` means no active amortization cycle.
     *      - `base*VNAWad` are denominators snapshot at cycle start (do not change during the cycle).
     *      - `plan*Wad` are total amounts to amortize per class for the cycle.
     *      - `dist*Wad` track how much was already executed (for last-batch dust = plan - dist).
     */
    struct AmortizationPlan {
        uint64 periodEnd;
        uint256 baseSeniorVNAWad;
        uint256 baseMezzVNAWad;
        uint256 baseJuniorVNAWad;
        uint256 planSeniorWad;
        uint256 planMezzWad;
        uint256 planJuniorWad;
        uint256 distSeniorWad;
        uint256 distMezzWad;
        uint256 distJuniorWad;
    }

    struct State {
        IERC20 stable;
        uint256 id;
        uint256 cnt;
        IFIDC_Optimized.CompactFIDC fidc;
        address token; // receivable

        // Investors and positions
        mapping(address => IFIDC_Optimized.Investment[]) pos;
        address[] invs;
        mapping(address => bool) isI;
        uint256 sInv; // senior VNA
        uint256 mInv; // mezz VNA

        // Caps
        uint256 maxQ; // max quotas
        uint256 maxSeniorBps;
        uint256 maxMezzBps;
        uint256 maxJuniorBps;
        uint256 sTok; // allocated quotas per class
        uint256 mTok;
        uint256 jTok;

        // Asset pricing system
        uint256 currentAssetPrice; // Current price per quota in WAD (18 decimals)
        uint256 totalQuotasIssued; // Total quotas issued so far

        // Aux
        uint256 lastF;
        mapping(string => address) purs; // purchase id processed
        mapping(address => FIDCDistributionLib.DebtorInfo) debs;
        mapping(address => bool) whites;

        // Bitmask roles
        mapping(address => uint256) roles;

        // Per-token collateral ratio overrides (percent, e.g., 120 = 120%)
        mapping(address => uint16) colRatioByToken;

        // Series management
        mapping(string => SeriesInfo) series;
        string[] seriesIds;
        mapping(string => bool) seriesExists;
        mapping(string => address[]) seriesInvestors;
        mapping(address => mapping(string => bool)) investorInSeries;

        // ✅ FASE 2: Tracking por classe por série
        mapping(string => SeriesClassStats) seriesClassStats;

        // ✅ CRITICAL FIX: O(1) mappings to check if investor is already in list
        // Prevents gas DoS in _isInList() when series grows
        mapping(string => mapping(address => bool)) seniorInSeriesList;
        mapping(string => mapping(address => bool)) mezzInSeriesList;
        mapping(string => mapping(address => bool)) juniorInSeriesList;

        // Totais públicos
        uint256 totalCaptated; // Total captado sem série (variável pública)
        uint256 totalCaptatedSeries; // Total captado em todas as séries (variável pública)
        uint256 totalSeriesQuotas; // Total de quotas de todas as séries (O(1) lookup)

        // Inicialização versionada (para upgrades futuros)
        uint32 initVersion; // Versão da inicialização (0 = não inicializado)

        // Vault transfer configuration
        VaultTransferConfig vaultConfig;

        // Whitelisted wallet for withdrawals (alternative to vault)
        address whitelistedWallet;

        // ✅ FIX: Batch distribution cursors (moved from FactoryManagerDiamond)
        // Cursor global (sem série)
        uint256 batchCursor;
        // Cursor por série (serieKey => cursor)
        mapping(bytes32 => uint256) batchCursorBySeries;

        // ✅ PR3: Batch amortization cursors (separate from yield distribution cursor)
        uint256 amortCursor;
        mapping(bytes32 => uint256) amortCursorBySeries;

        // ✅ PR3: Amortization cycle plan (global and per-series)
        AmortizationPlan amortPlan;
        mapping(bytes32 => AmortizationPlan) amortPlanBySeries;

        // ✅ G1: dedup de distribuição explícita (payoutId => executado). Append
        // no FIM da State — storage do Diamond é seguro para acréscimo.
        mapping(bytes32 => bool) executedExplicitPayouts;
    }

    function state() internal pure returns (State storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /**
     * @notice ✅ FIX CRÍTICO: Função removida - substituída por mappings O(1)
     * @dev O(n) loop causava DoS por gás conforme série cresce
     * @dev Agora usamos seniorInSeriesList/mezzInSeriesList/juniorInSeriesList
     */

    /* ====================== ROLE HELPERS ====================== */
    function _has(State storage s, address a, uint256 bit) internal view returns (bool) {
        return (s.roles[a] & bit) != 0;
    }

    function _require(State storage s, address a, uint256 bit) internal view {
        // Admin can perform any action
        if (((s.roles[a] & bit) == 0) && ((s.roles[a] & ROLE_ADMIN) == 0)) {
            revert FIDCErrors.UnauthorizedInvestor();
        }
    }

    function grantRole(State storage s, uint256 bit, address who) internal {
        s.roles[who] |= bit;
    }

    function revokeRole(State storage s, uint256 bit, address who) internal {
        s.roles[who] &= ~bit;
    }

    /* ====================== ADMIN API (via Factory) ====================== */
    function approveInvestor(address[] calldata a, uint8 c) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (c > 2) revert FIDCErrors.InvalidClass();
        uint256 bit = c == 0 ? ROLE_SENIOR : c == 1 ? ROLE_MEZZ : ROLE_JUNIOR;
        for (uint256 i; i < a.length; ++i) {
            grantRole(s, bit, a[i]);
        }
    }

    function approveInvestorForMultipleClasses(address investor, uint8[] calldata classIds) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);

        for (uint256 i; i < classIds.length; ++i) {
            if (classIds[i] > 2) revert FIDCErrors.InvalidClass();
            uint256 bit = classIds[i] == 0 ? ROLE_SENIOR : classIds[i] == 1 ? ROLE_MEZZ : ROLE_JUNIOR;
            grantRole(s, bit, investor);
        }
    }

    function revokeInvestor(address[] calldata a, uint8 c) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (c > 2) revert FIDCErrors.InvalidClass();
        uint256 bit = c == 0 ? ROLE_SENIOR : c == 1 ? ROLE_MEZZ : ROLE_JUNIOR;
        for (uint256 i; i < a.length; ++i) {
            revokeRole(s, bit, a[i]);
        }
    }

    function approveCollateral(address[] calldata a, bool b) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        for (uint256 i; i < a.length; ++i) {
            b ? grantRole(s, ROLE_COLL, a[i]) : revokeRole(s, ROLE_COLL, a[i]);
        }
    }

    function approvePayable(address[] calldata a, bool b) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        for (uint256 i; i < a.length; ++i) {
            b ? grantRole(s, ROLE_PAY, a[i]) : revokeRole(s, ROLE_PAY, a[i]);
        }
    }

    function whitelist(address[] calldata a, bool w) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        for (uint256 i; i < a.length; ++i) {
            s.whites[a[i]] = w;
        }
    }

    /**
     * @notice Sets whitelisted wallet for withdrawals
     * @param walletAddress Whitelisted wallet address (address(0) to clear)
     */
    function setWhitelistedWallet(address walletAddress) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        s.whitelistedWallet = walletAddress;
    }

    /**
     * @notice Gets whitelisted wallet for withdrawals
     * @return walletAddress Whitelisted wallet address (address(0) if not configured)
     */
    function getWhitelistedWallet() external view returns (address) {
        State storage s = state();
        return s.whitelistedWallet;
    }

    /**
     * @notice Set collateral ratio overrides per token. Ratios are in percent (e.g., 120 = 120%).
     *         Passing 0 clears the override and falls back to default ratio.
     */
    function setCollateralRatios(address[] calldata tokens, uint16[] calldata ratios) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (tokens.length == 0 || tokens.length != ratios.length) revert FIDCErrors.ValidationFailed();
        for (uint256 i; i < tokens.length; ++i) {
            s.colRatioByToken[tokens[i]] = ratios[i];
        }
    }

    function getCollateralRatio(address token) external view returns (uint16) {
        State storage s = state();
        uint16 r = s.colRatioByToken[token];
        return r;
    }

    function permitFunding(address o, address spender, uint256 v, uint256 d, uint8 _v, bytes32 r, bytes32 _s) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        // Try/catch para reverter com erro customizado se stable não implementar EIP-2612
        try IERC20Permit(address(s.stable)).permit(o, spender, v, d, _v, r, _s) {
        // Sucesso
        }
        catch {
            revert FIDCErrors.IncompatibleToken();
        }
    }

    function withdraw(address to, uint256 amount) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (to == address(0)) revert FIDCErrors.ZeroAddress();
        if (!s.whites[to]) revert FIDCErrors.NotWhitelisted();
        s.stable.safeTransfer(to, amount);
    }

    /* ====================== CORE ====================== */
    function investPre(
        string calldata purchaseId,
        address owner,
        uint8 classId,
        uint256 value,
        uint256 tokens,
        uint256 totalQuotas,
        string calldata serieId
    ) internal returns (uint256) {
        State storage s = state();
        if (s.fidc.paused) revert FIDCErrors.ContractPaused();
        _require(s, msg.sender, ROLE_ADMIN);
        // Validar assetPrice != 0
        if (s.currentAssetPrice == 0) revert FIDCErrors.ValidationFailed();

        // ✅ FIX MÉDIO: Limitar tamanho de strings para prevenir DoS/gas
        if (bytes(purchaseId).length == 0 || bytes(purchaseId).length > 64) {
            revert FIDCErrors.ValidationFailed(); // purchaseId vazio ou muito grande
        }
        if (bytes(serieId).length > 32) {
            revert FIDCErrors.ValidationFailed(); // serieId muito grande
        }
        if (s.purs[purchaseId] != address(0)) {
            revert FIDCErrors.PurchaseAlreadyProcessed(purchaseId);
        }
        if (classId > 2) revert FIDCErrors.InvalidClass();

        // role per class for investor
        uint256 bit = classId == 0 ? ROLE_SENIOR : classId == 1 ? ROLE_MEZZ : ROLE_JUNIOR;
        if (!_has(s, owner, bit)) revert FIDCErrors.UnauthorizedInvestor();

        // ✅ FIX: Try/catch para decimals (proteção contra tokens mal implementados)
        uint8 dec = 0;
        try IERC20Metadata(address(s.stable)).decimals() returns (uint8 d) {
            dec = d;
            if (dec == 0 || dec > 18) revert FIDCErrors.ValidationFailed(); // Decimais inválidos
        } catch {
            revert FIDCErrors.ValidationFailed(); // Token sem suporte a decimals()
        }
        uint256 valueNative = FIDCDistributionLib.scaleFromWad(value, dec);
        if (s.stable.allowance(owner, address(this)) < valueNative) revert FIDCErrors.InsufficientAllowance();
        // NOTE: operator-driven flow; production must use UnifiedFactoryManager *Authorized variants.
        // slither-disable-next-line arbitrary-send-erc20
        s.stable.safeTransferFrom(owner, address(this), valueNative);

        // ✅ FIX CRÍTICO: Validar tokens calculado on-chain (prevenir inflação de quotas)
        uint256 expectedTokens = (value * 1e18) / s.currentAssetPrice;
        if (tokens != expectedTokens) revert FIDCErrors.ValidationFailed();
        if (tokens == 0) revert FIDCErrors.ZeroAmount();
        if (classId == 0 && s.maxSeniorBps > 0) {
            uint256 cap = (totalQuotas * s.maxSeniorBps) / YieldCalculator.PRECISION;
            if (s.sTok + tokens > cap) revert FIDCErrors.ValidationFailed();
        } else if (classId == 1 && s.maxMezzBps > 0) {
            uint256 cap = (totalQuotas * s.maxMezzBps) / YieldCalculator.PRECISION;
            if (s.mTok + tokens > cap) revert FIDCErrors.ValidationFailed();
        } else if (classId == 2 && s.maxJuniorBps > 0) {
            uint256 cap = (totalQuotas * s.maxJuniorBps) / YieldCalculator.PRECISION;
            if (s.jTok + tokens > cap) revert FIDCErrors.ValidationFailed();
        }

        // ✅ GESTÃO DE SÉRIE
        if (bytes(serieId).length > 0) {
            // Série DEVE existir (criada explicitamente)
            require(s.seriesExists[serieId], "Series does not exist");
            SeriesInfo storage series = s.series[serieId];
            require(series.active, "Series is not active");

            // ✅ FASE 1: Validar restrição de classe por série
            if (classId == 0 && !series.allowSenior) {
                revert FIDCErrors.ClassNotAllowedInSeries();
            }
            if (classId == 1 && !series.allowMezz) {
                revert FIDCErrors.ClassNotAllowedInSeries();
            }
            if (classId == 2 && !series.allowJunior) {
                revert FIDCErrors.ClassNotAllowedInSeries();
            }

            // Validar limite da série (se maxQuotas > 0)
            if (series.maxQuotas > 0) {
                require(series.totalQuotas + tokens <= series.maxQuotas, "Series max quotas exceeded");
            }

            // Validar limite total do FIDC (se maxQ > 0) - usar O(1) lookup
            if (s.maxQ > 0) {
                require(s.totalSeriesQuotas + tokens <= s.maxQ, "Total FIDC quotas exceeded");
            }

            // Atualizar série existente
            series.totalCaptated += value;
            series.totalQuotas += tokens;
            series.totalInvestments += 1;
            series.lastInvestmentAt = block.timestamp;

            // Atualizar total de todas as séries (O(1))
            s.totalCaptatedSeries += value;
            s.totalSeriesQuotas += tokens;

            // Adicionar investidor à série (se ainda não estiver)
            if (!s.investorInSeries[owner][serieId]) {
                s.seriesInvestors[serieId].push(owner);
                s.investorInSeries[owner][serieId] = true;
            }

            // ✅ FASE 2: Atualizar estatísticas por classe
            SeriesClassStats storage stats = s.seriesClassStats[serieId];

            if (classId == 0) {
                stats.seniorCaptated += value;
                stats.seniorQuotas += tokens;
                // ✅ FIX CRÍTICO: Usar mapping O(1) ao invés de loop O(n)
                if (!s.seniorInSeriesList[serieId][owner]) {
                    stats.seniorInvestorList.push(owner);
                    stats.seniorInvestors++;
                    s.seniorInSeriesList[serieId][owner] = true;
                }
            } else if (classId == 1) {
                stats.mezzCaptated += value;
                stats.mezzQuotas += tokens;
                // ✅ FIX CRÍTICO: Usar mapping O(1) ao invés de loop O(n)
                if (!s.mezzInSeriesList[serieId][owner]) {
                    stats.mezzInvestorList.push(owner);
                    stats.mezzInvestors++;
                    s.mezzInSeriesList[serieId][owner] = true;
                }
            } else {
                stats.juniorCaptated += value;
                stats.juniorQuotas += tokens;
                // ✅ FIX CRÍTICO: Usar mapping O(1) ao invés de loop O(n)
                if (!s.juniorInSeriesList[serieId][owner]) {
                    stats.juniorInvestorList.push(owner);
                    stats.juniorInvestors++;
                    s.juniorInSeriesList[serieId][owner] = true;
                }
            }

            // ✅ FASE 4: Verificar e emitir eventos de milestones
            // Note: series.totalQuotas was already updated above, so we calculate oldTotalQuotas by subtracting tokens
            if (series.maxQuotas > 0) {
                uint256 oldTotalQuotas = series.totalQuotas - tokens; // Total antes do investimento
                uint256 oldPercentageBPS = (oldTotalQuotas * 10_000) / series.maxQuotas;
                uint256 newPercentageBPS = (series.totalQuotas * 10_000) / series.maxQuotas;

                // Emitir evento se cruzou milestone (25%, 50%, 75%)
                if (oldPercentageBPS < 2_500 && newPercentageBPS >= 2_500) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 2_500);
                }
                if (oldPercentageBPS < 5_000 && newPercentageBPS >= 5_000) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 5_000);
                }
                if (oldPercentageBPS < 7_500 && newPercentageBPS >= 7_500) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 7_500);
                }
                // Emit event when series reaches 100%
                if (oldPercentageBPS < 10_000 && newPercentageBPS >= 10_000) {
                    emit IFIDC_Optimized.SeriesComplete(serieId);
                }
            }
        } else {
            // Sem série: atualizar variável pública totalCaptated
            s.totalCaptated += value;
        }

        if (classId == 0) s.sInv += value;
        else if (classId == 1) s.mInv += value;

        if (classId == 0) s.sTok += tokens;
        else if (classId == 1) s.mTok += tokens;
        else s.jTok += tokens;

        // ✅ FIX: Proteção contra overflow no cast para uint128
        require(value <= type(uint128).max, "Investment value exceeds uint128 max");
        s.fidc.invested += uint128(value);
        s.pos[owner].push(
            IFIDC_Optimized.Investment({
                amount: uint128(value),
                date: uint64(block.timestamp),
                yieldStart: uint64(block.timestamp),
                class: classId,
                serieId: serieId
            })
        );
        if (!s.isI[owner]) s.invs.push(owner);
        s.isI[owner] = true;
        s.purs[purchaseId] = owner;

        // ✅ AUTOMATIC TRANSFER TO VAULT/WALLET (if configured)
        if (s.vaultConfig.enabled && s.vaultConfig.transferPercentBPS > 0) {
            uint256 transferAmount = (value * s.vaultConfig.transferPercentBPS) / 10_000;
            uint256 transferAmountNative = FIDCDistributionLib.scaleFromWad(transferAmount, dec);
            s.stable.safeTransfer(s.vaultConfig.targetAddress, transferAmountNative);
        }

        emit IFIDC_Optimized.Invested(owner, purchaseId, value, tokens, s.id);
        return ++s.cnt;
    }

    // -----------------------------------------------------------------------
    // Coverage hardening helpers (avoid "stack too deep" when optimizer/viaIR is off)
    // -----------------------------------------------------------------------

    function _sumBatchNoSeries(State storage s, address owner, uint8[] calldata classIds, uint256[] calldata values)
        internal
        view
        returns (BatchSums memory sums)
    {
        for (uint256 i = 0; i < classIds.length; i++) {
            uint8 classId = classIds[i];
            uint256 value = values[i];

            if (classId > 2) revert FIDCErrors.InvalidClass();
            if (value == 0) revert FIDCErrors.ZeroAmount();

            uint256 bit = classId == 0 ? ROLE_SENIOR : classId == 1 ? ROLE_MEZZ : ROLE_JUNIOR;
            if (!_has(s, owner, bit)) revert FIDCErrors.UnauthorizedInvestor();

            uint256 calculatedTokens = (value * 1e18) / s.currentAssetPrice;
            if (calculatedTokens == 0) revert FIDCErrors.ZeroAmount();

            if (classId == 0) sums.addSTok += calculatedTokens;
            else if (classId == 1) sums.addMTok += calculatedTokens;
            else sums.addJTok += calculatedTokens;

            sums.totalValue += value;
            sums.totalTokens += calculatedTokens;
        }
    }

    function _sumBatchWithSeries(
        State storage s,
        address owner,
        uint8[] calldata classIds,
        uint256[] calldata values,
        string calldata serieId
    ) internal view returns (BatchSums memory sums) {
        require(s.seriesExists[serieId], "Series does not exist");
        SeriesInfo storage series = s.series[serieId];
        require(series.active, "Series is not active");

        for (uint256 i = 0; i < classIds.length; i++) {
            uint8 classId = classIds[i];
            uint256 value = values[i];

            if (classId > 2) revert FIDCErrors.InvalidClass();
            if (value == 0) revert FIDCErrors.ZeroAmount();

            if (classId == 0 && !series.allowSenior) revert FIDCErrors.ClassNotAllowedInSeries();
            if (classId == 1 && !series.allowMezz) revert FIDCErrors.ClassNotAllowedInSeries();
            if (classId == 2 && !series.allowJunior) revert FIDCErrors.ClassNotAllowedInSeries();

            uint256 bit = classId == 0 ? ROLE_SENIOR : classId == 1 ? ROLE_MEZZ : ROLE_JUNIOR;
            if (!_has(s, owner, bit)) revert FIDCErrors.UnauthorizedInvestor();

            uint256 calculatedTokens = (value * 1e18) / s.currentAssetPrice;
            if (calculatedTokens == 0) revert FIDCErrors.ZeroAmount();

            if (classId == 0) sums.addSTok += calculatedTokens;
            else if (classId == 1) sums.addMTok += calculatedTokens;
            else sums.addJTok += calculatedTokens;

            sums.totalValue += value;
            sums.totalTokens += calculatedTokens;
        }
    }

    function _collectInvestmentFunds(State storage s, address owner, uint256 totalValueWad) internal {
        uint8 dec = IERC20Metadata(address(s.stable)).decimals();
        uint256 totalNativeValue = FIDCDistributionLib.scaleFromWad(totalValueWad, dec);
        if (s.stable.allowance(owner, address(this)) < totalNativeValue) revert FIDCErrors.InsufficientAllowance();
        // NOTE: operator-driven flow; production must use UnifiedFactoryManager *Authorized variants.
        // slither-disable-next-line arbitrary-send-erc20
        s.stable.safeTransferFrom(owner, address(this), totalNativeValue);

        // ✅ AUTOMATIC TRANSFER TO VAULT/WALLET (if configured)
        if (s.vaultConfig.enabled && s.vaultConfig.transferPercentBPS > 0) {
            uint256 transferAmountWad = (totalValueWad * s.vaultConfig.transferPercentBPS) / 10_000;
            uint256 transferAmountNative = FIDCDistributionLib.scaleFromWad(transferAmountWad, dec);
            s.stable.safeTransfer(s.vaultConfig.targetAddress, transferAmountNative);
        }
    }

    function _recordInvestmentPosition(
        State storage s,
        address owner,
        uint256 valueWad,
        uint8 classId,
        string calldata serieId
    ) internal {
        // ✅ FIX: Proteção contra overflow no cast para uint128
        require(valueWad <= type(uint128).max, "Investment value exceeds uint128 max");
        s.fidc.invested += uint128(valueWad);
        s.pos[owner].push(
            IFIDC_Optimized.Investment({
                amount: uint128(valueWad),
                date: uint64(block.timestamp),
                yieldStart: uint64(block.timestamp),
                class: classId,
                serieId: serieId
            })
        );
    }

    function _finalizeInvestBatchPre(
        State storage s,
        string calldata purchaseId,
        address owner,
        uint8[] calldata classIds,
        uint256[] calldata values,
        string calldata serieId,
        uint256 totalValueWad,
        uint256 totalTokens
    ) internal returns (uint256[] memory invIds) {
        invIds = new uint256[](classIds.length);

        // Processar cada investimento
        for (uint256 i = 0; i < classIds.length; i++) {
            // Calcular tokens para este investimento
            uint256 calculatedTokens = (values[i] * 1e18) / s.currentAssetPrice;

            // Atualizar contadores de classe
            if (classIds[i] == 0) {
                s.sInv += values[i];
                s.sTok += calculatedTokens;
            } else if (classIds[i] == 1) {
                s.mInv += values[i];
                s.mTok += calculatedTokens;
            } else {
                s.jTok += calculatedTokens;
            }

            // ✅ FIX: Proteção contra overflow no cast para uint128
            require(values[i] <= type(uint128).max, "Investment value exceeds uint128 max");
            s.fidc.invested += uint128(values[i]);
            s.pos[owner].push(
                IFIDC_Optimized.Investment({
                    amount: uint128(values[i]),
                    date: uint64(block.timestamp),
                    yieldStart: uint64(block.timestamp),
                    class: classIds[i],
                    serieId: serieId
                })
            );

            invIds[i] = ++s.cnt;
            emit IFIDC_Optimized.Invested(owner, purchaseId, values[i], calculatedTokens, s.id);
        }

        // ✅ GESTÃO DE SÉRIE (após processar todos os investimentos)
        if (bytes(serieId).length > 0) {
            // Atualizar série
            s.series[serieId].totalCaptated += totalValueWad;
            s.series[serieId].totalQuotas += totalTokens;
            s.series[serieId].totalInvestments += classIds.length;
            s.series[serieId].lastInvestmentAt = block.timestamp;

            // Atualizar total de todas as séries (O(1))
            s.totalCaptatedSeries += totalValueWad;
            s.totalSeriesQuotas += totalTokens;

            // Adicionar investidor à série (se ainda não estiver)
            if (!s.investorInSeries[owner][serieId]) {
                s.seriesInvestors[serieId].push(owner);
                s.investorInSeries[owner][serieId] = true;
            }

            // ✅ FASE 2: Atualizar estatísticas por classe
            SeriesClassStats storage stats = s.seriesClassStats[serieId];

            // Processar cada investimento para atualizar estatísticas por classe
            for (uint256 i = 0; i < classIds.length; i++) {
                uint256 calculatedTokens = (values[i] * 1e18) / s.currentAssetPrice;

                if (classIds[i] == 0) {
                    stats.seniorCaptated += values[i];
                    stats.seniorQuotas += calculatedTokens;
                    // ✅ FIX CRÍTICO: Usar mapping O(1) ao invés de loop O(n)
                    if (!s.seniorInSeriesList[serieId][owner]) {
                        stats.seniorInvestorList.push(owner);
                        stats.seniorInvestors++;
                        s.seniorInSeriesList[serieId][owner] = true;
                    }
                } else if (classIds[i] == 1) {
                    stats.mezzCaptated += values[i];
                    stats.mezzQuotas += calculatedTokens;
                    // ✅ FIX CRÍTICO: Usar mapping O(1) ao invés de loop O(n)
                    if (!s.mezzInSeriesList[serieId][owner]) {
                        stats.mezzInvestorList.push(owner);
                        stats.mezzInvestors++;
                        s.mezzInSeriesList[serieId][owner] = true;
                    }
                } else {
                    stats.juniorCaptated += values[i];
                    stats.juniorQuotas += calculatedTokens;
                    // ✅ FIX CRÍTICO: Usar mapping O(1) ao invés de loop O(n)
                    if (!s.juniorInSeriesList[serieId][owner]) {
                        stats.juniorInvestorList.push(owner);
                        stats.juniorInvestors++;
                        s.juniorInSeriesList[serieId][owner] = true;
                    }
                }
            }

            // ✅ FASE 4: Verificar e emitir eventos de milestones (após atualizar totalQuotas)
            SeriesInfo storage seriesForMilestones = s.series[serieId];
            if (seriesForMilestones.maxQuotas > 0) {
                uint256 oldTotalQuotas = seriesForMilestones.totalQuotas - totalTokens; // Total antes do investimento
                uint256 oldPercentageBPS = (oldTotalQuotas * 10_000) / seriesForMilestones.maxQuotas;
                uint256 newPercentageBPS = (seriesForMilestones.totalQuotas * 10_000) / seriesForMilestones.maxQuotas;

                // Emitir evento se cruzou milestone (25%, 50%, 75%)
                if (oldPercentageBPS < 2_500 && newPercentageBPS >= 2_500) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 2_500);
                }
                if (oldPercentageBPS < 5_000 && newPercentageBPS >= 5_000) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 5_000);
                }
                if (oldPercentageBPS < 7_500 && newPercentageBPS >= 7_500) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 7_500);
                }
                // Emit event when series reaches 100%
                if (oldPercentageBPS < 10_000 && newPercentageBPS >= 10_000) {
                    emit IFIDC_Optimized.SeriesComplete(serieId);
                }
            }
        } else {
            // Sem série: atualizar variável pública totalCaptated
            s.totalCaptated += totalValueWad;
        }

        if (!s.isI[owner]) s.invs.push(owner);
        s.isI[owner] = true;
        s.purs[purchaseId] = owner;

        return invIds;
    }

    function investBatchPre(
        string calldata purchaseId,
        address owner,
        uint8[] calldata classIds,
        uint256[] calldata values,
        uint256 totalQuotas,
        string calldata serieId
    ) external returns (uint256[] memory invIds) {
        State storage s = state();
        if (s.fidc.paused) revert FIDCErrors.ContractPaused();
        _require(s, msg.sender, ROLE_ADMIN);

        if (bytes(purchaseId).length == 0 || s.purs[purchaseId] != address(0)) {
            revert FIDCErrors.PurchaseAlreadyProcessed(purchaseId);
        }
        if (classIds.length == 0 || classIds.length != values.length) {
            revert FIDCErrors.ValidationFailed();
        }

        bool hasSeries = bytes(serieId).length > 0;

        // Validar assetPrice != 0
        if (s.currentAssetPrice == 0) revert FIDCErrors.ValidationFailed();
        uint256 totalValueWad;
        uint256 totalTokens;
        {
            // Keep the heavy accumulator struct scoped to reduce stack pressure in coverage builds.
            BatchSums memory sums;
            if (hasSeries) {
                sums = _sumBatchWithSeries(s, owner, classIds, values, serieId);
            } else {
                sums = _sumBatchNoSeries(s, owner, classIds, values);
            }

            // Validar limites de classe usando acumuladores (evita bypass de cap)
            if (s.maxSeniorBps > 0) {
                uint256 cap = (totalQuotas * s.maxSeniorBps) / YieldCalculator.PRECISION;
                if (s.sTok + sums.addSTok > cap) revert FIDCErrors.ValidationFailed();
            }
            if (s.maxMezzBps > 0) {
                uint256 cap = (totalQuotas * s.maxMezzBps) / YieldCalculator.PRECISION;
                if (s.mTok + sums.addMTok > cap) revert FIDCErrors.ValidationFailed();
            }
            if (s.maxJuniorBps > 0) {
                uint256 cap = (totalQuotas * s.maxJuniorBps) / YieldCalculator.PRECISION;
                if (s.jTok + sums.addJTok > cap) revert FIDCErrors.ValidationFailed();
            }

            // ✅ VALIDAR LIMITES DE SÉRIE (se fornecido)
            if (hasSeries) {
                SeriesInfo storage series = s.series[serieId];
                if (series.maxQuotas > 0) {
                    require(series.totalQuotas + sums.totalTokens <= series.maxQuotas, "Series max quotas exceeded");
                }
                if (s.maxQ > 0) {
                    require(s.totalSeriesQuotas + sums.totalTokens <= s.maxQ, "Total FIDC quotas exceeded");
                }
            }

            totalValueWad = sums.totalValue;
            totalTokens = sums.totalTokens;
        }

        _collectInvestmentFunds(s, owner, totalValueWad);

        invIds = new uint256[](classIds.length);

        // Processar cada investimento
        for (uint256 i = 0; i < classIds.length; i++) {
            uint256 calculatedTokens = (values[i] * 1e18) / s.currentAssetPrice;

            if (classIds[i] == 0) {
                s.sInv += values[i];
                s.sTok += calculatedTokens;
            } else if (classIds[i] == 1) {
                s.mInv += values[i];
                s.mTok += calculatedTokens;
            } else {
                s.jTok += calculatedTokens;
            }

            _recordInvestmentPosition(s, owner, values[i], classIds[i], serieId);

            invIds[i] = ++s.cnt;
            emit IFIDC_Optimized.Invested(owner, purchaseId, values[i], calculatedTokens, s.id);
        }

        if (bytes(serieId).length > 0) {
            s.series[serieId].totalCaptated += totalValueWad;
            s.series[serieId].totalQuotas += totalTokens;
            s.series[serieId].totalInvestments += classIds.length;
            s.series[serieId].lastInvestmentAt = block.timestamp;

            s.totalCaptatedSeries += totalValueWad;
            s.totalSeriesQuotas += totalTokens;

            if (!s.investorInSeries[owner][serieId]) {
                s.seriesInvestors[serieId].push(owner);
                s.investorInSeries[owner][serieId] = true;
            }

            SeriesClassStats storage stats = s.seriesClassStats[serieId];
            for (uint256 i = 0; i < classIds.length; i++) {
                uint256 calculatedTokens = (values[i] * 1e18) / s.currentAssetPrice;

                if (classIds[i] == 0) {
                    stats.seniorCaptated += values[i];
                    stats.seniorQuotas += calculatedTokens;
                    if (!s.seniorInSeriesList[serieId][owner]) {
                        stats.seniorInvestorList.push(owner);
                        stats.seniorInvestors++;
                        s.seniorInSeriesList[serieId][owner] = true;
                    }
                } else if (classIds[i] == 1) {
                    stats.mezzCaptated += values[i];
                    stats.mezzQuotas += calculatedTokens;
                    if (!s.mezzInSeriesList[serieId][owner]) {
                        stats.mezzInvestorList.push(owner);
                        stats.mezzInvestors++;
                        s.mezzInSeriesList[serieId][owner] = true;
                    }
                } else {
                    stats.juniorCaptated += values[i];
                    stats.juniorQuotas += calculatedTokens;
                    if (!s.juniorInSeriesList[serieId][owner]) {
                        stats.juniorInvestorList.push(owner);
                        stats.juniorInvestors++;
                        s.juniorInSeriesList[serieId][owner] = true;
                    }
                }
            }

            SeriesInfo storage seriesForMilestones = s.series[serieId];
            if (seriesForMilestones.maxQuotas > 0) {
                uint256 oldTotalQuotas = seriesForMilestones.totalQuotas - totalTokens;
                uint256 oldPercentageBPS = (oldTotalQuotas * 10_000) / seriesForMilestones.maxQuotas;
                uint256 newPercentageBPS = (seriesForMilestones.totalQuotas * 10_000) / seriesForMilestones.maxQuotas;

                if (oldPercentageBPS < 2_500 && newPercentageBPS >= 2_500) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 2_500);
                }
                if (oldPercentageBPS < 5_000 && newPercentageBPS >= 5_000) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 5_000);
                }
                if (oldPercentageBPS < 7_500 && newPercentageBPS >= 7_500) {
                    emit IFIDC_Optimized.SeriesMilestoneReached(serieId, 7_500);
                }
                if (oldPercentageBPS < 10_000 && newPercentageBPS >= 10_000) {
                    emit IFIDC_Optimized.SeriesComplete(serieId);
                }
            }
        } else {
            s.totalCaptated += totalValueWad;
        }

        if (!s.isI[owner]) s.invs.push(owner);
        s.isI[owner] = true;
        s.purs[purchaseId] = owner;

        return invIds;
    }

    /**
     * @notice Antecipação com collateral ratio customizável
     * @dev OBRIGATÓRIO: customCollateralRatio deve ser sempre > 0 e entre 100-300
     * @param pj Endereço do cedente (Pessoa Jurídica)
     * @param amount Valor a antecipar em WAD (18 decimais)
     * @param colToken Endereço do token de colateral (address(0) = recebível interno)
     * @param customCollateralRatio Ratio customizado (OBRIGATÓRIO: 100-300, sem valores padrão)
     */
    function anticipateWithRatio(address pj, uint256 amount, address colToken, uint16 customCollateralRatio) internal {
        _anticipateInternal(pj, amount, colToken, customCollateralRatio, false);
    }

    /**
     * @notice Antecipação com collateral ratio customizável (sem transferir stable token)
     * @dev Used when funds have already been transferred from another source (vault, wallet, etc)
     * @dev REQUIRED: customCollateralRatio must always be > 0 and between 100-300
     * @param pj Creditor address (Legal Entity)
     * @param amount Amount to anticipate in WAD (18 decimals)
     * @param colToken Collateral token address (address(0) = internal receivable)
     * @param customCollateralRatio Ratio customizado (OBRIGATÓRIO: 100-300, sem valores padrão)
     */
    function anticipateWithRatioSkipTransfer(address pj, uint256 amount, address colToken, uint16 customCollateralRatio)
        internal
    {
        _anticipateInternal(pj, amount, colToken, customCollateralRatio, true);
    }

    /**
     * @notice Implementação interna de antecipação
     * @dev Lógica compartilhada entre anticipate() e anticipateWithRatio()
     * @param skipTransfer Se true, não transfere stable token (fundos já vieram de outra fonte)
     */
    function _anticipateInternal(
        address pj,
        uint256 amount,
        address colToken,
        uint16 customCollateralRatio,
        bool skipTransfer
    ) internal {
        State storage s = state();
        if (s.fidc.paused) revert FIDCErrors.ContractPaused();
        _require(s, msg.sender, ROLE_COLL);
        if (pj == address(0)) revert FIDCErrors.ZeroAddress();
        if (amount == 0) revert FIDCErrors.ZeroAmount();
        uint8 dec = IERC20Metadata(address(s.stable)).decimals();
        uint256 amtNative = FIDCDistributionLib.scaleFromWad(amount, dec);
        // ✅ If skipTransfer = false, check FIDC balance (funds come from FIDC itself)
        // ✅ If skipTransfer = true, do not check balance (funds already came from another source)
        if (!skipTransfer && s.stable.balanceOf(address(this)) < amtNative) revert FIDCErrors.InsufficientLiquidity();
        FIDCDistributionLib.DebtorInfo storage d = s.debs[pj];

        // ✅ OBRIGATÓRIO: customCollateralRatio deve ser sempre fornecido (sem valores padrão)
        // Ratio deve estar entre 100% e 300%
        if (customCollateralRatio < 100 || customCollateralRatio > 300) {
            revert FIDCErrors.ValidationFailed();
        }
        uint16 ratio = customCollateralRatio;

        // Atualizar exposure e dueWad (dueWad = soma de amount * ratio / 100)
        d.exposure += amount;
        uint256 dueAdd = (amount * ratio) / 100;
        d.dueWad += dueAdd;

        uint256 colReqWad = (amount * ratio) / 100;
        uint256 colReqNative;
        if (colToken == address(0)) {
            IReceivable(s.token).mint(address(this), colReqWad);
            colReqNative = colReqWad;
            d.internalReceivableLocked += colReqWad;
        } else {
            // ✅ FIX: Limitar tokens de colateral por devedor (prevenir DoS)
            if (d.lockedByTokenWad[colToken] == 0) {
                require(d.collateralTokens.length < MAX_COLLATERAL_TOKENS_PER_DEBTOR, "Too many collateral tokens");
                d.collateralTokens.push(colToken);
            }

            // ✅ FIX: Try/catch for collateral decimals (ERC20); NFT (ERC721/1155) não tem decimals()
            uint8 decCol = 0;
            bool isNFT = false;
            try IERC20Metadata(colToken).decimals() returns (uint8 decimals) {
                decCol = decimals;
                if (decCol == 0 || decCol > 18) revert FIDCErrors.ValidationFailed();
            } catch {
                // Colateral sem decimals() = NFT (ERC721/ERC1155). Custódia é feita pelo UnifiedFactoryManager.
                decCol = IERC20Metadata(address(s.stable)).decimals();
                isNFT = true;
            }
            colReqNative = FIDCDistributionLib.scaleFromWad(colReqWad, decCol);
            if (!isNFT) {
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(colToken).safeTransferFrom(pj, address(this), colReqNative);
            }
            d.lockedByTokenWad[colToken] += colReqWad;
        }
        s.fidc.amount += uint128(amount);
        // ✅ Se skipTransfer = false, transfere do saldo do FIDC para o cedente
        // ✅ If skipTransfer = true, do not transfer (funds already transferred from another source)
        if (!skipTransfer) {
            s.stable.safeTransfer(pj, amtNative);
        }
        emit IFIDC_Optimized.Anticipated(s.id, pj, amount, colToken, colReqNative);
        // Novo evento com ratio usado
        emit IFIDC_Optimized.AnticipatedWithRatio(s.id, pj, amount, colToken, colReqNative, ratio);
    }

    /**
     * @notice Compensação pelo próprio devedor
     * @dev ✅ NOVA LÓGICA: Aceita overpayment e distingue dívida de juros
     * @param payAmount Valor a pagar em WAD (18 decimais) - pode ser maior que dueWad (juros)
     * @param pj Endereço do devedor (que está pagando)
     */
    function compensate(uint256 payAmount, address pj) internal {
        State storage s = state();
        if (s.fidc.paused) revert FIDCErrors.ContractPaused();
        _require(s, msg.sender, ROLE_PAY);
        if (payAmount == 0) revert FIDCErrors.ZeroAmount();
        if (pj == address(0)) revert FIDCErrors.ZeroAddress();
        FIDCDistributionLib.DebtorInfo storage d = s.debs[pj];
        if (d.exposure == 0) revert FIDCErrors.NoDebt();

        // ✅ NOVA LÓGICA: Aceitar overpayment - o excesso será considerado juros
        uint256 debtToPay = payAmount > d.dueWad ? d.dueWad : payAmount;
        uint256 interestAmount = payAmount > d.dueWad ? payAmount - d.dueWad : 0;

        uint8 dec = IERC20Metadata(address(s.stable)).decimals();
        uint256 payNative = FIDCDistributionLib.scaleFromWad(payAmount, dec);
        // NOTE: operator-driven flow; production must use UnifiedFactoryManager *Authorized variants.
        // slither-disable-next-line arbitrary-send-erc20
        s.stable.safeTransferFrom(pj, address(this), payNative);
        _compensateInternal(s, debtToPay, interestAmount, d, pj);
    }

    /**
     * @notice Compensação em nome de um devedor por um terceiro pagador
     * @dev ✅ NOVA LÓGICA: Aceita overpayment e distingue dívida de juros
     * @dev O colateral é queimado apenas proporcionalmente à dívida (dueWad), não aos juros
     * @param payAmount Valor a pagar em WAD (18 decimais) - pode ser maior que dueWad (juros)
     * @param payer Endereço que está pagando
     * @param debtor Endereço do devedor
     * @return result Estrutura com detalhamento de dívida paga, juros pagos e colateral queimado
     */
    function compensateFor(uint256 payAmount, address payer, address debtor)
        internal
        returns (CompensationResult memory result)
    {
        State storage s = state();
        if (s.fidc.paused) revert FIDCErrors.ContractPaused();
        _require(s, msg.sender, ROLE_PAY);
        if (payAmount == 0) revert FIDCErrors.ZeroAmount();
        if (payer == address(0) || debtor == address(0)) revert FIDCErrors.ZeroAddress();
        FIDCDistributionLib.DebtorInfo storage d = s.debs[debtor];
        if (d.exposure == 0) revert FIDCErrors.NoDebt();

        // ✅ NOVA LÓGICA: Aceitar overpayment - o excesso será considerado juros
        uint256 debtToPay = payAmount > d.dueWad ? d.dueWad : payAmount;
        uint256 interestAmount = payAmount > d.dueWad ? payAmount - d.dueWad : 0;

        uint8 dec = IERC20Metadata(address(s.stable)).decimals();
        uint256 payNative = FIDCDistributionLib.scaleFromWad(payAmount, dec);
        // NOTE: operator-driven flow; production must use UnifiedFactoryManager *Authorized variants.
        // slither-disable-next-line arbitrary-send-erc20
        s.stable.safeTransferFrom(payer, address(this), payNative);

        result = _compensateInternal(s, debtToPay, interestAmount, d, debtor);
    }

    /**
     * @notice Compensação interna com queima de colateral
     * @dev ✅ NOVA LÓGICA: Distingue dívida de juros e queima colateral apenas proporcionalmente à dívida
     * @param debtToPay Valor da dívida a pagar (relacionado ao colateral) em WAD
     * @param interestAmount Valor pago como juros (excesso sobre a dívida) em WAD
     * @param d Informações do devedor
     * @param debtor Endereço do devedor
     * @return result Estrutura com detalhamento de dívida paga, juros pagos e colateral queimado
     */
    function _compensateInternal(
        State storage s,
        uint256 debtToPay,
        uint256 interestAmount,
        FIDCDistributionLib.DebtorInfo storage d,
        address debtor
    ) private returns (CompensationResult memory result) {
        uint256 exposureBefore = d.exposure;
        uint256 dueBefore = d.dueWad;

        // ✅ NOVA LÓGICA: Separar dívida de juros
        result.debtPaidWad = debtToPay;
        result.interestPaidWad = interestAmount;
        result.debtFullyPaid = debtToPay >= dueBefore;

        // Usar struct para reduzir stack (e evitar falso-positivo do Slither sobre init)
        CompCtx memory c = CompCtx({
            payWad: debtToPay, // ✅ IMPORTANTE: Usar apenas debtToPay para cálculo de colateral
            principalPaidWad: 0,
            burnedSumWad: 0,
            totalLockedWad: 0,
            colToBurnWad: 0,
            stableDec: 0
        });

        // Principal pago proporcional ao "due" total (não ao ratio padrão)
        c.principalPaidWad = dueBefore == 0 ? 0 : (c.payWad * d.exposure) / dueBefore;
        if (c.principalPaidWad > d.exposure) c.principalPaidWad = d.exposure;

        c.totalLockedWad = d.internalReceivableLocked;
        for (uint256 i; i < d.collateralTokens.length; ++i) {
            c.totalLockedWad += d.lockedByTokenWad[d.collateralTokens[i]];
        }

        // ✅ IMPORTANTE: Burn proporcional APENAS ao debtToPay (dívida), NÃO aos juros
        // O colateral está vinculado à dívida original, não aos juros
        c.colToBurnWad = c.totalLockedWad == 0 || dueBefore == 0 ? 0 : (c.totalLockedWad * c.payWad) / dueBefore;
        if (c.colToBurnWad > c.totalLockedWad) c.colToBurnWad = c.totalLockedWad;

        // ✅ FIX BUG CRÍTICO #5: Calcular e queimar colateral corretamente
        // Aplicar cap ANTES de somar no acumulador para garantir cálculo determinístico
        c.burnedSumWad = 0;
        uint256 remainingToBurnWad = c.colToBurnWad; // Variável dedicada para controle do restante

        // Queimar recebível interno primeiro
        uint256 internalShare =
            c.totalLockedWad == 0 ? 0 : (d.internalReceivableLocked * c.colToBurnWad) / c.totalLockedWad;
        if (internalShare > d.internalReceivableLocked) internalShare = d.internalReceivableLocked;
        if (internalShare > remainingToBurnWad) internalShare = remainingToBurnWad;

        if (internalShare > 0) {
            // ✅ FIX: Usar burnFrom para queimar do contrato (não do msg.sender)
            // O recebível foi mintido para address(this) durante antecipação
            IReceivable(s.token).burnFrom(address(this), internalShare);
            d.internalReceivableLocked -= internalShare;
            c.burnedSumWad += internalShare;
            remainingToBurnWad -= internalShare;
            emit IFIDC_Optimized.CollateralBurned(s.id, debtor, s.token, internalShare, internalShare);
        }

        // ✅ FIX: Queimar colateral externo (tokens ERC20)
        // Calcular proporcionalmente e aplicar cap antes de somar
        for (uint256 i; i < d.collateralTokens.length; ++i) {
            if (remainingToBurnWad == 0) break; // Already burned everything needed

            address t = d.collateralTokens[i];
            uint256 lockedWad = d.lockedByTokenWad[t];
            if (lockedWad == 0) continue;

            // Calcular share proporcional
            uint256 shareWad = c.totalLockedWad == 0 ? 0 : (lockedWad * c.colToBurnWad) / c.totalLockedWad;

            // ✅ FIX: Aplicar cap ANTES de somar no acumulador
            if (shareWad > lockedWad) shareWad = lockedWad;
            if (shareWad > remainingToBurnWad) shareWad = remainingToBurnWad;

            if (shareWad > 0) {
                uint8 decCol;
                try IERC20Metadata(t).decimals() returns (uint8 decT) {
                    decCol = decT;
                } catch {
                    // NFT (ERC721/ERC1155): sem decimals(); uso stable para valor contábil; não queimar no FIDC
                    decCol = IERC20Metadata(address(s.stable)).decimals();
                }
                uint256 shareNative = FIDCDistributionLib.scaleFromWad(shareWad, decCol);

                // Tentar burn/transfer apenas para ERC20 (NFT é contabilizado no FIDCModuleLib via AnticipationRecord)
                try IERC20BurnableLike(t).burn(shareNative) {}
                catch {
                    try IERC20BurnableLike(t).burnFrom(address(this), shareNative) {}
                    catch {
                        // transfer é external; safeTransfer seria library call (não permitido em try)
                        try IERC20(t).transfer(address(0xdead), shareNative) {}
                            catch {
                            // Token não é ERC20 fungível (ex.: NFT): só atualizar contabilidade
                        }
                    }
                }

                d.lockedByTokenWad[t] -= shareWad;
                c.burnedSumWad += shareWad;
                remainingToBurnWad -= shareWad;
                emit IFIDC_Optimized.CollateralBurned(s.id, debtor, t, shareWad, shareNative);
            }
        }

        // ✅ FIX: Limpar tokens com saldo zero após queima (prevenir crescimento infinito)
        // Usar loop reverso para permitir remoção segura
        for (uint256 i = d.collateralTokens.length; i > 0;) {
            --i;
            address t = d.collateralTokens[i];
            if (d.lockedByTokenWad[t] == 0) {
                // Swap com último elemento e pop
                if (i < d.collateralTokens.length - 1) {
                    d.collateralTokens[i] = d.collateralTokens[d.collateralTokens.length - 1];
                }
                d.collateralTokens.pop();
            }
        }

        // Atualizar saldos - apenas com base na dívida paga, não nos juros
        d.dueWad = dueBefore > c.payWad ? dueBefore - c.payWad : 0;
        d.exposure -= c.principalPaidWad;
        s.fidc.amount -= uint128(c.principalPaidWad);

        // ✅ NOVO EVENTO: Evidenciar claramente dívida paga vs juros pagos
        emit IFIDC_Optimized.CompensatedWithInterest(
            s.id,
            debtor,
            result.debtPaidWad,
            result.interestPaidWad,
            c.principalPaidWad,
            exposureBefore,
            d.exposure,
            c.burnedSumWad,
            result.debtFullyPaid
        );

        // Evento compatível (mantido para retrocompatibilidade)
        emit IFIDC_Optimized.CompensatedStats(
            s.id, debtor, c.payWad, c.principalPaidWad, exposureBefore, d.exposure, c.burnedSumWad
        );

        // ✅ Retornar resultado detalhado
        result.collateralBurnedWad = c.burnedSumWad;
        return result;
    }

    /* ====================== SERIES MANAGEMENT ====================== */

    /**
     * @notice Helper para calcular total de quotas de todas as séries
     */
    function _calculateTotalSeriesQuotas(State storage s) private view returns (uint256 total) {
        for (uint256 i = 0; i < s.seriesIds.length; i++) {
            total += s.series[s.seriesIds[i]].totalQuotas;
        }
    }

    /**
     * @notice Cria uma nova série no FIDC (explicitamente)
     * @param serieId ID único da série (não pode ser vazio)
     * @param maxQuotas Limite máximo de quotas para esta série (0 = ilimitado)
     * @param allowSenior Se classe Senior pode investir nesta série
     * @param allowMezz Se classe Mezzanine pode investir nesta série
     * @param allowJunior Se classe Junior pode investir nesta série
     * @dev ✅ FASE 1: Adicionado suporte para restrição de classes por série
     *      maxQ validation happens in investPre/investBatchPre when quotas are issued
     *      Pelo menos uma classe deve ser permitida (validação abaixo)
     */
    function createSeries(
        string calldata serieId,
        uint256 maxQuotas,
        bool allowSenior,
        bool allowMezz,
        bool allowJunior
    ) internal {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);

        // ✅ FIX MÉDIO: Limitar tamanho de strings para prevenir DoS/gas
        require(bytes(serieId).length > 0 && bytes(serieId).length <= 32, "Invalid serieId length");
        require(!s.seriesExists[serieId], "Series already exists");

        // ✅ FASE 1: Validar que pelo menos uma classe é permitida
        require(allowSenior || allowMezz || allowJunior, "At least one class must be allowed");

        // ✅ FIX: Do not validate maxQ here - maxQ limits issued quotas, not configured limits
        // Validation happens in investPre/investBatchPre when quotas are actually issued

        s.series[serieId] = SeriesInfo({
            serieId: serieId,
            totalCaptated: 0,
            totalQuotas: 0,
            maxQuotas: maxQuotas,
            totalInvestments: 0,
            active: true,
            createdAt: block.timestamp,
            lastInvestmentAt: 0,
            allowSenior: allowSenior,
            allowMezz: allowMezz,
            allowJunior: allowJunior
        });

        s.seriesIds.push(serieId);
        s.seriesExists[serieId] = true;
    }

    /**
     * @notice Atualiza limite máximo de quotas de uma série
     * @param serieId ID da série
     * @param newMaxQuotas Novo limite máximo (0 = ilimitado)
     * @dev ✅ FIX CRÍTICO: maxQ limita quotas EMITIDAS (totalSupply), não limites configurados
     *      Então só precisamos garantir que newMaxQuotas >= totalQuotas emitidas nesta série
     */
    function updateSeriesMaxQuotas(string calldata serieId, uint256 newMaxQuotas) internal {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);

        require(s.seriesExists[serieId], "Series does not exist");

        // ✅ FIX: Only ensure new limit >= already issued quotas (if not unlimited)
        // maxQ already limits total issued quotas via totalSeriesQuotas in investPre/investBatchPre
        require(newMaxQuotas == 0 || newMaxQuotas >= s.series[serieId].totalQuotas, "New max must be >= issued quotas");

        s.series[serieId].maxQuotas = newMaxQuotas;
    }

    /**
     * @notice Desativa uma série (não permite mais investimentos)
     * @param serieId ID da série
     */
    function deactivateSeries(string calldata serieId) internal {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);

        require(s.seriesExists[serieId], "Series does not exist");
        s.series[serieId].active = false;
    }

    /**
     * @notice Retorna informações de uma série específica
     */
    function getSeries(string calldata serieId) external view returns (SeriesInfo memory) {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");
        return s.series[serieId];
    }

    /**
     * @notice Retorna todas as séries do FIDC
     */
    function getAllSeries() external view returns (string[] memory) {
        return state().seriesIds;
    }

    /**
     * @notice Retorna investidores de uma série específica
     */
    function getSeriesInvestors(string calldata serieId) external view returns (address[] memory) {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");
        return s.seriesInvestors[serieId];
    }

    /**
     * @notice Retorna estatísticas detalhadas por classe de uma série
     * @param serieId ID da série
     * @return Estatísticas por classe (captado, quotas, investidores)
     * @dev ✅ FASE 2: Nova função para consultar informações detalhadas por classe
     */
    function getSeriesClassStats(string calldata serieId) external view returns (SeriesClassStats memory) {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");
        return s.seriesClassStats[serieId];
    }

    /**
     * @notice Retorna lista de investidores de uma classe específica em uma série
     * @param serieId ID da série
     * @param classId ID da classe (0=Senior, 1=Mezzanine, 2=Junior)
     * @return Lista de endereços de investidores da classe especificada
     * @dev ✅ FASE 2: Nova função para consultar investidores por classe
     */
    function getSeriesInvestorsByClass(string calldata serieId, uint8 classId)
        external
        view
        returns (address[] memory)
    {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");
        require(classId <= 2, "Invalid class");

        SeriesClassStats storage stats = s.seriesClassStats[serieId];
        if (classId == 0) return stats.seniorInvestorList;
        if (classId == 1) return stats.mezzInvestorList;
        return stats.juniorInvestorList;
    }

    /**
     * @notice Retorna quantas quotas restam em uma série
     * @param serieId ID da série
     * @return remaining Quantidade de quotas restantes (type(uint256).max se ilimitado)
     * @return isUnlimited true se a série é ilimitada (maxQuotas == 0)
     * @dev ✅ FASE 3: Função helper para facilitar consulta de quotas restantes
     */
    function getSeriesRemainingQuotas(string calldata serieId)
        external
        view
        returns (uint256 remaining, bool isUnlimited)
    {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");

        SeriesInfo storage series = s.series[serieId];
        if (series.maxQuotas == 0) {
            return (type(uint256).max, true); // Ilimitado
        }

        if (series.totalQuotas >= series.maxQuotas) {
            return (0, false); // Completo
        }

        return (series.maxQuotas - series.totalQuotas, false);
    }

    /**
     * @notice Returns fill percentage of a series
     * @param serieId Series ID
     * @return percentageBPS Percentage in basis points (0-10000, where 10000 = 100%)
     * @return isUnlimited true if series is unlimited (maxQuotas == 0)
     * @dev ✅ PHASE 3: Helper function to facilitate fill percentage query
     */
    function getSeriesFillPercentage(string calldata serieId)
        external
        view
        returns (uint256 percentageBPS, bool isUnlimited)
    {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");

        SeriesInfo storage series = s.series[serieId];
        if (series.maxQuotas == 0) {
            return (0, true); // Unlimited
        }

        if (series.maxQuotas == 0) return (0, true);
        uint256 percentage = (series.totalQuotas * 10_000) / series.maxQuotas;
        return (percentage, false);
    }

    /**
     * @notice Verifica se uma série está completa (atingiu maxQuotas)
     * @param serieId ID da série
     * @return true se a série está completa (totalQuotas >= maxQuotas)
     * @dev ✅ FASE 3: Função helper para verificar se série está completa
     *      Séries ilimitadas (maxQuotas == 0) nunca estão completas
     */
    function isSeriesComplete(string calldata serieId) external view returns (bool) {
        State storage s = state();
        require(s.seriesExists[serieId], "Series does not exist");

        SeriesInfo storage series = s.series[serieId];
        if (series.maxQuotas == 0) return false; // Ilimitado nunca está completo
        return series.totalQuotas >= series.maxQuotas;
    }

    /* ====================== VIEWS (through lib storage) ====================== */
    function getDebtorInfo(address debtor)
        external
        view
        returns (uint256 exposure, address collateralToken, uint256 collateralLocked)
    {
        State storage s = state();
        FIDCDistributionLib.DebtorInfo storage d = s.debs[debtor];
        uint256 totalLocked = d.internalReceivableLocked;
        address lt = address(0);
        address[] storage toks = d.collateralTokens;
        for (uint256 i; i < toks.length; ++i) {
            address t = toks[i];
            totalLocked += d.lockedByTokenWad[t];
            lt = t;
        }
        return (d.exposure, lt, totalLocked);
    }

    function getInvestorPositions(address investor) external view returns (IFIDC_Optimized.Investment[] memory) {
        State storage s = state();
        return s.pos[investor];
    }

    /* ====================== VAULT TRANSFER MANAGEMENT ====================== */

    /**
     * @notice Configures automatic transfer to vault or wallet
     */
    function setVaultTransferConfig(address targetAddress, uint16 transferPercentBPS, bool enabled) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);

        require(targetAddress != address(0), "Invalid target address");
        require(transferPercentBPS <= 10_000, "Percent cannot exceed 100%");

        s.vaultConfig = VaultTransferConfig({
            targetAddress: targetAddress, transferPercentBPS: transferPercentBPS, enabled: enabled
        });
    }

    /**
     * @notice Manually transfers percentage to specific address
     */
    function manualTransferToVault(address targetAddress, uint16 transferPercentBPS)
        external
        returns (uint256 transferAmount)
    {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);

        require(targetAddress != address(0), "Invalid target address");
        require(transferPercentBPS > 0 && transferPercentBPS <= 10_000, "Invalid percent");

        // Get current FIDC balance
        uint256 currentBalance = s.stable.balanceOf(address(this));
        uint8 dec = IERC20Metadata(address(s.stable)).decimals();
        uint256 currentBalanceWad = FIDCDistributionLib.scaleToWad(currentBalance, dec);

        // Calculate percentage of current balance
        transferAmount = (currentBalanceWad * transferPercentBPS) / 10_000;

        // Convert to native decimals
        uint256 transferAmountNative = FIDCDistributionLib.scaleFromWad(transferAmount, dec);

        // Validate sufficient balance
        require(transferAmountNative <= currentBalance, "Insufficient balance");

        // Transfer
        s.stable.safeTransfer(targetAddress, transferAmountNative);

        return transferAmount;
    }

    /* ====================== ADMIN HELPERS USED BY CORE ====================== */
    function isAdmin(address a) external view returns (bool) {
        State storage s = state();
        return _has(s, a, ROLE_ADMIN);
    }

    /**
     * @notice Atualiza parâmetros do FIDC
     */
    function updateFIDC(
        address _manager,
        uint32 _yield,
        uint32 _grace,
        uint32 _spread,
        uint32 _mezzSpread,
        uint256 _maxQuotas,
        uint256 _maxSenior,
        uint256 _maxMezz,
        uint256 _maxJunior,
        uint256 _feePlatform,
        address _walletPlatform
    ) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (s.fidc.paused || _manager == address(0)) revert FIDCErrors.ValidationFailed();

        // Validações de faixa
        if (_feePlatform > YieldCalculator.PRECISION) revert FIDCErrors.ValidationFailed();
        if (_maxSenior > YieldCalculator.PRECISION) revert FIDCErrors.ValidationFailed();
        if (_maxMezz > YieldCalculator.PRECISION) revert FIDCErrors.ValidationFailed();
        if (_maxJunior > YieldCalculator.PRECISION) revert FIDCErrors.ValidationFailed();

        // ✅ HIGH FIX: Consistency rule for class basis points
        // Sum of limits cannot exceed 100% (10000 BPS)
        // Note: We allow sum < 10000 for flexibility (remainder can be unallocated)
        // Only validate if any value is being updated (> 0)
        if (_maxSenior > 0 || _maxMezz > 0 || _maxJunior > 0) {
            uint256 newMaxSenior = _maxSenior > 0 ? _maxSenior : s.maxSeniorBps;
            uint256 newMaxMezz = _maxMezz > 0 ? _maxMezz : s.maxMezzBps;
            uint256 newMaxJunior = _maxJunior > 0 ? _maxJunior : s.maxJuniorBps;
            uint256 totalClassLimits = newMaxSenior + newMaxMezz + newMaxJunior;
            if (totalClassLimits > YieldCalculator.PRECISION) revert FIDCErrors.ValidationFailed();
        }

        s.fidc.manager = _manager;
        s.fidc.yield = _yield;
        s.fidc.gracePeriod = _grace;
        s.fidc.seniorSpread = _spread;
        s.fidc.mezzSpread = _mezzSpread;
        if (_maxQuotas > 0) s.maxQ = _maxQuotas;
        if (_maxSenior > 0) s.maxSeniorBps = _maxSenior;
        if (_maxMezz > 0) s.maxMezzBps = _maxMezz;
        if (_maxJunior > 0) s.maxJuniorBps = _maxJunior;
        if (_feePlatform > 0) s.fidc.feePlatform = uint32(_feePlatform);
        if (_walletPlatform != address(0)) s.fidc.walletPlatform = _walletPlatform;
    }

    /**
     * @notice Coleta taxa do gestor
     */
    function collectFee(uint256 feeAmount, address manager) external returns (uint256 feeCollected) {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (feeAmount == 0) revert FIDCErrors.ZeroAmount();

        uint256 available = s.stable.balanceOf(address(this));
        feeCollected = feeAmount > available ? available : feeAmount;

        if (feeCollected > 0) {
            s.stable.safeTransfer(manager, feeCollected);
            s.lastF = block.timestamp;
        }
    }

    /**
     * @notice Atualiza preço do asset
     */
    function updateAssetPrice(uint256 newPrice) external {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (newPrice == 0) revert FIDCErrors.ZeroAmount();
        s.currentAssetPrice = newPrice;
    }

    /**
     * @notice Calcula tokens para um valor dado
     */
    function calculateTokensForValue(uint256 value) external view returns (uint256) {
        State storage s = state();
        // ✅ FIX: Proteção contra overflow na multiplicação
        require(value <= type(uint256).max / 1e18, "Value too large for token calculation");
        require(s.currentAssetPrice > 0, "Asset price must be greater than zero");
        return (value * 1e18) / s.currentAssetPrice;
    }

    /**
     * @notice Calcula valor para um número de tokens dado
     */
    function calculateValueForTokens(uint256 tokens) external view returns (uint256) {
        State storage s = state();
        return (tokens * s.currentAssetPrice) / 1e18;
    }

    /**
     * @notice Libera colateral NFT/ERC1155 do Diamond para um destino (chamado pelo UnifiedFactoryManager)
     * @dev Requer ROLE_ADMIN (Unified tem essa role). CONTRACT_LOCK envia o NFT para o Diamond; esta função devolve ao destino.
     * @param colToken Endereço do contrato ERC721 ou ERC1155
     * @param tokenId ID do token
     * @param amount Para ERC721 deve ser 1; para ERC1155 é a quantidade
     * @param destination Endereço que receberá o NFT
     */
    function releaseCollateralTo(address colToken, uint256 tokenId, uint256 amount, address destination) internal {
        State storage s = state();
        _require(s, msg.sender, ROLE_ADMIN);
        if (destination == address(0)) revert FIDCErrors.ZeroAddress();
        if (colToken == address(0)) revert FIDCErrors.ZeroAddress();
        if (amount == 0) revert FIDCErrors.ZeroAmount();
        if (amount == 1) {
            // slither-disable-next-line arbitrary-send-erc721
            IERC721(colToken).safeTransferFrom(address(this), destination, tokenId);
        } else {
            // slither-disable-next-line arbitrary-send-erc1155
            IERC1155(colToken).safeTransferFrom(address(this), destination, tokenId, amount, "");
        }
    }
}

