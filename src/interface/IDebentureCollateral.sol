// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IDebentureCollateral
 * @notice Interface para usar DebentureSeries como colateral em FIDC
 */
interface IDebentureCollateral {
    /**
     * @notice Verifica se uma debênture pode ser usada como colateral
     * @param debentureAddress Endereço do contrato DebentureSeries
     * @param holder Endereço do holder
     * @param amount Quantidade de tokens
     * @return canUse True se pode usar
     * @return reason Motivo se não puder
     */
    function canUseAsCollateral(address debentureAddress, address holder, uint256 amount)
        external
        view
        returns (bool canUse, string memory reason);

    /**
     * @notice Calcula valor de colateral de uma debênture
     * @param debentureAddress Endereço do contrato
     * @param amount Quantidade de tokens
     * @return collateralValue Valor em stable token (WAD, 18 decimais)
     */
    function calculateCollateralValue(address debentureAddress, uint256 amount)
        external
        view
        returns (uint256 collateralValue);

    /**
     * @notice Transfere debênture para custódia do FIDC
     * @param fidcId ID do FIDC
     * @param debentureAddress Endereço do contrato
     * @param from De quem transfere
     * @param amount Quantidade
     */
    function transferToCustody(uint256 fidcId, address debentureAddress, address from, uint256 amount) external;

    /**
     * @notice Retorna debênture da custódia
     * @param fidcId ID do FIDC
     * @param debentureAddress Endereço do contrato
     * @param to Para quem retorna
     * @param amount Quantidade
     */
    function returnFromCustody(uint256 fidcId, address debentureAddress, address to, uint256 amount) external;
}
