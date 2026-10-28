// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FIDCManagerLib} from "../libraries/FIDCManagerLib.sol";

interface IFIDC_Optimized {
    struct CompactFIDC {
        address manager;
        address token;
        uint128 invested;
        uint128 amount;
        uint64 startDate;
        uint32 fee; // Taxa anual em basis points (ex: 200 = 2% ao ano)
        uint32 yield;
        uint32 gracePeriod;
        uint32 seniorSpread;
        uint32 mezzSpread;
        uint32 feePlatform; // taxa da plataforma (bps)
        address walletPlatform; // carteira da plataforma
        bool paused;
    }

    struct Investment {
        uint128 amount;
        uint64 date;
        uint64 yieldStart;
        uint8 class;
        string serieId; // ID da série ("" = sem série)
    }

    // Investimento simplificado usando apenas valor (stable amount)
    function investValue(string calldata pid, address owner, uint8 classId, uint256 value, string calldata serieId)
        external
        returns (uint256);

    // Investimento em lote para múltiplas classes (calcula tokens automaticamente)
    function investBatch(
        string calldata pid,
        address owner,
        uint8[] calldata classIds,
        uint256[] calldata values,
        string calldata serieId
    ) external returns (uint256[] memory invIds);
    function anticipateWithRatio(address pj, uint256 amount, address collateral, uint16 customCollateralRatio) external;
    function anticipateWithRatioSkipTransfer(
        address pj,
        uint256 amount,
        address collateral,
        uint16 customCollateralRatio
    ) external;
    /**
     * @notice Compensação em nome de um devedor por um terceiro pagador
     * @dev ✅ NOVA LÓGICA: Aceita overpayment e distingue dívida de juros
     * @dev O colateral é queimado apenas proporcionalmente à dívida (dueWad), não aos juros
     * @param payAmount Valor a pagar em WAD (18 decimais) - pode ser maior que dueWad (juros)
     * @param payer Endereço que está pagando
     * @param debtor Endereço do devedor
     * @return debtPaidWad Valor pago como dívida (relacionado ao colateral) em WAD
     * @return interestPaidWad Valor pago como juros (excesso sobre a dívida) em WAD
     * @return collateralBurnedWad Colateral queimado (proporcional apenas à dívida) em WAD
     * @return debtFullyPaid Se a dívida foi totalmente quitada (true se payAmount >= dueWad)
     */
    function compensateFor(uint256 payAmount, address payer, address debtor)
        external
        returns (uint256 debtPaidWad, uint256 interestPaidWad, uint256 collateralBurnedWad, bool debtFullyPaid);
    /// @notice Libera colateral NFT/ERC1155 do Diamond para destination (só ROLE_ADMIN, ex.: UnifiedFactoryManager)
    function releaseCollateralTo(address colToken, uint256 tokenId, uint256 amount, address destination) external;
    function updateFIDC(
        address manager,
        uint32 yield,
        uint32 grace,
        uint32 spread,
        uint32 mezzSpread,
        uint256 maxQuotas,
        uint256 maxSenior,
        uint256 maxMezz,
        uint256 maxJunior,
        uint256 feePlatform,
        address walletPlatform
    ) external;
    function collectFee(uint256 feeAmount, address manager) external returns (uint256 feeCollected);
    function approveCollateral(address[] calldata addresses, bool approved) external;
    function approvePayable(address[] calldata addresses, bool approved) external;
    function approveInvestor(address[] calldata addresses, uint8 classId) external;
    function approveInvestorForMultipleClasses(address investor, uint8[] calldata classIds) external;
    function revokeInvestor(address[] calldata addresses, uint8 classId) external;
    function grantAdmin(address[] calldata admins) external;
    function revokeAdmin(address[] calldata admins) external;
    function isAdmin(address a) external view returns (bool);
    function setCollateralRatios(address[] calldata tokens, uint16[] calldata ratios) external;
    function whitelist(address[] calldata addresses, bool w) external;
    function permitFunding(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    function setPaused(bool p) external;
    function withdraw(address to, uint256 amount) external;

    function distributeWithYieldsBatch(
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex
    )
        external
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            uint256 processedInvestors,
            uint256 nextStartIndex
        );

    /**
     * @notice Distribuição de yields em lotes (série opcional) - Interface Unified
     * @dev Versão unificada que gerencia cursors internamente (não precisa do fidcId)
     * @param serieId ID da série ("" ou "," = sem série, usa cursor global)
     * @param seniorYieldBPS Yield para Senior em basis points
     * @param mezzYieldBPS Yield para Mezzanine em basis points
     * @param juniorYieldBPS Yield para Junior em basis points
     * @param batchPercentBPS Percentual de investidores a processar (0-10000)
     * @return seniorDist Valor distribuído para Senior
     * @return mezzDist Valor distribuído para Mezzanine
     * @return juniorDist Valor distribuído para Junior
     * @return fullPayment Se pagamento foi completo
     * @return processedInvestors Número de investidores processados
     * @return nextCursor Próximo cursor para continuar distribuição
     * @return wrapped Se o cursor voltou ao início (wrapped)
     * @return newSeniorVNA Novo VNA Senior após distribuição
     * @return newMezzVNA Novo VNA Mezzanine após distribuição
     * @return seriesMode Se está em modo série (true) ou global (false)
     */
    function distributeWithYieldsBatchUnified(
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

    /**
     * @notice Distribuição em lotes com periodEnd fixo (ciclo auditável)
     * @dev Mesma ideia do distributeWithYieldsBatchUnified, mas calcula yield até um timestamp fixo.
     *      Se você executar em várias transações (horas/dias), o yield NÃO muda (desde que periodEnd seja o mesmo).
     * @param periodEnd Timestamp final do período (deve ser <= block.timestamp)
     */
    function distributeWithYieldsBatchUnifiedAt(
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint64 periodEnd
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

    /**
     * @notice PR3: Amortiza principal em lotes (ciclo auditável via periodEnd) - UNIFIED
     * @dev Função separada da distribuição de yield. Reduz `Investment.amount` pro-rata e transfere principal ao investidor.
     *      Não cobra fee de plataforma na amortização (principal).
     * @param serieId ID da série ("" ou "," = modo global)
     * @param batchPercentBPS Percentual do lote a processar (10000 = 100%)
     * @param maxAmortizationNative Cap máximo (em unidade nativa do stable) a amortizar no ciclo
     * @param periodEnd Timestamp apenas para auditoria/ciclo (deve ser <= block.timestamp)
     */
    function amortizePrincipalBatchUnifiedAt(
        string calldata serieId,
        uint256 batchPercentBPS,
        uint256 maxAmortizationNative,
        uint64 periodEnd
    )
        external
        returns (
            uint256 seniorAmortWad,
            uint256 mezzAmortWad,
            uint256 juniorAmortWad,
            bool fullAmortization,
            uint256 processedInvestors,
            uint256 nextCursor,
            bool wrapped,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            bool seriesMode
        );

    /**
     * @notice G1 — Distribuição EXPLÍCITA: paga netAmounts[i] a investors[i] do
     *         saldo stable pré-fundeado do fundo. O backend calcula o líquido
     *         (pós-retenção IR/IOF) por investidor — igual ao fan-out XRPL — e o
     *         contrato só transfere. Dá paridade EVM↔XRPL para séries com PF sem
     *         alterar a distribuição por BPS. Idempotente por payoutId.
     * @param serieId série (metadata para auditoria/evento)
     * @param investors destinatários
     * @param netAmounts valores líquidos em unidades NATIVAS do stable (já convertidos off-chain)
     * @param periodEnd fim do ciclo (metadata/auditoria)
     * @param payoutId chave de idempotência (dedup on-chain)
     * @return total soma paga
     * @return count nº de transferências
     */
    function distributeExplicit(
        string calldata serieId,
        address[] calldata investors,
        uint256[] calldata netAmounts,
        uint64 periodEnd,
        bytes32 payoutId
    ) external returns (uint256 total, uint256 count);

    /**
     * @notice Simula distribuição com yields e retorna informações detalhadas por investidor
     * @param serieId ID da série ("" ou "," = modo global)
     * @param seniorYieldBPS Yield Senior em basis points (10000 = 100%)
     * @param mezzYieldBPS Yield Mezzanine em basis points
     * @param juniorYieldBPS Yield Junior em basis points
     * @param batchPercentBPS Percentual do lote a processar (10000 = 100%)
     * @param startIndex Índice inicial para processar
     * @return totalSeniorVNAWad VNA total Senior na série/batch (WAD)
     * @return totalMezzVNAWad VNA total Mezzanine na série/batch (WAD)
     * @return totalJuniorVNAWad VNA total Junior na série/batch (WAD)
     * @return totalSeniorDistWad Distribuição total Senior (WAD)
     * @return totalMezzDistWad Distribuição total Mezzanine (WAD)
     * @return totalJuniorDistWad Distribuição total Junior (WAD)
     * @return processedInvestors Número de investidores processados
     * @return nextStartIndex Próximo índice para continuar distribuição
     * @return fullPayment Se todos os juros foram pagos
     * @return seriesMode Se está em modo série
     * @return investors Array de endereços dos investidores
     * @return classIds Array de classes dos investidores
     * @return vnaWads Array de VNAs dos investidores (WAD)
     * @return percentageBPSs Array de percentuais na classe (BPS)
     * @return expectedInterestWads Array de juros esperados (WAD)
     * @return distributionWads Array de distribuições totais (WAD)
     * @return interestWads Array de partes de juros (WAD)
     * @return amortizationWads Array de partes de amortização (WAD)
     */
    function calculateDistributionWithYieldsBatch(
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
            uint256 totalSeniorVNAWad,
            uint256 totalMezzVNAWad,
            uint256 totalJuniorVNAWad,
            uint256 totalSeniorDistWad,
            uint256 totalMezzDistWad,
            uint256 totalJuniorDistWad,
            uint256 processedInvestors,
            uint256 nextStartIndex,
            bool fullPayment,
            bool seriesMode,
            address[] memory investors,
            uint8[] memory classIds,
            uint256[] memory vnaWads,
            uint256[] memory percentageBPSs,
            uint256[] memory expectedInterestWads,
            uint256[] memory distributionWads,
            uint256[] memory interestWads,
            uint256[] memory amortizationWads
        );

    /**
     * @notice Simula a distribuição em batch com periodEnd fixo (ciclo auditável)
     * @dev Mesmo output de calculateDistributionWithYieldsBatch, mas usando currentTime = periodEnd.
     * @param periodEnd Timestamp final do período (deve ser <= block.timestamp)
     * @return totalSeniorVNAWad VNA total Senior no batch (WAD)
     * @return totalMezzVNAWad VNA total Mezzanine no batch (WAD)
     * @return totalJuniorVNAWad VNA total Junior no batch (WAD)
     * @return totalSeniorDistWad Distribuição total Senior (WAD)
     * @return totalMezzDistWad Distribuição total Mezzanine (WAD)
     * @return totalJuniorDistWad Distribuição total Junior (WAD)
     * @return processedInvestors Número de investidores processados
     * @return nextStartIndex Próximo índice para continuar
     * @return fullPayment Se todos os juros foram pagos
     * @return seriesMode Se está em modo série
     * @dev NOTA: Retorna APENAS totais (sem arrays) para evitar "stack too deep".
     *      Para arrays detalhados de investidores, use calculateDistributionWithYieldsBatch após o ciclo.
     */
    function calculateDistributionWithYieldsBatchAt(
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex,
        uint64 periodEnd
    )
        external
        view
        returns (
            uint256 totalSeniorVNAWad,
            uint256 totalMezzVNAWad,
            uint256 totalJuniorVNAWad,
            uint256 totalSeniorDistWad,
            uint256 totalMezzDistWad,
            uint256 totalJuniorDistWad,
            uint256 processedInvestors,
            uint256 nextStartIndex,
            bool fullPayment,
            bool seriesMode
        );

    /**
     * @notice Reset batch distribution cursor (global or by series)
     * @param serieId ID da série ("" ou "," = sem série, reseta cursor global)
     */
    function resetDistributionCursor(string calldata serieId) external;

    function getStableToken() external view returns (address);
    function getWhitelistedWallet() external view returns (address);
    function setWhitelistedWallet(address walletAddress) external;

    // Views
    function getFIDC() external view returns (CompactFIDC memory);
    function getInvestorPositions(address investor) external view returns (Investment[] memory);
    function getDebtorInfo(address debtor)
        external
        view
        returns (uint256 exposure, address collateralToken, uint256 collateralLocked);

    // Series management
    function createSeries(
        string calldata serieId,
        uint256 maxQuotas,
        bool allowSenior,
        bool allowMezz,
        bool allowJunior
    ) external;
    function updateSeriesMaxQuotas(string calldata serieId, uint256 newMaxQuotas) external;
    function deactivateSeries(string calldata serieId) external;
    function getSeries(string calldata serieId) external view returns (FIDCManagerLib.SeriesInfo memory);
    function getAllSeries() external view returns (string[] memory);
    function getSeriesInvestors(string calldata serieId) external view returns (address[] memory);
    function getTotalCaptated() external view returns (uint256);
    function getTotalCaptatedSeries() external view returns (uint256);
    function getSeriesClassStats(string calldata serieId) external view returns (FIDCManagerLib.SeriesClassStats memory);
    function getSeriesInvestorsByClass(string calldata serieId, uint8 classId) external view returns (address[] memory);
    function getSeriesRemainingQuotas(string calldata serieId)
        external
        view
        returns (uint256 remaining, bool isUnlimited);
    function getSeriesFillPercentage(string calldata serieId)
        external
        view
        returns (uint256 percentageBPS, bool isUnlimited);
    function isSeriesComplete(string calldata serieId) external view returns (bool);

    // Vault transfer management
    function setVaultTransferConfig(address targetAddress, uint16 transferPercentBPS, bool enabled) external;
    function manualTransferToVault(address targetAddress, uint16 transferPercentBPS)
        external
        returns (uint256 transferAmount);
    function getInvestorApproval(address investor, uint8 classId) external view returns (bool);
    function getCollateralApproval(address operator) external view returns (bool);
    function getPayableApproval(address operator) external view returns (bool);
    function getCurrentAssetPrice() external view returns (uint256);
    function getTotalQuotasIssued() external view returns (uint256);
    function calculateTokensForValue(uint256 value) external view returns (uint256);
    function calculateValueForTokens(uint256 tokens) external view returns (uint256);
    function getDistributionCursor(string calldata serieId) external view returns (uint256 cursor, bool seriesMode);
    function getInvestorsCount(string calldata serieId) external view returns (uint256 count, bool seriesMode);

    /**
     * @notice PR4: Retorna o cursor atual de AMORTIZAÇÃO (global ou por série)
     * @dev Cursor separado do cursor de distribuição de yield.
     */
    function getAmortizationCursor(string calldata serieId) external view returns (uint256 cursor, bool seriesMode);

    /**
     * @notice PR4: Retorna o plano de amortização ativo (global ou por série)
     * @dev `periodEnd == 0` significa que não há ciclo ativo.
     */
    function getAmortizationPlan(string calldata serieId)
        external
        view
        returns (
            uint64 periodEnd,
            uint256 baseSeniorVNAWad,
            uint256 baseMezzVNAWad,
            uint256 baseJuniorVNAWad,
            uint256 planSeniorWad,
            uint256 planMezzWad,
            uint256 planJuniorWad,
            uint256 distSeniorWad,
            uint256 distMezzWad,
            uint256 distJuniorWad,
            bool seriesMode
        );

    /**
     * @notice PR4: Simula amortização (principal) em batch com periodEnd fixo (TOTALS ONLY)
     * @dev Coerente com a execução do PR3 (plano ativo vs plano novo).
     */
    function calculateAmortizationBatchAt(
        string calldata serieId,
        uint256 batchPercentBPS,
        uint256 startIndex,
        uint256 maxAmortizationNative,
        uint64 periodEnd
    )
        external
        view
        returns (
            uint256 baseSeniorVNAWad,
            uint256 baseMezzVNAWad,
            uint256 baseJuniorVNAWad,
            uint256 planSeniorWad,
            uint256 planMezzWad,
            uint256 planJuniorWad,
            uint256 batchSeniorAmortWad,
            uint256 batchMezzAmortWad,
            uint256 batchJuniorAmortWad,
            uint256 processedInvestors,
            uint256 nextStartIndex,
            bool wouldWrap,
            bool fullAmortization,
            bool seriesMode
        );
    function updateAssetPrice(uint256 newPrice) external;

    /* ═══════════════════════════════ EVENTS ATUALIZADOS ═══════════════════════════════ */
    event FIDCCreated(uint256 indexed id, address manager, address token);
    event FIDCUpdated(
        uint256 indexed id,
        address manager,
        uint32 fee,
        uint32 yield,
        uint32 grace,
        uint32 spread,
        uint32 mezzSpread,
        uint16 collateralRatio,
        uint256 maxQuotas
    );
    event Invested(address indexed investor, string purchaseId, uint256 value, uint256 tokens, uint256 fidcId);
    event Anticipated(uint256 indexed id, address indexed pj, uint256 amount, address collateral, uint256 required);
    event AnticipatedWithRatio(
        uint256 indexed id,
        address indexed pj,
        uint256 amount,
        address collateral,
        uint256 required,
        uint16 collateralRatio
    );

    // Detailed metrics (compat event – does not replace Compensated)
    event CompensatedStats(
        uint256 indexed id,
        address indexed debtor,
        uint256 amountWad,
        uint256 principalPaidWad,
        uint256 exposureBeforeWad,
        uint256 exposureAfterWad,
        uint256 totalBurnedWad
    );

    // Emitted per collateral burned (internal receivable or external token)
    event CollateralBurned(
        uint256 indexed id, address indexed debtor, address collateralToken, uint256 burnedWad, uint256 burnedNative
    );

    /**
     * @notice Evento detalhado de compensação com distinção entre dívida e juros
     * @dev Evidencia claramente o que foi pago como dívida (relacionado ao colateral) vs juros
     * @param id ID do FIDC
     * @param debtor Endereço do devedor
     * @param debtPaidWad Valor pago como dívida (relacionado ao colateral) em WAD
     * @param interestPaidWad Valor pago como juros (excesso sobre a dívida) em WAD
     * @param principalPaidWad Principal quitado (redução do exposure) em WAD
     * @param exposureBeforeWad Exposure antes da compensação em WAD
     * @param exposureAfterWad Exposure após a compensação em WAD
     * @param collateralBurnedWad Colateral queimado (proporcional apenas à dívida) em WAD
     * @param debtFullyPaid Se a dívida foi totalmente quitada
     */
    event CompensatedWithInterest(
        uint256 indexed id,
        address indexed debtor,
        uint256 debtPaidWad,
        uint256 interestPaidWad,
        uint256 principalPaidWad,
        uint256 exposureBeforeWad,
        uint256 exposureAfterWad,
        uint256 collateralBurnedWad,
        bool debtFullyPaid
    );

    event WithdrawnWithYield(
        address indexed investor, uint256 amount, uint256 yieldBPS, uint8 classId, uint256 indexed fidcId
    );

    /* ═══════════════════════════════ SERIES EVENTS (FASE 4) ═══════════════════════════════ */
    /**
     * @notice Evento emitido quando uma série atinge um milestone de preenchimento
     * @param serieId ID da série
     * @param percentageBPS Percentual atingido em basis points (2500 = 25%, 5000 = 50%, etc)
     * @dev ✅ FASE 4: Evento para milestones de captação (25%, 50%, 75%)
     */
    event SeriesMilestoneReached(string indexed serieId, uint256 percentageBPS);

    /**
     * @notice Evento emitido quando uma série atinge 100% de preenchimento (maxQuotas)
     * @param serieId ID da série
     * @dev ✅ FASE 4: Evento quando série está completa
     */
    event SeriesComplete(string indexed serieId);

    /* ═══════════════════════════════ EVENTOS COMPACTOS ═══════════════════════════════ */
    event Created(uint256 indexed id);
    event Updated(uint256 indexed id);
    // Compact aliases (non-conflicting)
    event Anticipated(uint256 indexed id, address pj, uint256 amount);
    event Compensated(uint256 indexed id, address pj, uint256 amount);
    event FeeCollected(uint256 indexed id, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Whitelisted(address indexed addr, bool whitelisted);
}
