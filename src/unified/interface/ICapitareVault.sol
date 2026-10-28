// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUnifiedEscrow} from "./IUnifiedEscrow.sol";

/**
 * @title ICapitareVault
 * @notice Interface para CapitareVault
 * @dev Usado para reduzir tamanho do bytecode ao evitar importar o contrato completo
 */
interface ICapitareVault is IUnifiedEscrow {
    /**
     * @notice Adiciona endereço autorizado
     * @param authorizedAddress Endereço a autorizar
     */
    function addAuthorizedAddress(address authorizedAddress) external;

    /**
     * @notice Remove endereço autorizado
     * @param authorizedAddress Endereço a remover
     */
    function removeAuthorizedAddress(address authorizedAddress) external;
}

