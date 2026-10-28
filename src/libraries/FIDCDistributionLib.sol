// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFIDC_Optimized} from "../interface/IFIDC_Optimized.sol";
import {YieldCalculator} from "./YieldCalculator.sol";
import {FIDCErrors} from "./FIDCErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title FIDCDistributionLib
 * @author @Afonsodalvi — mobiup
 * @notice Specialized library for distributions and calculations with different decimals
 */
library FIDCDistributionLib {
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════ EVENTS ═══════════════════════════════ */

    event DistributedWithYields(
        uint256 indexed fidcId,
        uint256 seniorDistWad,
        uint256 mezzDistWad,
        uint256 juniorDistWad,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        bool fullPayment
    );

    event DistributedWithYieldsBatch(
        uint256 indexed fidcId,
        uint256 seniorDistWad,
        uint256 mezzDistWad,
        uint256 juniorDistWad,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        bool fullPayment,
        uint256 startIndex,
        uint256 endIndex,
        uint256 processedInvestors
    );

    /* ═══════════════════════════════ STRUCTS ═══════════════════════════════ */
    struct EmergencyDistributionParams {
        address investor;
        uint256 yieldBPS;
        uint256 managerFeeBPS;
        bool feeOnProfit;
        address manager;
        uint256 fidcId;
    }

    struct DebtorInfo {
        uint256 exposure; // total principal (WAD)
        uint256 dueWad; // sum(amount * ratio / 100) (WAD) - total due considering ratios
        uint256 internalReceivableLocked;
        address[] collateralTokens;
        mapping(address => uint256) lockedByTokenWad;
    }

    struct InvestorData {
        uint256 totalInvested;
        uint256[3] classInvested;
        bool hasPositions;
    }

    struct GrossPaid {
        uint256 sPaidIntG;
        uint256 sPaidAmortG;
        uint256 mPaidIntG;
        uint256 mPaidAmortG;
        uint256 jPaidIntG;
        uint256 jPaidAmortG;
        bool fullPayment;
    }

    /**
     * @notice Calculates gross amounts paid for each class (helper to reduce stack)
     */
    function _calcGrossPaid(
        uint256 availableWad,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 juniorVNA,
        uint256 sInt,
        uint256 mInt,
        uint256 jInt
    ) private pure returns (GrossPaid memory g) {
        uint256 b = availableWad;
        uint256 x;

        x = b >= sInt ? sInt : b;
        g.sPaidIntG = x;
        b = b > sInt ? b - sInt : 0;

        x = b >= seniorVNA ? seniorVNA : b;
        g.sPaidAmortG = x;
        b = b > seniorVNA ? b - seniorVNA : 0;

        x = b >= mInt ? mInt : b;
        g.mPaidIntG = x;
        b = b > mInt ? b - mInt : 0;

        x = b >= mezzVNA ? mezzVNA : b;
        g.mPaidAmortG = x;
        b = b > mezzVNA ? b - mezzVNA : 0;

        x = b >= jInt ? jInt : b;
        g.jPaidIntG = x;
        b = b > jInt ? b - jInt : 0;

        g.jPaidAmortG = b >= juniorVNA ? juniorVNA : b;

        g.fullPayment = (g.sPaidIntG + g.sPaidAmortG == seniorVNA + sInt)
            && (g.mPaidIntG + g.mPaidAmortG == mezzVNA + mInt) && (g.jPaidIntG + g.jPaidAmortG == juniorVNA + jInt);
    }

    /**
     * @notice Estrutura para informações de distribuição por investidor
     */
    struct InvestorDistributionInfo {
        address investor; // Endereço do investidor
        uint8 classId; // Classe do investidor (0=Senior, 1=Mezzanine, 2=Junior)
        uint256 vnaWad; // VNA do investidor na série/classe (WAD)
        uint256 percentageBPS; // Percentual do investidor na classe (BPS, 10000 = 100%)
        uint256 expectedInterestWad; // Juros esperados (WAD)
        uint256 distributionWad; // Distribuição total (juros + amortização) (WAD)
        uint256 interestWad; // Parte de juros na distribuição (WAD)
        uint256 amortizationWad; // Parte de amortização na distribuição (WAD)
    }

    /**
     * @notice Estrutura de retorno da simulação de distribuição
     */
    struct DistributionSimulation {
        uint256 totalSeniorVNAWad; // VNA total Senior na série/batch (WAD)
        uint256 totalMezzVNAWad; // VNA total Mezzanine na série/batch (WAD)
        uint256 totalJuniorVNAWad; // VNA total Junior na série/batch (WAD)
        uint256 totalSeniorDistWad; // Distribuição total Senior (WAD)
        uint256 totalMezzDistWad; // Distribuição total Mezzanine (WAD)
        uint256 totalJuniorDistWad; // Distribuição total Junior (WAD)
        uint256 processedInvestors; // Número de investidores processados
        uint256 nextStartIndex; // Próximo índice para continuar distribuição
        bool fullPayment; // Se todos os juros foram pagos
        bool seriesMode; // Se está em modo série
        InvestorDistributionInfo[] investors; // Informações detalhadas por investidor
    }

    /**
     * @notice Struct para distribuições calculadas (reduz stack)
     */
    struct CalculatedDistributions {
        uint256 sPaidInt;
        uint256 sPaidAmort;
        uint256 mPaidInt;
        uint256 mPaidAmort;
        uint256 jPaidInt;
        uint256 jPaidAmort;
        bool fullPayment;
    }

    /**
     * @notice Struct para reduzir stack depth na simulação
     */
    struct SimulationParams {
        uint256 seniorVNA;
        uint256 mezzVNA;
        uint256 juniorVNA;
        uint256 batchSeniorVNA;
        uint256 batchMezzVNA;
        uint256 batchJuniorVNA;
        uint256 endIndex;
    }

    /**
     * @notice Struct para armazenar juros proporcionais calculados (reduz stack)
     */
    struct ProportionalInterests {
        uint256 seniorInt;
        uint256 mezzInt;
        uint256 juniorInt;
    }

    /**
     * @notice Struct para armazenar yields BPS (reduz stack depth)
     */
    struct YieldsBPS {
        uint256 seniorBPS;
        uint256 mezzBPS;
        uint256 juniorBPS;
    }

    /**
     * @notice Struct para parâmetros de simulação proporcional (reduz stack depth)
     */
    struct ProportionalSimulationParams {
        address[] investors;
        uint256 seniorYieldBPS;
        uint256 mezzYieldBPS;
        uint256 juniorYieldBPS;
        uint256 currentTime;
        string serieId;
        bool noSeries;
    }

    /**
     * @notice Struct para resultados de simulação proporcional (reduz stack depth)
     */
    struct ProportionalSimulationResult {
        uint256 totalSeniorYield;
        uint256 totalMezzYield;
        uint256 totalJuniorYield;
        uint256 totalSeniorVNA;
        uint256 totalMezzVNA;
        uint256 totalJuniorVNA;
    }

    /* ═══════════════════════════════ YIELD DISTRIBUTION ═══════════════════════════════ */

    /**
     * @notice Distributes yields with custom yields for each class
     */
    function distributeWithYields(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        mapping(string => address[]) storage seriesInvestors,
        IFIDC_Optimized.CompactFIDC storage fidc,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 myFIDCId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS
    )
        internal
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 newSeniorVNA,
            uint256 newMezzVNA
        )
    {
        uint8 dec = IERC20Metadata(address(stable)).decimals();
        uint256 availableWad = YieldCalculator.scaleToWad(stable.balanceOf(address(this)), dec);
        if (availableWad == 0) revert FIDCErrors.InsufficientLiquidity();

        uint256 seniorPlusMezz = seniorVNA + mezzVNA;
        uint256 juniorVNA = fidc.invested > seniorPlusMezz ? fidc.invested - seniorPlusMezz : 0;

        uint256 sInt = (seniorVNA * seniorYieldBPS) / YieldCalculator.PRECISION;
        uint256 mInt = (mezzVNA * mezzYieldBPS) / YieldCalculator.PRECISION;
        uint256 jInt = (juniorVNA * juniorYieldBPS) / YieldCalculator.PRECISION;

        uint256 seniorTarget = seniorVNA + sInt;
        uint256 mezzTarget = mezzVNA + mInt;
        uint256 juniorTarget = juniorVNA + jInt;

        uint256 bucket = availableWad;

        // 1) Sênior
        uint256 sPaidIntGross = bucket >= sInt ? sInt : bucket;
        uint256 sPlatFee = (sPaidIntGross * fidc.feePlatform) / YieldCalculator.PRECISION;
        uint256 sPaidInt = sPaidIntGross - sPlatFee;
        bucket -= sPaidIntGross;
        if (sPlatFee > 0 && fidc.walletPlatform != address(0)) {
            uint256 sPlatFeeNative = YieldCalculator.scaleFromWad(sPlatFee, dec);
            if (sPlatFeeNative > 0) stable.safeTransfer(fidc.walletPlatform, sPlatFeeNative);
        }
        if (sPaidInt > 0) _distributeInterestToClass(stable, investors, positions, 0, sPaidInt, seniorVNA, dec);
        uint256 sPaidAmort = bucket >= seniorVNA ? seniorVNA : bucket;
        bucket -= sPaidAmort;
        if (sPaidAmort > 0) {
            _amortizeClass(stable, investors, positions, 0, sPaidAmort, seniorVNA, dec);
            // Proteção contra underflow - garantir que fidc.invested >= sPaidAmort
            if (uint256(fidc.invested) >= sPaidAmort) {
                fidc.invested -= uint128(sPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }
        seniorDistWad = sPaidInt + sPaidAmort;
        uint256 seniorDistGrossWad = sPaidIntGross + sPaidAmort;

        uint256 updatedSeniorVNA = seniorVNA > sPaidAmort ? (seniorVNA - sPaidAmort) : 0;
        uint256 updatedJuniorVNA =
            fidc.invested > (updatedSeniorVNA + mezzVNA) ? fidc.invested - updatedSeniorVNA - mezzVNA : 0;

        // 2) Mezzanine
        uint256 mPaidIntGross = bucket >= mInt ? mInt : bucket;
        uint256 mPlatFee = (mPaidIntGross * fidc.feePlatform) / YieldCalculator.PRECISION;
        uint256 mPaidInt = mPaidIntGross - mPlatFee;
        bucket -= mPaidIntGross;
        if (mPlatFee > 0 && fidc.walletPlatform != address(0)) {
            uint256 mPlatFeeNative = YieldCalculator.scaleFromWad(mPlatFee, dec);
            if (mPlatFeeNative > 0) stable.safeTransfer(fidc.walletPlatform, mPlatFeeNative);
        }
        if (mPaidInt > 0) _distributeInterestToClass(stable, investors, positions, 1, mPaidInt, mezzVNA, dec);
        uint256 mPaidAmort = bucket >= mezzVNA ? mezzVNA : bucket;
        bucket -= mPaidAmort;
        if (mPaidAmort > 0) {
            _amortizeClass(stable, investors, positions, 1, mPaidAmort, mezzVNA, dec);
            // Proteção contra underflow - garantir que fidc.invested >= mPaidAmort
            if (uint256(fidc.invested) >= mPaidAmort) {
                fidc.invested -= uint128(mPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }
        mezzDistWad = mPaidInt + mPaidAmort;
        uint256 mezzDistGrossWad = mPaidIntGross + mPaidAmort;

        uint256 updatedMezzVNA = mezzVNA > mPaidAmort ? (mezzVNA - mPaidAmort) : 0;
        updatedJuniorVNA =
            fidc.invested > (updatedSeniorVNA + updatedMezzVNA) ? fidc.invested - updatedSeniorVNA - updatedMezzVNA : 0;

        // 3) Junior
        uint256 jPaidIntGross = bucket >= jInt ? jInt : bucket;
        uint256 jPlatFee = (jPaidIntGross * fidc.feePlatform) / YieldCalculator.PRECISION;
        uint256 jPaidInt = jPaidIntGross - jPlatFee;
        bucket -= jPaidIntGross;
        if (jPlatFee > 0 && fidc.walletPlatform != address(0)) {
            uint256 jPlatFeeNative = YieldCalculator.scaleFromWad(jPlatFee, dec);
            if (jPlatFeeNative > 0) stable.safeTransfer(fidc.walletPlatform, jPlatFeeNative);
        }
        if (jPaidInt > 0) _distributeInterestToClass(stable, investors, positions, 2, jPaidInt, updatedJuniorVNA, dec);
        uint256 jPaidAmort = bucket >= updatedJuniorVNA ? updatedJuniorVNA : bucket;
        bucket -= jPaidAmort;
        if (jPaidAmort > 0) {
            _amortizeClass(stable, investors, positions, 2, jPaidAmort, updatedJuniorVNA, dec);
            // Proteção contra underflow - garantir que fidc.invested >= jPaidAmort
            if (uint256(fidc.invested) >= jPaidAmort) {
                fidc.invested -= uint128(jPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }
        juniorDistWad = jPaidInt + jPaidAmort;
        uint256 juniorDistGrossWad = jPaidIntGross + jPaidAmort;

        fullPayment = (seniorDistGrossWad == seniorTarget) && (mezzDistGrossWad == mezzTarget)
            && (juniorDistGrossWad == juniorTarget);

        newSeniorVNA = updatedSeniorVNA;
        newMezzVNA = updatedMezzVNA;

        emit DistributedWithYields(
            myFIDCId,
            seniorDistWad,
            mezzDistWad,
            juniorDistWad,
            seniorYieldBPS,
            mezzYieldBPS,
            juniorYieldBPS,
            fullPayment
        );
    }

    /*════════════════════════════  CALCULATION (view)  ═══════════════════════════*/

    /**
     * @notice Calculates yield distribution without execution
     */
    function calculateDistributionWithYields(
        IERC20 stable,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 totalVNA,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS
    )
        internal
        view
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 remainingWad
        )
    {
        uint8 dec = IERC20Metadata(address(stable)).decimals();
        uint256 availableWad = YieldCalculator.scaleToWad(stable.balanceOf(address(this)), dec);

        uint256 juniorVNA = totalVNA - seniorVNA - mezzVNA;

        uint256 sInt = (seniorVNA * seniorYieldBPS) / YieldCalculator.PRECISION;
        uint256 mInt = (mezzVNA * mezzYieldBPS) / YieldCalculator.PRECISION;
        uint256 jInt = (juniorVNA * juniorYieldBPS) / YieldCalculator.PRECISION;

        uint256 seniorTarget = seniorVNA + sInt;
        uint256 mezzTarget = mezzVNA + mInt;
        uint256 juniorTarget = juniorVNA + jInt;

        uint256 bucket = availableWad;

        seniorDistWad = bucket >= seniorTarget ? seniorTarget : bucket;
        bucket -= seniorDistWad;
        mezzDistWad = bucket >= mezzTarget ? mezzTarget : bucket;
        bucket -= mezzDistWad;
        juniorDistWad = bucket >= juniorTarget ? juniorTarget : bucket;
        bucket -= juniorDistWad;

        fullPayment = (seniorDistWad == seniorTarget) && (mezzDistWad == mezzTarget) && (juniorDistWad == juniorTarget);
        remainingWad = bucket;
    }

    /*════════════════════════════  CVM 175 STANDARD DISTRIBUTION  ══════════════════════*/

    /* ═══════════════════════════════ TOKEN COMPATIBILITY ═══════════════════════════════ */

    function scaleToWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return YieldCalculator.scaleToWad(amount, decimals);
    }

    function scaleFromWad(uint256 wadAmount, uint8 decimals) internal pure returns (uint256) {
        return YieldCalculator.scaleFromWad(wadAmount, decimals);
    }

    function convertBetweenTokenDecimals(address fromToken, address toToken, uint256 amount)
        internal
        view
        returns (uint256 convertedAmount)
    {
        uint8 fromDecimals = IERC20Metadata(fromToken).decimals();
        uint8 toDecimals = IERC20Metadata(toToken).decimals();

        if (fromDecimals == toDecimals) {
            return amount;
        }

        uint256 wadAmount = YieldCalculator.scaleToWad(amount, fromDecimals);
        convertedAmount = YieldCalculator.scaleFromWad(wadAmount, toDecimals);
    }

    function normalizeTokenAmount(address token, uint256 amount) internal view returns (uint256 normalizedAmount) {
        uint8 decimals = IERC20Metadata(token).decimals();
        normalizedAmount = YieldCalculator.scaleToWad(amount, decimals);
    }

    function denormalizeTokenAmount(address token, uint256 wadAmount) internal view returns (uint256 nativeAmount) {
        uint8 decimals = IERC20Metadata(token).decimals();
        nativeAmount = YieldCalculator.scaleFromWad(wadAmount, decimals);
    }

    function safeTransferWithDecimals(address token, address to, uint256 amount) internal {
        uint8 decimals = IERC20Metadata(token).decimals();
        uint256 nativeAmount = YieldCalculator.scaleFromWad(amount, decimals);
        IERC20(token).safeTransfer(to, nativeAmount);
    }

    function _distributeToClass(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint8 classId,
        uint256 totalAmountWad,
        uint256 totalClassInvWad,
        uint8 tokenDec
    ) private {
        if (totalAmountWad == 0 || totalClassInvWad == 0) return;

        int256 lastIdx = -1;
        for (uint256 i; i < investors.length; ++i) {
            IFIDC_Optimized.Investment[] storage invs = positions[investors[i]];
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == classId && invs[j].amount > 0) {
                    lastIdx = int256(i);
                }
            }
        }
        if (lastIdx < 0) return;

        uint256 distributedWad = 0;
        for (uint256 i; i < investors.length; ++i) {
            address inv = investors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investedWad = 0;
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == classId) investedWad += invs[j].amount;
            }

            if (investedWad == 0) continue;

            uint256 shareWad;
            if (int256(i) == lastIdx) {
                shareWad = totalAmountWad - distributedWad;
            } else {
                shareWad = (investedWad * totalAmountWad) / totalClassInvWad;
                distributedWad += shareWad;
            }
            uint256 shareNative = YieldCalculator.scaleFromWad(shareWad, tokenDec);
            if (shareNative > 0) stable.safeTransfer(inv, shareNative);
        }
    }

    function _distributeInterestToClass(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint8 classId,
        uint256 interestWad,
        uint256 totalClassInvWad,
        uint8 tokenDec
    ) private {
        _distributeToClass(stable, investors, positions, classId, interestWad, totalClassInvWad, tokenDec);
    }

    function _amortizeClass(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint8 classId,
        uint256 amortWad,
        uint256 totalClassInvWad,
        uint8 tokenDec
    ) private {
        if (amortWad == 0 || totalClassInvWad == 0) return;

        for (uint256 i; i < investors.length; ++i) {
            address inv = investors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investorVna = 0;
            uint256 lastIdx = type(uint256).max;
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == classId && invs[j].amount > 0) {
                    investorVna += invs[j].amount;
                    lastIdx = j;
                }
            }

            if (investorVna == 0) continue;

            uint256 investorAmortWad = Math.mulDiv(investorVna, amortWad, totalClassInvWad);
            uint256 investorAmortNative = YieldCalculator.scaleFromWad(investorAmortWad, tokenDec);
            if (investorAmortNative > 0) {
                stable.safeTransfer(inv, investorAmortNative);
            }

            if (investorAmortWad > 0) {
                uint256 reducedSum = 0;
                for (uint256 j; j < invs.length; ++j) {
                    if (invs[j].class != classId || invs[j].amount == 0) continue;
                    uint256 posShare;
                    if (j == lastIdx) {
                        posShare = investorAmortWad - reducedSum;
                    } else {
                        posShare = Math.mulDiv(invs[j].amount, investorAmortWad, investorVna);
                        reducedSum += posShare;
                    }
                    if (posShare > invs[j].amount) posShare = invs[j].amount;
                    invs[j].amount = uint128(invs[j].amount - posShare);
                }
            }
        }
    }

    function calculateProportionalYield(
        IFIDC_Optimized.Investment memory investment,
        uint256 yieldBPS,
        uint256 currentTime
    ) internal pure returns (uint256 proportionalYield) {
        if (currentTime <= investment.yieldStart) {
            return 0;
        }

        uint256 timeElapsed = currentTime - investment.yieldStart;
        uint256 annualSeconds = 365 days;

        proportionalYield = (investment.amount * yieldBPS * timeElapsed) / (10000 * annualSeconds);
    }

    /* ═══════════════════ PROPORTIONAL YIELD DISTRIBUTION ═══════════════════ */

    /**
     * @notice Calcula o yield proporcional ao tempo para todas as posições de um investidor
     * @param positions Array de posições do investidor
     * @param yieldBPS Taxa de yield anual em BPS (ex: 1000 = 10%)
     * @param currentTime Timestamp atual para cálculo
     * @return totalProportionalYield Soma dos yields proporcionais de todas as posições
     */
    function calculateInvestorProportionalYield(
        IFIDC_Optimized.Investment[] memory positions,
        uint256 yieldBPS,
        uint256 currentTime
    ) internal pure returns (uint256 totalProportionalYield) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amount > 0) {
                totalProportionalYield += calculateProportionalYield(positions[i], yieldBPS, currentTime);
            }
        }
    }

    /**
     * @notice Calcula o yield proporcional ao tempo para uma classe específica de um investidor
     * @param positions Array de posições do investidor
     * @param classId ID da classe (0=Senior, 1=Mezzanine, 2=Junior)
     * @param yieldBPS Taxa de yield anual em BPS
     * @param currentTime Timestamp atual
     * @return classProportionalYield Yield proporcional total da classe
     * @return classVNA VNA total da classe
     */
    function calculateInvestorClassProportionalYield(
        IFIDC_Optimized.Investment[] memory positions,
        uint8 classId,
        uint256 yieldBPS,
        uint256 currentTime
    ) internal pure returns (uint256 classProportionalYield, uint256 classVNA) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].class == classId && positions[i].amount > 0) {
                classProportionalYield += calculateProportionalYield(positions[i], yieldBPS, currentTime);
                classVNA += positions[i].amount;
            }
        }
    }

    /**
     * @notice Struct para armazenar informações de yield proporcional por investidor
     */
    struct ProportionalYieldInfo {
        address investor;
        uint256 seniorYield;
        uint256 mezzYield;
        uint256 juniorYield;
        uint256 seniorVNA;
        uint256 mezzVNA;
        uint256 juniorVNA;
    }

    /**
     * @notice Calcula o yield proporcional ao tempo para todos os investidores
     * @dev Função view que retorna os yields calculados por tempo decorrido
     * @param investors Lista de investidores
     * @param positions Mapping de posições por investidor
     * @param seniorYieldBPS Yield anual Senior em BPS
     * @param mezzYieldBPS Yield anual Mezzanine em BPS
     * @param juniorYieldBPS Yield anual Junior em BPS
     * @param currentTime Timestamp para cálculo (normalmente block.timestamp)
     * @return infos Array com informações de yield proporcional por investidor
     * @return totalSeniorYield Total de yield proporcional Senior
     * @return totalMezzYield Total de yield proporcional Mezzanine
     * @return totalJuniorYield Total de yield proporcional Junior
     */
    function calculateAllProportionalYields(
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 currentTime
    )
        internal
        view
        returns (
            ProportionalYieldInfo[] memory infos,
            uint256 totalSeniorYield,
            uint256 totalMezzYield,
            uint256 totalJuniorYield
        )
    {
        uint256 len = investors.length;
        infos = new ProportionalYieldInfo[](len);

        for (uint256 i = 0; i < len; i++) {
            address inv = investors[i];
            IFIDC_Optimized.Investment[] storage invPositions = positions[inv];

            infos[i].investor = inv;

            for (uint256 j = 0; j < invPositions.length; j++) {
                IFIDC_Optimized.Investment storage pos = invPositions[j];
                if (pos.amount == 0) continue;

                uint256 propYield = calculateProportionalYield(
                    pos, pos.class == 0 ? seniorYieldBPS : (pos.class == 1 ? mezzYieldBPS : juniorYieldBPS), currentTime
                );

                if (pos.class == 0) {
                    infos[i].seniorYield += propYield;
                    infos[i].seniorVNA += pos.amount;
                    totalSeniorYield += propYield;
                } else if (pos.class == 1) {
                    infos[i].mezzYield += propYield;
                    infos[i].mezzVNA += pos.amount;
                    totalMezzYield += propYield;
                } else {
                    infos[i].juniorYield += propYield;
                    infos[i].juniorVNA += pos.amount;
                    totalJuniorYield += propYield;
                }
            }
        }
    }

    /**
     * @notice Calcula yields proporcionais para SIMULAÇÃO (retorna struct única para reduzir stack)
     * @dev Função otimizada para uso no FIDCViewsFacet sem causar stack too deep
     * @param investors Lista de investidores
     * @param positions Mapping de posições
     * @param yieldsBPS Struct com yields BPS para cada classe
     * @param currentTime Timestamp para cálculo (block.timestamp)
     * @return result Struct com totais de yields e VNAs proporcionais
     */
    function calculateProportionalYieldsForSimulation(
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        YieldsBPS memory yieldsBPS,
        uint256 currentTime
    ) internal view returns (ProportionalSimulationResult memory result) {
        uint256 len = investors.length;

        for (uint256 i; i < len; ++i) {
            IFIDC_Optimized.Investment[] storage invPositions = positions[investors[i]];

            for (uint256 j; j < invPositions.length; ++j) {
                IFIDC_Optimized.Investment storage pos = invPositions[j];
                if (pos.amount == 0) continue;

                uint256 propYield = calculateProportionalYield(
                    pos,
                    pos.class == 0 ? yieldsBPS.seniorBPS : (pos.class == 1 ? yieldsBPS.mezzBPS : yieldsBPS.juniorBPS),
                    currentTime
                );

                if (pos.class == 0) {
                    result.totalSeniorYield += propYield;
                    result.totalSeniorVNA += pos.amount;
                } else if (pos.class == 1) {
                    result.totalMezzYield += propYield;
                    result.totalMezzVNA += pos.amount;
                } else {
                    result.totalJuniorYield += propYield;
                    result.totalJuniorVNA += pos.amount;
                }
            }
        }
    }

    /**
     * @notice Calcula yields proporcionais para SIMULAÇÃO com filtro de série
     * @dev Filtra posições por série antes de calcular
     * @param seriesInvestors Mapping de investidores por série
     * @param positions Mapping de posições por investidor
     * @param serieId ID da série (vazio para modo global)
     * @param yieldsBPS Struct com yields BPS para cada classe
     * @param currentTime Timestamp para cálculo
     * @return result Struct com totais de yields e VNAs proporcionais
     */
    function calculateProportionalYieldsForSimulationBySeries(
        mapping(string => address[]) storage seriesInvestors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        string memory serieId,
        YieldsBPS memory yieldsBPS,
        uint256 currentTime
    ) internal view returns (ProportionalSimulationResult memory result) {
        address[] storage investors = seriesInvestors[serieId];
        uint256 len = investors.length;
        bytes32 targetSerieHash = keccak256(bytes(serieId));

        for (uint256 i; i < len; ++i) {
            IFIDC_Optimized.Investment[] storage invPositions = positions[investors[i]];

            for (uint256 j; j < invPositions.length; ++j) {
                IFIDC_Optimized.Investment storage pos = invPositions[j];
                if (pos.amount == 0) continue;

                // Filtrar por série
                if (keccak256(bytes(pos.serieId)) != targetSerieHash) continue;

                uint256 propYield = calculateProportionalYield(
                    pos,
                    pos.class == 0 ? yieldsBPS.seniorBPS : (pos.class == 1 ? yieldsBPS.mezzBPS : yieldsBPS.juniorBPS),
                    currentTime
                );

                if (pos.class == 0) {
                    result.totalSeniorYield += propYield;
                    result.totalSeniorVNA += pos.amount;
                } else if (pos.class == 1) {
                    result.totalMezzYield += propYield;
                    result.totalMezzVNA += pos.amount;
                } else {
                    result.totalJuniorYield += propYield;
                    result.totalJuniorVNA += pos.amount;
                }
            }
        }
    }

    /**
     * @notice Distribui yields proporcionalmente ao tempo de cada posição
     * @dev IMPORTANTE: Esta função distribui juros baseados no tempo desde yieldStart
     * @dev A fórmula é: yield = (amount × yieldBPS × timeElapsed) / (10000 × 365 days)
     * @param stable Token de stablecoin
     * @param investors Lista de investidores
     * @param positions Mapping de posições
     * @param fidc Struct do FIDC
     * @param seniorYieldBPS Yield anual Senior em BPS
     * @param mezzYieldBPS Yield anual Mezzanine em BPS
     * @param juniorYieldBPS Yield anual Junior em BPS
     * @return seniorDistWad Total distribuído para Senior
     * @return mezzDistWad Total distribuído para Mezzanine
     * @return juniorDistWad Total distribuído para Junior
     * @return fullPayment Se todos os yields foram pagos completamente
     */
    function distributeWithProportionalYields(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        IFIDC_Optimized.CompactFIDC storage fidc,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS
    ) internal returns (uint256 seniorDistWad, uint256 mezzDistWad, uint256 juniorDistWad, bool fullPayment) {
        uint8 dec = IERC20Metadata(address(stable)).decimals();
        uint256 availableWad = YieldCalculator.scaleToWad(stable.balanceOf(address(this)), dec);
        if (availableWad == 0) revert FIDCErrors.InsufficientLiquidity();

        uint256 currentTime = block.timestamp;
        uint256 bucket = availableWad;

        // Calcular yields proporcionais por investidor
        (
            ProportionalYieldInfo[] memory infos,
            uint256 totalSeniorYield,
            uint256 totalMezzYield,
            uint256 totalJuniorYield
        ) = calculateAllProportionalYields(
            investors, positions, seniorYieldBPS, mezzYieldBPS, juniorYieldBPS, currentTime
        );

        // Waterfall: Senior → Mezzanine → Junior

        // 1) Senior - distribuir yield proporcional
        uint256 seniorToPay = bucket >= totalSeniorYield ? totalSeniorYield : bucket;
        if (seniorToPay > 0) {
            uint256 seniorPlatFee = (seniorToPay * fidc.feePlatform) / YieldCalculator.PRECISION;
            uint256 seniorNet = seniorToPay - seniorPlatFee;

            if (seniorPlatFee > 0 && fidc.walletPlatform != address(0)) {
                uint256 seniorPlatFeeNative = YieldCalculator.scaleFromWad(seniorPlatFee, dec);
                if (seniorPlatFeeNative > 0) stable.safeTransfer(fidc.walletPlatform, seniorPlatFeeNative);
            }

            // Distribuir proporcionalmente ao yield calculado de cada investidor
            _distributeProportionalYieldToInvestors(stable, infos, 0, seniorNet, totalSeniorYield, dec);
            seniorDistWad = seniorNet;
        }
        bucket -= seniorToPay;

        // 2) Mezzanine
        uint256 mezzToPay = bucket >= totalMezzYield ? totalMezzYield : bucket;
        if (mezzToPay > 0) {
            uint256 mezzPlatFee = (mezzToPay * fidc.feePlatform) / YieldCalculator.PRECISION;
            uint256 mezzNet = mezzToPay - mezzPlatFee;

            if (mezzPlatFee > 0 && fidc.walletPlatform != address(0)) {
                uint256 mezzPlatFeeNative = YieldCalculator.scaleFromWad(mezzPlatFee, dec);
                if (mezzPlatFeeNative > 0) stable.safeTransfer(fidc.walletPlatform, mezzPlatFeeNative);
            }

            _distributeProportionalYieldToInvestors(stable, infos, 1, mezzNet, totalMezzYield, dec);
            mezzDistWad = mezzNet;
        }
        bucket -= mezzToPay;

        // 3) Junior
        uint256 juniorToPay = bucket >= totalJuniorYield ? totalJuniorYield : bucket;
        if (juniorToPay > 0) {
            uint256 juniorPlatFee = (juniorToPay * fidc.feePlatform) / YieldCalculator.PRECISION;
            uint256 juniorNet = juniorToPay - juniorPlatFee;

            if (juniorPlatFee > 0 && fidc.walletPlatform != address(0)) {
                uint256 juniorPlatFeeNative = YieldCalculator.scaleFromWad(juniorPlatFee, dec);
                if (juniorPlatFeeNative > 0) stable.safeTransfer(fidc.walletPlatform, juniorPlatFeeNative);
            }

            _distributeProportionalYieldToInvestors(stable, infos, 2, juniorNet, totalJuniorYield, dec);
            juniorDistWad = juniorNet;
        }
        bucket -= juniorToPay;

        // Full payment se todos os yields proporcionais foram pagos
        fullPayment =
            (seniorToPay == totalSeniorYield) && (mezzToPay == totalMezzYield) && (juniorToPay == totalJuniorYield);
    }

    /**
     * @notice Distribui yield proporcional para investidores de uma classe
     * @param stable Token de stablecoin
     * @param infos Array de informações de yield por investidor
     * @param classId ID da classe
     * @param totalToDistribute Total a distribuir para a classe
     * @param totalClassYield Total de yield da classe (para calcular proporção)
     * @param dec Decimais do token
     */
    function _distributeProportionalYieldToInvestors(
        IERC20 stable,
        ProportionalYieldInfo[] memory infos,
        uint8 classId,
        uint256 totalToDistribute,
        uint256 totalClassYield,
        uint8 dec
    ) private {
        if (totalToDistribute == 0 || totalClassYield == 0) return;

        uint256 distributed = 0;
        uint256 lastIdx = type(uint256).max;

        // Encontrar último investidor com yield desta classe
        for (uint256 i = 0; i < infos.length; i++) {
            uint256 invYield =
                classId == 0 ? infos[i].seniorYield : (classId == 1 ? infos[i].mezzYield : infos[i].juniorYield);
            if (invYield > 0) {
                lastIdx = i;
            }
        }

        if (lastIdx == type(uint256).max) return;

        for (uint256 i = 0; i < infos.length; i++) {
            uint256 invYield =
                classId == 0 ? infos[i].seniorYield : (classId == 1 ? infos[i].mezzYield : infos[i].juniorYield);

            if (invYield == 0) continue;

            uint256 share;
            if (i == lastIdx) {
                // Último investidor recebe o restante para evitar dust
                share = totalToDistribute - distributed;
            } else {
                // Proporção baseada no yield calculado
                share = (invYield * totalToDistribute) / totalClassYield;
                distributed += share;
            }

            uint256 shareNative = YieldCalculator.scaleFromWad(share, dec);
            if (shareNative > 0) {
                stable.safeTransfer(infos[i].investor, shareNative);
            }
        }
    }

    /**
     * @notice Evento emitido quando distribuição proporcional é executada
     */
    event DistributedWithProportionalYields(
        uint256 seniorDistWad,
        uint256 mezzDistWad,
        uint256 juniorDistWad,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        bool fullPayment,
        uint256 timestamp
    );

    /**
     * @notice Distribui yields PROPORCIONAIS ao tempo em batches (evita gas limit)
     * @dev IMPORTANTE: Yields calculados baseados no tempo desde yieldStart de CADA posição
     * @dev Fórmula: yield = (amount × yieldBPS × timeElapsed) / (10000 × 365 days)
     * @param stable Token de stablecoin
     * @param investors Lista de investidores
     * @param positions Mapping de posições
     * @param seriesInvestors Mapping de investidores por série
     * @param fidc Struct do FIDC
     * @param seniorVNA VNA Senior atual
     * @param mezzVNA VNA Mezzanine atual
     * @param fidcId ID do FIDC
     * @param serieId ID da série ("" = todas)
     * @param seniorYieldBPS Yield ANUAL Senior em BPS
     * @param mezzYieldBPS Yield ANUAL Mezzanine em BPS
     * @param juniorYieldBPS Yield ANUAL Junior em BPS
     * @param batchPercentBPS Percentual de investidores a processar (10000 = 100%)
     * @param startIndex Índice inicial
     */
    function distributeWithProportionalYieldsBatch(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        mapping(string => address[]) storage seriesInvestors,
        IFIDC_Optimized.CompactFIDC storage fidc,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 fidcId,
        string memory serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex
    )
        internal
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            uint256 processedInvestors,
            uint256 nextStartIndex
        )
    {
        return distributeWithProportionalYieldsBatchAt(
            stable,
            investors,
            positions,
            seriesInvestors,
            fidc,
            seniorVNA,
            mezzVNA,
            fidcId,
            serieId,
            seniorYieldBPS,
            mezzYieldBPS,
            juniorYieldBPS,
            batchPercentBPS,
            startIndex,
            block.timestamp
        );
    }

    /**
     * @notice Distribui yields proporcionais ao tempo em batches, usando um timestamp fixo (periodEnd/currentTime)
     * @dev PR2: permite processar o "mesmo ciclo" em várias transações sem variar o yield.
     * @param currentTime Timestamp fixo para cálculo (ex.: periodEnd)
     */
    function distributeWithProportionalYieldsBatchAt(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        mapping(string => address[]) storage seriesInvestors,
        IFIDC_Optimized.CompactFIDC storage fidc,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 fidcId,
        string memory serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex,
        uint256 currentTime
    )
        internal
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            uint256 processedInvestors,
            uint256 nextStartIndex
        )
    {
        uint8 dec = IERC20Metadata(address(stable)).decimals();
        uint256 availableWad = YieldCalculator.scaleToWad(stable.balanceOf(address(this)), dec);
        if (availableWad == 0) revert FIDCErrors.InsufficientLiquidity();

        // Determinar modo (com ou sem série)
        bytes memory serieBytes = bytes(serieId);
        bool noSeries = (serieBytes.length == 0) || (serieBytes.length == 1 && serieBytes[0] == bytes1(uint8(44)));

        // Obter lista de investidores para processar
        address[] memory targetInvestors;
        if (noSeries) {
            // Modo global: criar array de referência
            uint256 len = investors.length;
            if (startIndex >= len) {
                return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
            }
            uint256 batchSize = (len * batchPercentBPS) / YieldCalculator.PRECISION;
            if (batchPercentBPS > 0 && batchSize == 0) batchSize = 1;
            uint256 endIndex = startIndex + batchSize;
            if (endIndex > len) endIndex = len;
            processedInvestors = endIndex - startIndex;
            nextStartIndex = endIndex;

            targetInvestors = new address[](processedInvestors);
            for (uint256 i = 0; i < processedInvestors; i++) {
                targetInvestors[i] = investors[startIndex + i];
            }
        } else {
            // Modo série: usar investidores da série
            address[] storage seriesInvs = seriesInvestors[serieId];
            uint256 len = seriesInvs.length;
            if (len == 0 || startIndex >= len) {
                return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
            }
            uint256 batchSize = (len * batchPercentBPS) / YieldCalculator.PRECISION;
            if (batchPercentBPS > 0 && batchSize == 0) batchSize = 1;
            uint256 endIndex = startIndex + batchSize;
            if (endIndex > len) endIndex = len;
            processedInvestors = endIndex - startIndex;
            nextStartIndex = endIndex;

            targetInvestors = new address[](processedInvestors);
            for (uint256 i = 0; i < processedInvestors; i++) {
                targetInvestors[i] = seriesInvs[startIndex + i];
            }
        }

        // Calcular yields proporcionais para o batch (usa currentTime fixo)
        ProportionalYieldInfo[] memory batchInfos = new ProportionalYieldInfo[](processedInvestors);
        uint256 totalSeniorYield = 0;
        uint256 totalMezzYield = 0;
        uint256 totalJuniorYield = 0;

        for (uint256 i = 0; i < processedInvestors; i++) {
            address inv = targetInvestors[i];
            IFIDC_Optimized.Investment[] storage invPositions = positions[inv];

            batchInfos[i].investor = inv;

            for (uint256 j = 0; j < invPositions.length; j++) {
                IFIDC_Optimized.Investment storage pos = invPositions[j];
                if (pos.amount == 0) continue;

                // Filtrar por série se necessário
                if (!noSeries) {
                    bytes32 posSerieHash = keccak256(bytes(pos.serieId));
                    bytes32 targetSerieHash = keccak256(serieBytes);
                    if (posSerieHash != targetSerieHash) continue;
                }

                uint256 propYield = calculateProportionalYield(
                    pos, pos.class == 0 ? seniorYieldBPS : (pos.class == 1 ? mezzYieldBPS : juniorYieldBPS), currentTime
                );

                if (pos.class == 0) {
                    batchInfos[i].seniorYield += propYield;
                    batchInfos[i].seniorVNA += pos.amount;
                    totalSeniorYield += propYield;
                } else if (pos.class == 1) {
                    batchInfos[i].mezzYield += propYield;
                    batchInfos[i].mezzVNA += pos.amount;
                    totalMezzYield += propYield;
                } else {
                    batchInfos[i].juniorYield += propYield;
                    batchInfos[i].juniorVNA += pos.amount;
                    totalJuniorYield += propYield;
                }
            }
        }

        // Waterfall: Senior → Mezzanine → Junior
        uint256 bucket = availableWad;
        newSeniorVNA = seniorVNA;
        newMezzVNA = mezzVNA;

        // 1) Senior
        uint256 seniorToPay = bucket >= totalSeniorYield ? totalSeniorYield : bucket;
        if (seniorToPay > 0) {
            uint256 seniorPlatFee = (seniorToPay * fidc.feePlatform) / YieldCalculator.PRECISION;
            uint256 seniorNet = seniorToPay - seniorPlatFee;

            if (seniorPlatFee > 0 && fidc.walletPlatform != address(0)) {
                uint256 feeNative = YieldCalculator.scaleFromWad(seniorPlatFee, dec);
                if (feeNative > 0) stable.safeTransfer(fidc.walletPlatform, feeNative);
            }

            _distributeProportionalYieldToInvestors(stable, batchInfos, 0, seniorNet, totalSeniorYield, dec);
            seniorDistWad = seniorNet;
        }
        bucket -= seniorToPay;

        // 2) Mezzanine
        uint256 mezzToPay = bucket >= totalMezzYield ? totalMezzYield : bucket;
        if (mezzToPay > 0) {
            uint256 mezzPlatFee = (mezzToPay * fidc.feePlatform) / YieldCalculator.PRECISION;
            uint256 mezzNet = mezzToPay - mezzPlatFee;

            if (mezzPlatFee > 0 && fidc.walletPlatform != address(0)) {
                uint256 feeNative = YieldCalculator.scaleFromWad(mezzPlatFee, dec);
                if (feeNative > 0) stable.safeTransfer(fidc.walletPlatform, feeNative);
            }

            _distributeProportionalYieldToInvestors(stable, batchInfos, 1, mezzNet, totalMezzYield, dec);
            mezzDistWad = mezzNet;
        }
        bucket -= mezzToPay;

        // 3) Junior
        uint256 juniorToPay = bucket >= totalJuniorYield ? totalJuniorYield : bucket;
        if (juniorToPay > 0) {
            uint256 juniorPlatFee = (juniorToPay * fidc.feePlatform) / YieldCalculator.PRECISION;
            uint256 juniorNet = juniorToPay - juniorPlatFee;

            if (juniorPlatFee > 0 && fidc.walletPlatform != address(0)) {
                uint256 feeNative = YieldCalculator.scaleFromWad(juniorPlatFee, dec);
                if (feeNative > 0) stable.safeTransfer(fidc.walletPlatform, feeNative);
            }

            _distributeProportionalYieldToInvestors(stable, batchInfos, 2, juniorNet, totalJuniorYield, dec);
            juniorDistWad = juniorNet;
        }

        // Full payment se todos os yields foram pagos
        fullPayment =
            (seniorToPay == totalSeniorYield) && (mezzToPay == totalMezzYield) && (juniorToPay == totalJuniorYield);

        // ✅ PR1 (Bug 2 fix): avançar yieldStart proporcionalmente ao pago
        // Se o caixa é insuficiente, NÃO podemos resetar yieldStart para currentTime, senão o yield devido não pago "some".
        // Em vez disso, avançamos o yieldStart por uma fração do tempo decorrido:
        // newYieldStart = yieldStart + (currentTime - yieldStart) * (paidClassYield / totalClassYield)
        // - paidClassYield é o valor GROSS pago (antes da fee), pois o período "liquidado" inclui a parcela de fee.
        // - Se paidClassYield == 0 => não avança (mantém accrual).
        // - Se paidClassYield == totalClassYield => vira reset completo para currentTime.
        uint256 ratioSeniorWad = totalSeniorYield == 0 ? 0 : (seniorToPay * 1e18) / totalSeniorYield;
        uint256 ratioMezzWad = totalMezzYield == 0 ? 0 : (mezzToPay * 1e18) / totalMezzYield;
        uint256 ratioJuniorWad = totalJuniorYield == 0 ? 0 : (juniorToPay * 1e18) / totalJuniorYield;

        // Atualizar yieldStart das posições após distribuição
        for (uint256 i = 0; i < processedInvestors; i++) {
            address inv = targetInvestors[i];
            IFIDC_Optimized.Investment[] storage invPositions = positions[inv];
            for (uint256 j = 0; j < invPositions.length; j++) {
                if (invPositions[j].amount > 0) {
                    // Filtrar por série se necessário
                    if (!noSeries) {
                        bytes32 posSerieHash = keccak256(bytes(invPositions[j].serieId));
                        bytes32 targetSerieHash = keccak256(serieBytes);
                        if (posSerieHash != targetSerieHash) continue;
                    }

                    // Avançar yieldStart proporcionalmente ao pago na classe
                    // (mantém o "saldo" de tempo/yield não pago para a próxima distribuição)
                    if (currentTime <= invPositions[j].yieldStart) continue;

                    uint256 ratioWad = invPositions[j].class == 0
                        ? ratioSeniorWad
                        : (invPositions[j].class == 1 ? ratioMezzWad : ratioJuniorWad);

                    if (ratioWad == 0) continue;

                    uint256 elapsed = currentTime - invPositions[j].yieldStart;
                    uint256 advance = Math.mulDiv(elapsed, ratioWad, 1e18);
                    uint256 newStart = uint256(invPositions[j].yieldStart) + advance;
                    if (newStart > currentTime) newStart = currentTime;
                    if (newStart > type(uint64).max) newStart = type(uint64).max;
                    invPositions[j].yieldStart = uint64(newStart);
                }
            }
        }

        emit DistributedWithYieldsBatch(
            fidcId,
            seniorDistWad,
            mezzDistWad,
            juniorDistWad,
            seniorYieldBPS,
            mezzYieldBPS,
            juniorYieldBPS,
            fullPayment,
            startIndex,
            nextStartIndex,
            processedInvestors
        );
    }

    function _distributeToClassBatch(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint8 classId,
        uint256 totalAmountWad,
        uint256 totalClassInvWad,
        uint8 tokenDec,
        uint256 startIndex,
        uint256 endIndex
    ) private {
        if (totalAmountWad == 0 || totalClassInvWad == 0) return;

        uint256 distributedWad = 0;
        int256 lastIdx = -1;

        for (uint256 i = startIndex; i < endIndex; ++i) {
            address invAddr = investors[i];
            IFIDC_Optimized.Investment[] storage invps = positions[invAddr];
            for (uint256 j; j < invps.length; ++j) {
                if (invps[j].class == classId && invps[j].amount > 0) {
                    lastIdx = int256(i);
                }
            }
        }
        if (lastIdx < 0) return;

        for (uint256 i = startIndex; i < endIndex; ++i) {
            address inv = investors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investedWad = 0;
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == classId) investedWad += invs[j].amount;
            }

            if (investedWad == 0) continue;

            uint256 shareWad;
            if (int256(i) == lastIdx) {
                shareWad = totalAmountWad - distributedWad;
            } else {
                shareWad = (investedWad * totalAmountWad) / totalClassInvWad;
                distributedWad += shareWad;
            }
            uint256 shareNative = YieldCalculator.scaleFromWad(shareWad, tokenDec);
            if (shareNative > 0) stable.safeTransfer(inv, shareNative);
        }
    }

    function _amortizeClassBatch(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint8 classId,
        uint256 amortWad,
        uint256 totalClassInvWad,
        uint8 tokenDec,
        uint256 startIndex,
        uint256 endIndex
    ) private {
        if (amortWad == 0 || totalClassInvWad == 0) return;

        // Find last investor with VNA in this class (to allocate dust)
        int256 lastI = -1;
        for (uint256 i = startIndex; i < endIndex; ++i) {
            address inv = investors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == classId && invs[j].amount > 0) {
                    lastI = int256(i);
                }
            }
        }
        if (lastI < 0) return;

        uint256 distributedWad = 0;
        for (uint256 i = startIndex; i < endIndex; ++i) {
            address inv = investors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investorVna = 0;
            uint256 lastIdx = type(uint256).max;
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == classId && invs[j].amount > 0) {
                    investorVna += invs[j].amount;
                    lastIdx = j;
                }
            }

            if (investorVna == 0) continue;

            uint256 investorAmortWad;
            if (int256(i) == lastI) {
                investorAmortWad = amortWad - distributedWad;
            } else {
                investorAmortWad = Math.mulDiv(investorVna, amortWad, totalClassInvWad);
                distributedWad += investorAmortWad;
            }
            uint256 investorAmortNative = YieldCalculator.scaleFromWad(investorAmortWad, tokenDec);
            if (investorAmortNative > 0) {
                stable.safeTransfer(inv, investorAmortNative);
            }

            if (investorAmortWad > 0) {
                uint256 reducedSum = 0;
                for (uint256 j; j < invs.length; ++j) {
                    if (invs[j].class != classId || invs[j].amount == 0) continue;
                    uint256 posShare;
                    if (j == lastIdx) {
                        posShare = investorAmortWad - reducedSum;
                    } else {
                        posShare = Math.mulDiv(invs[j].amount, investorAmortWad, investorVna);
                        reducedSum += posShare;
                    }
                    if (posShare > invs[j].amount) posShare = invs[j].amount;
                    invs[j].amount = uint128(invs[j].amount - posShare);
                }
            }
        }
    }

    function checkTokenCompatibility(address token) internal view returns (bool isCompatible, uint8 decimals) {
        try IERC20Metadata(token).decimals() returns (uint8 _decimals) {
            return (true, _decimals);
        } catch {
            return (false, 0);
        }
    }

    /**
     * @notice Distributes yields in batches (avoids gas limit) - UNIFIED
     * @param batchPercentBPS Percentage of investors to process (0-10000, where 10000 = 100%)
     * @param startIndex Starting index to begin distribution
     * @param serieId Series ID ("" or "," = no series, processes all; otherwise filters by series)
     * @param seriesInvestors Mapping of series to investors (can be empty if serieId == "")
     */
    function distributeWithYieldsBatch(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        mapping(string => address[]) storage seriesInvestors,
        IFIDC_Optimized.CompactFIDC storage fidc,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 fidcId,
        string memory serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex
    )
        internal
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            uint256 processedInvestors,
            uint256 nextStartIndex
        )
    {
        uint8 dec = IERC20Metadata(address(stable)).decimals();
        uint256 availableWad = YieldCalculator.scaleToWad(stable.balanceOf(address(this)), dec);
        if (availableWad == 0) revert FIDCErrors.InsufficientLiquidity();

        // Check if no series mode (serieId empty or ",")
        bytes memory serieBytes = bytes(serieId);
        bool noSeries = (serieBytes.length == 0) || (serieBytes.length == 1 && serieBytes[0] == bytes1(uint8(44))); // ',' == 44

        uint256 seniorPlusMezz = seniorVNA + mezzVNA;
        uint256 juniorVNA = fidc.invested > seniorPlusMezz ? fidc.invested - seniorPlusMezz : 0;
        uint256 totalInv;
        uint256 batchSeniorVNA;
        uint256 batchMezzVNA;
        uint256 batchJuniorVNA;
        address[] memory filteredInvestors;
        uint256 endIndex;

        if (noSeries) {
            // No series mode: use all investors
            totalInv = investors.length;
            // Se cursor está além do fim, retornar batch vazio (evita underflow)
            if (startIndex >= totalInv) {
                return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
            }
            uint256 batchSize = (totalInv * batchPercentBPS) / YieldCalculator.PRECISION;
            if (batchPercentBPS > 0 && batchSize == 0) batchSize = 1;
            endIndex = startIndex + batchSize;
            if (endIndex > totalInv) endIndex = totalInv;
            processedInvestors = endIndex - startIndex;
            nextStartIndex = endIndex;

            (batchSeniorVNA, batchMezzVNA, batchJuniorVNA) =
                _calculateBatchVNAs(stable, investors, positions, startIndex, endIndex);

            filteredInvestors = new address[](0); // Not used in no series mode
        } else {
            // Series mode: filter investors by series
            filteredInvestors = _filterInvestorsBySeries(investors, positions, seriesInvestors, serieId);
            if (filteredInvestors.length == 0) {
                return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
            }

            totalInv = filteredInvestors.length;
            // Se cursor está além do fim, retornar batch vazio (evita underflow)
            if (startIndex >= totalInv) {
                return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
            }
            uint256 batchSize = (totalInv * batchPercentBPS) / YieldCalculator.PRECISION;
            if (batchPercentBPS > 0 && batchSize == 0) batchSize = 1;
            endIndex = startIndex + batchSize;
            if (endIndex > totalInv) endIndex = totalInv;
            processedInvestors = endIndex - startIndex;
            nextStartIndex = endIndex;

            (batchSeniorVNA, batchMezzVNA, batchJuniorVNA) =
                _calculateBatchVNAsBySeries(positions, filteredInvestors, startIndex, endIndex, serieId);
        }

        uint256 sInt = (seniorVNA * seniorYieldBPS) / YieldCalculator.PRECISION;
        uint256 mInt = (mezzVNA * mezzYieldBPS) / YieldCalculator.PRECISION;
        uint256 jInt = (juniorVNA * juniorYieldBPS) / YieldCalculator.PRECISION;

        GrossPaid memory g = _calcGrossPaid(availableWad, seniorVNA, mezzVNA, juniorVNA, sInt, mInt, jInt);
        fullPayment = g.fullPayment;

        // Senior
        uint256 sRatio =
            (seniorVNA == 0 || batchSeniorVNA == 0) ? 0 : Math.mulDiv(g.sPaidIntG, batchSeniorVNA, seniorVNA);
        uint256 sFee = Math.mulDiv(sRatio, fidc.feePlatform, YieldCalculator.PRECISION);
        // Proteção contra underflow - garantir que sRatio >= sFee
        uint256 sPaidInt = sRatio >= sFee ? sRatio - sFee : 0;

        if (sFee > 0 && fidc.walletPlatform != address(0)) {
            stable.safeTransfer(fidc.walletPlatform, YieldCalculator.scaleFromWad(sFee, dec));
        }

        if (sPaidInt > 0) {
            if (noSeries) {
                _distributeToClassBatch(
                    stable, investors, positions, 0, sPaidInt, batchSeniorVNA, dec, startIndex, endIndex
                );
            } else {
                _distributeToClassBatchBySeries(
                    stable,
                    positions,
                    filteredInvestors,
                    0,
                    sPaidInt,
                    batchSeniorVNA,
                    dec,
                    startIndex,
                    endIndex,
                    serieId
                );
            }
        }

        uint256 sPaidAmort =
            (seniorVNA == 0 || batchSeniorVNA == 0) ? 0 : Math.mulDiv(g.sPaidAmortG, batchSeniorVNA, seniorVNA);
        if (sPaidAmort > 0) {
            if (noSeries) {
                _amortizeClassBatch(
                    stable, investors, positions, 0, sPaidAmort, batchSeniorVNA, dec, startIndex, endIndex
                );
            } else {
                _amortizeClassBatchBySeries(
                    stable,
                    positions,
                    filteredInvestors,
                    0,
                    sPaidAmort,
                    batchSeniorVNA,
                    dec,
                    startIndex,
                    endIndex,
                    serieId
                );
            }
            // Proteção contra underflow - garantir que fidc.invested >= sPaidAmort
            if (uint256(fidc.invested) >= sPaidAmort) {
                fidc.invested -= uint128(sPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }

        seniorDistWad = sPaidInt + sPaidAmort;
        newSeniorVNA = seniorVNA > sPaidAmort ? seniorVNA - sPaidAmort : 0;

        // Mezzanine
        uint256 mRatio = (mezzVNA == 0 || batchMezzVNA == 0) ? 0 : Math.mulDiv(g.mPaidIntG, batchMezzVNA, mezzVNA);
        uint256 mFee = Math.mulDiv(mRatio, fidc.feePlatform, YieldCalculator.PRECISION);
        // Proteção contra underflow - garantir que mRatio >= mFee
        uint256 mPaidInt = mRatio >= mFee ? mRatio - mFee : 0;

        if (mFee > 0 && fidc.walletPlatform != address(0)) {
            stable.safeTransfer(fidc.walletPlatform, YieldCalculator.scaleFromWad(mFee, dec));
        }

        if (mPaidInt > 0) {
            if (noSeries) {
                _distributeToClassBatch(
                    stable, investors, positions, 1, mPaidInt, batchMezzVNA, dec, startIndex, endIndex
                );
            } else {
                _distributeToClassBatchBySeries(
                    stable, positions, filteredInvestors, 1, mPaidInt, batchMezzVNA, dec, startIndex, endIndex, serieId
                );
            }
        }

        uint256 mPaidAmort = (mezzVNA == 0 || batchMezzVNA == 0) ? 0 : Math.mulDiv(g.mPaidAmortG, batchMezzVNA, mezzVNA);
        if (mPaidAmort > 0) {
            if (noSeries) {
                _amortizeClassBatch(
                    stable, investors, positions, 1, mPaidAmort, batchMezzVNA, dec, startIndex, endIndex
                );
            } else {
                _amortizeClassBatchBySeries(
                    stable,
                    positions,
                    filteredInvestors,
                    1,
                    mPaidAmort,
                    batchMezzVNA,
                    dec,
                    startIndex,
                    endIndex,
                    serieId
                );
            }
            // Proteção contra underflow - garantir que fidc.invested >= mPaidAmort
            if (uint256(fidc.invested) >= mPaidAmort) {
                fidc.invested -= uint128(mPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }

        mezzDistWad = mPaidInt + mPaidAmort;
        newMezzVNA = mezzVNA > mPaidAmort ? mezzVNA - mPaidAmort : 0;

        // Junior
        uint256 jVNA = fidc.invested > (newSeniorVNA + newMezzVNA) ? fidc.invested - newSeniorVNA - newMezzVNA : 0;
        uint256 jRatio = (jVNA == 0 || batchJuniorVNA == 0) ? 0 : Math.mulDiv(g.jPaidIntG, batchJuniorVNA, jVNA);
        uint256 jFee = Math.mulDiv(jRatio, fidc.feePlatform, YieldCalculator.PRECISION);
        // Proteção contra underflow - garantir que jRatio >= jFee
        uint256 jPaidInt = jRatio >= jFee ? jRatio - jFee : 0;

        if (jFee > 0 && fidc.walletPlatform != address(0)) {
            stable.safeTransfer(fidc.walletPlatform, YieldCalculator.scaleFromWad(jFee, dec));
        }

        if (jPaidInt > 0) {
            if (noSeries) {
                _distributeToClassBatch(
                    stable, investors, positions, 2, jPaidInt, batchJuniorVNA, dec, startIndex, endIndex
                );
            } else {
                _distributeToClassBatchBySeries(
                    stable,
                    positions,
                    filteredInvestors,
                    2,
                    jPaidInt,
                    batchJuniorVNA,
                    dec,
                    startIndex,
                    endIndex,
                    serieId
                );
            }
        }

        uint256 jPaidAmort = (jVNA == 0 || batchJuniorVNA == 0) ? 0 : Math.mulDiv(g.jPaidAmortG, batchJuniorVNA, jVNA);
        if (jPaidAmort > 0) {
            if (noSeries) {
                _amortizeClassBatch(
                    stable, investors, positions, 2, jPaidAmort, batchJuniorVNA, dec, startIndex, endIndex
                );
            } else {
                _amortizeClassBatchBySeries(
                    stable,
                    positions,
                    filteredInvestors,
                    2,
                    jPaidAmort,
                    batchJuniorVNA,
                    dec,
                    startIndex,
                    endIndex,
                    serieId
                );
            }
            // Proteção contra underflow - garantir que fidc.invested >= jPaidAmort
            if (uint256(fidc.invested) >= jPaidAmort) {
                fidc.invested -= uint128(jPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }

        juniorDistWad = jPaidInt + jPaidAmort;

        emit DistributedWithYieldsBatch(
            fidcId,
            seniorDistWad,
            mezzDistWad,
            juniorDistWad,
            seniorYieldBPS,
            mezzYieldBPS,
            juniorYieldBPS,
            fullPayment,
            startIndex,
            endIndex,
            processedInvestors
        );
    }

    /**
     * @notice Calculates batch VNAs
     */
    function _calculateBatchVNAs(
        IERC20,
        /* stable */
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        uint256 startIndex,
        uint256 endIndex
    ) private view returns (uint256 batchSeniorVNA, uint256 batchMezzVNA, uint256 batchJuniorVNA) {
        for (uint256 i = startIndex; i < endIndex; ++i) {
            IFIDC_Optimized.Investment[] storage invs = positions[investors[i]];
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class == 0) batchSeniorVNA += invs[j].amount;
                else if (invs[j].class == 1) batchMezzVNA += invs[j].amount;
                else if (invs[j].class == 2) batchJuniorVNA += invs[j].amount;
            }
        }
    }

    /**
     * @notice Distributes yields by series using batch (avoids gas limit)
     * @dev Uses same FIDC storage slot via FIDCManagerLib
     */
    function distributeWithYieldsBatchBySeries(
        IERC20 stable,
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        mapping(string => address[]) storage seriesInvestors,
        IFIDC_Optimized.CompactFIDC storage fidc,
        uint256 seniorVNA,
        uint256 mezzVNA,
        uint256 fidcId,
        string calldata serieId,
        uint256 seniorYieldBPS,
        uint256 mezzYieldBPS,
        uint256 juniorYieldBPS,
        uint256 batchPercentBPS,
        uint256 startIndex
    )
        internal
        returns (
            uint256 seniorDistWad,
            uint256 mezzDistWad,
            uint256 juniorDistWad,
            bool fullPayment,
            uint256 newSeniorVNA,
            uint256 newMezzVNA,
            uint256 processedInvestors,
            uint256 nextStartIndex
        )
    {
        uint8 dec = IERC20Metadata(address(stable)).decimals();
        uint256 availableWad = YieldCalculator.scaleToWad(stable.balanceOf(address(this)), dec);
        if (availableWad == 0) revert FIDCErrors.InsufficientLiquidity();

        // Filter investors by series
        address[] memory filteredInvestors = _filterInvestorsBySeries(investors, positions, seriesInvestors, serieId);
        if (filteredInvestors.length == 0) {
            return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
        }

        uint256 seniorPlusMezz = seniorVNA + mezzVNA;
        uint256 juniorVNA = fidc.invested > seniorPlusMezz ? fidc.invested - seniorPlusMezz : 0;
        uint256 totalInv = filteredInvestors.length;
        // Se cursor está além do fim, retornar batch vazio (evita underflow)
        if (startIndex >= totalInv) {
            return (0, 0, 0, true, seniorVNA, mezzVNA, 0, 0);
        }
        uint256 batchSize = (totalInv * batchPercentBPS) / YieldCalculator.PRECISION;
        if (batchPercentBPS > 0 && batchSize == 0) batchSize = 1;
        uint256 endIndex = startIndex + batchSize;
        if (endIndex > totalInv) endIndex = totalInv;
        processedInvestors = endIndex - startIndex;
        nextStartIndex = endIndex;

        (uint256 batchSeniorVNA, uint256 batchMezzVNA, uint256 batchJuniorVNA) =
            _calculateBatchVNAsBySeries(positions, filteredInvestors, startIndex, endIndex, serieId);

        uint256 sInt = (seniorVNA * seniorYieldBPS) / YieldCalculator.PRECISION;
        uint256 mInt = (mezzVNA * mezzYieldBPS) / YieldCalculator.PRECISION;
        uint256 jInt = (juniorVNA * juniorYieldBPS) / YieldCalculator.PRECISION;

        GrossPaid memory g = _calcGrossPaid(availableWad, seniorVNA, mezzVNA, juniorVNA, sInt, mInt, jInt);
        fullPayment = g.fullPayment;

        // Senior
        uint256 sRatio =
            (seniorVNA == 0 || batchSeniorVNA == 0) ? 0 : Math.mulDiv(g.sPaidIntG, batchSeniorVNA, seniorVNA);
        uint256 sFee = Math.mulDiv(sRatio, fidc.feePlatform, YieldCalculator.PRECISION);
        // Proteção contra underflow - garantir que sRatio >= sFee
        uint256 sPaidInt = sRatio >= sFee ? sRatio - sFee : 0;

        if (sFee > 0 && fidc.walletPlatform != address(0)) {
            stable.safeTransfer(fidc.walletPlatform, YieldCalculator.scaleFromWad(sFee, dec));
        }

        if (sPaidInt > 0) {
            _distributeToClassBatchBySeries(
                stable, positions, filteredInvestors, 0, sPaidInt, batchSeniorVNA, dec, startIndex, endIndex, serieId
            );
        }

        uint256 sPaidAmort =
            (seniorVNA == 0 || batchSeniorVNA == 0) ? 0 : Math.mulDiv(g.sPaidAmortG, batchSeniorVNA, seniorVNA);
        if (sPaidAmort > 0) {
            _amortizeClassBatchBySeries(
                stable, positions, filteredInvestors, 0, sPaidAmort, batchSeniorVNA, dec, startIndex, endIndex, serieId
            );
            // Proteção contra underflow - garantir que fidc.invested >= sPaidAmort
            if (uint256(fidc.invested) >= sPaidAmort) {
                fidc.invested -= uint128(sPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }

        seniorDistWad = sPaidInt + sPaidAmort;
        newSeniorVNA = seniorVNA > sPaidAmort ? seniorVNA - sPaidAmort : 0;

        // Mezzanine
        uint256 mRatio = (mezzVNA == 0 || batchMezzVNA == 0) ? 0 : Math.mulDiv(g.mPaidIntG, batchMezzVNA, mezzVNA);
        uint256 mFee = Math.mulDiv(mRatio, fidc.feePlatform, YieldCalculator.PRECISION);
        // Proteção contra underflow - garantir que mRatio >= mFee
        uint256 mPaidInt = mRatio >= mFee ? mRatio - mFee : 0;

        if (mFee > 0 && fidc.walletPlatform != address(0)) {
            stable.safeTransfer(fidc.walletPlatform, YieldCalculator.scaleFromWad(mFee, dec));
        }

        if (mPaidInt > 0) {
            _distributeToClassBatchBySeries(
                stable, positions, filteredInvestors, 1, mPaidInt, batchMezzVNA, dec, startIndex, endIndex, serieId
            );
        }

        uint256 mPaidAmort = (mezzVNA == 0 || batchMezzVNA == 0) ? 0 : Math.mulDiv(g.mPaidAmortG, batchMezzVNA, mezzVNA);
        if (mPaidAmort > 0) {
            _amortizeClassBatchBySeries(
                stable, positions, filteredInvestors, 1, mPaidAmort, batchMezzVNA, dec, startIndex, endIndex, serieId
            );
            // Proteção contra underflow - garantir que fidc.invested >= mPaidAmort
            if (uint256(fidc.invested) >= mPaidAmort) {
                fidc.invested -= uint128(mPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }

        mezzDistWad = mPaidInt + mPaidAmort;
        newMezzVNA = mezzVNA > mPaidAmort ? mezzVNA - mPaidAmort : 0;

        // Junior
        uint256 jVNA = fidc.invested > (newSeniorVNA + newMezzVNA) ? fidc.invested - newSeniorVNA - newMezzVNA : 0;
        uint256 jRatio = (jVNA == 0 || batchJuniorVNA == 0) ? 0 : Math.mulDiv(g.jPaidIntG, batchJuniorVNA, jVNA);
        uint256 jFee = Math.mulDiv(jRatio, fidc.feePlatform, YieldCalculator.PRECISION);
        // Proteção contra underflow - garantir que jRatio >= jFee
        uint256 jPaidInt = jRatio >= jFee ? jRatio - jFee : 0;

        if (jFee > 0 && fidc.walletPlatform != address(0)) {
            stable.safeTransfer(fidc.walletPlatform, YieldCalculator.scaleFromWad(jFee, dec));
        }

        if (jPaidInt > 0) {
            _distributeToClassBatchBySeries(
                stable, positions, filteredInvestors, 2, jPaidInt, batchJuniorVNA, dec, startIndex, endIndex, serieId
            );
        }

        uint256 jPaidAmort = (jVNA == 0 || batchJuniorVNA == 0) ? 0 : Math.mulDiv(g.jPaidAmortG, batchJuniorVNA, jVNA);
        if (jPaidAmort > 0) {
            _amortizeClassBatchBySeries(
                stable, positions, filteredInvestors, 2, jPaidAmort, batchJuniorVNA, dec, startIndex, endIndex, serieId
            );
            // Proteção contra underflow - garantir que fidc.invested >= jPaidAmort
            if (uint256(fidc.invested) >= jPaidAmort) {
                fidc.invested -= uint128(jPaidAmort);
            } else {
                fidc.invested = 0;
            }
        }

        juniorDistWad = jPaidInt + jPaidAmort;
    }

    /**
     * @notice Filters investors by series
     * @dev FIXED: For serieId == "", returns ALL investors (no filtering)
     *      Position filtering will be done in distribution functions
     */
    function _filterInvestorsBySeries(
        address[] storage investors,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        mapping(string => address[]) storage seriesInvestors,
        string memory serieId
    ) private view returns (address[] memory) {
        if (bytes(serieId).length == 0) {
            // Return ALL investors (position filtering will be done later)
            address[] memory result = new address[](investors.length);
            for (uint256 i = 0; i < investors.length; i++) {
                result[i] = investors[i];
            }
            return result;
        } else {
            return seriesInvestors[serieId];
        }
    }

    /**
     * @notice Calculates batch VNAs filtered by series
     */
    function _calculateBatchVNAsBySeries(
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        address[] memory filteredInvestors,
        uint256 startIndex,
        uint256 endIndex,
        string memory serieId
    ) private view returns (uint256 batchSeniorVNA, uint256 batchMezzVNA, uint256 batchJuniorVNA) {
        for (uint256 i = startIndex; i < endIndex && i < filteredInvestors.length; ++i) {
            IFIDC_Optimized.Investment[] storage invs = positions[filteredInvestors[i]];
            for (uint256 j; j < invs.length; ++j) {
                bool matchesSeries = bytes(serieId).length == 0
                    ? bytes(invs[j].serieId).length == 0
                    : keccak256(bytes(invs[j].serieId)) == keccak256(bytes(serieId));

                if (matchesSeries) {
                    if (invs[j].class == 0) batchSeniorVNA += invs[j].amount;
                    else if (invs[j].class == 1) batchMezzVNA += invs[j].amount;
                    else if (invs[j].class == 2) batchJuniorVNA += invs[j].amount;
                }
            }
        }
    }

    /**
     * @notice Distributes to specific class filtering by series
     */
    function _distributeToClassBatchBySeries(
        IERC20 stable,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        address[] memory filteredInvestors,
        uint8 classId,
        uint256 totalAmountWad,
        uint256 totalClassInvWad,
        uint8 tokenDec,
        uint256 startIndex,
        uint256 endIndex,
        string memory serieId
    ) private {
        if (totalAmountWad == 0 || totalClassInvWad == 0) return;

        int256 lastIdx = -1;
        for (uint256 i = startIndex; i < endIndex && i < filteredInvestors.length; ++i) {
            IFIDC_Optimized.Investment[] storage invps = positions[filteredInvestors[i]];
            for (uint256 j; j < invps.length; ++j) {
                bool matchesSeries = bytes(serieId).length == 0
                    ? bytes(invps[j].serieId).length == 0
                    : keccak256(bytes(invps[j].serieId)) == keccak256(bytes(serieId));

                if (invps[j].class == classId && invps[j].amount > 0 && matchesSeries) {
                    lastIdx = int256(i);
                }
            }
        }
        if (lastIdx < 0) return;

        uint256 distributedWad = 0;
        for (uint256 i = startIndex; i < endIndex && i < filteredInvestors.length; ++i) {
            address inv = filteredInvestors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investedWad = 0;
            for (uint256 j; j < invs.length; ++j) {
                bool matchesSeries = bytes(serieId).length == 0
                    ? bytes(invs[j].serieId).length == 0
                    : keccak256(bytes(invs[j].serieId)) == keccak256(bytes(serieId));

                if (invs[j].class == classId && matchesSeries) investedWad += invs[j].amount;
            }

            if (investedWad == 0) continue;

            uint256 shareWad;
            if (int256(i) == lastIdx) {
                shareWad = totalAmountWad - distributedWad;
            } else {
                shareWad = (investedWad * totalAmountWad) / totalClassInvWad;
                distributedWad += shareWad;
            }
            uint256 shareNative = YieldCalculator.scaleFromWad(shareWad, tokenDec);
            if (shareNative > 0) stable.safeTransfer(inv, shareNative);
        }
    }

    /**
     * @notice Amortizes specific class filtering by series
     */
    function _amortizeClassBatchBySeries(
        IERC20 stable,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        address[] memory filteredInvestors,
        uint8 classId,
        uint256 amortWad,
        uint256 totalClassInvWad,
        uint8 tokenDec,
        uint256 startIndex,
        uint256 endIndex,
        string memory serieId
    ) private {
        if (amortWad == 0 || totalClassInvWad == 0) return;

        // Find last investor with VNA in this class/series (to allocate dust)
        int256 lastI = -1;
        for (uint256 i = startIndex; i < endIndex && i < filteredInvestors.length; ++i) {
            IFIDC_Optimized.Investment[] storage invps = positions[filteredInvestors[i]];
            for (uint256 j; j < invps.length; ++j) {
                bool matchesSeries = bytes(serieId).length == 0
                    ? bytes(invps[j].serieId).length == 0
                    : keccak256(bytes(invps[j].serieId)) == keccak256(bytes(serieId));
                if (invps[j].class == classId && invps[j].amount > 0 && matchesSeries) {
                    lastI = int256(i);
                }
            }
        }
        if (lastI < 0) return;

        uint256 distributedWad = 0;
        for (uint256 i = startIndex; i < endIndex && i < filteredInvestors.length; ++i) {
            address inv = filteredInvestors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investorVna = 0;
            uint256 lastIdx = type(uint256).max;
            for (uint256 j; j < invs.length; ++j) {
                bool matchesSeries = bytes(serieId).length == 0
                    ? bytes(invs[j].serieId).length == 0
                    : keccak256(bytes(invs[j].serieId)) == keccak256(bytes(serieId));

                if (invs[j].class == classId && invs[j].amount > 0 && matchesSeries) {
                    investorVna += invs[j].amount;
                    lastIdx = j;
                }
            }

            if (investorVna == 0) continue;

            uint256 investorAmortWad;
            if (int256(i) == lastI) {
                investorAmortWad = amortWad - distributedWad;
            } else {
                investorAmortWad = Math.mulDiv(investorVna, amortWad, totalClassInvWad);
                distributedWad += investorAmortWad;
            }
            uint256 investorAmortNative = YieldCalculator.scaleFromWad(investorAmortWad, tokenDec);
            if (investorAmortNative > 0) {
                stable.safeTransfer(inv, investorAmortNative);
            }

            if (investorAmortWad > 0) {
                uint256 reducedSum = 0;
                for (uint256 j; j < invs.length; ++j) {
                    bool matchesSeries = bytes(serieId).length == 0
                        ? bytes(invs[j].serieId).length == 0
                        : keccak256(bytes(invs[j].serieId)) == keccak256(bytes(serieId));

                    if (invs[j].class != classId || invs[j].amount == 0 || !matchesSeries) continue;
                    uint256 posShare;
                    if (j == lastIdx) {
                        posShare = investorAmortWad - reducedSum;
                    } else {
                        posShare = Math.mulDiv(invs[j].amount, investorAmortWad, investorVna);
                        reducedSum += posShare;
                    }
                    if (posShare > invs[j].amount) posShare = invs[j].amount;
                    invs[j].amount = uint128(invs[j].amount - posShare);
                }
            }
        }
    }

    /**
     * @notice Amortizes a class across an explicit list of investors (exact: no dust left)
     * @dev Used by PR3 amortization cycle (batch processing with cursors).
     * @param targetInvestors Subset of investors to process in this batch
     * @param serieHash keccak256(bytes(serieId)) (ignored if noSeries == true)
     * @param noSeries If true, do not filter by series (global scope)
     */
    function amortizeClassToTargetInvestors(
        IERC20 stable,
        mapping(address => IFIDC_Optimized.Investment[]) storage positions,
        address[] memory targetInvestors,
        bytes32 serieHash,
        bool noSeries,
        uint8 classId,
        uint256 amortWad,
        uint256 totalClassInvWad,
        uint8 tokenDec
    ) internal {
        if (amortWad == 0 || totalClassInvWad == 0 || targetInvestors.length == 0) return;

        int256 lastI = -1;
        for (uint256 i; i < targetInvestors.length; ++i) {
            IFIDC_Optimized.Investment[] storage invps = positions[targetInvestors[i]];
            for (uint256 j; j < invps.length; ++j) {
                if (invps[j].class != classId || invps[j].amount == 0) continue;
                if (!noSeries) {
                    if (keccak256(bytes(invps[j].serieId)) != serieHash) continue;
                }
                lastI = int256(i);
            }
        }
        if (lastI < 0) return;

        uint256 distributedWad = 0;
        for (uint256 i; i < targetInvestors.length; ++i) {
            address inv = targetInvestors[i];
            IFIDC_Optimized.Investment[] storage invs = positions[inv];

            uint256 investorVna = 0;
            uint256 lastPosIdx = type(uint256).max;
            for (uint256 j; j < invs.length; ++j) {
                if (invs[j].class != classId || invs[j].amount == 0) continue;
                if (!noSeries) {
                    if (keccak256(bytes(invs[j].serieId)) != serieHash) continue;
                }
                investorVna += invs[j].amount;
                lastPosIdx = j;
            }
            if (investorVna == 0) continue;

            uint256 investorAmortWad;
            if (int256(i) == lastI) {
                investorAmortWad = amortWad - distributedWad;
            } else {
                investorAmortWad = Math.mulDiv(investorVna, amortWad, totalClassInvWad);
                distributedWad += investorAmortWad;
            }

            uint256 investorAmortNative = YieldCalculator.scaleFromWad(investorAmortWad, tokenDec);
            if (investorAmortNative > 0) {
                stable.safeTransfer(inv, investorAmortNative);
            }

            if (investorAmortWad > 0) {
                uint256 reducedSum = 0;
                for (uint256 j; j < invs.length; ++j) {
                    if (invs[j].class != classId || invs[j].amount == 0) continue;
                    if (!noSeries) {
                        if (keccak256(bytes(invs[j].serieId)) != serieHash) continue;
                    }

                    uint256 posShare;
                    if (j == lastPosIdx) {
                        posShare = investorAmortWad - reducedSum;
                    } else {
                        posShare = Math.mulDiv(uint256(invs[j].amount), investorAmortWad, investorVna);
                        reducedSum += posShare;
                    }
                    if (posShare > invs[j].amount) posShare = invs[j].amount;
                    invs[j].amount = uint128(uint256(invs[j].amount) - posShare);
                }
            }
        }
    }
}
