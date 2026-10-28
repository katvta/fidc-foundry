// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IUnifiedEscrow
 * @notice Interface comum para contratos que podem atuar como escrow
 * @dev Permite ao UnifiedFactoryManager movimentar fundos autorizados
 */
interface IUnifiedEscrow {
    /**
     * @notice Permite transferência autorizada de fundos
     * @dev Só endereços autorizados podem chamar esta função
     * @param token Endereço do token ERC20
     * @param to Destinatário dos fundos
     * @param amount Quantidade a transferir
     * @return sucesso True se a transferência foi bem-sucedida
     */
    function authorizedTransfer(address token, address to, uint256 amount) external returns (bool sucesso);

    /**
     * @notice Verifica se um endereço está autorizado a movimentar fundos
     * @param authorizedAddress Endereço a verificar
     * @return autorizado True se o endereço está autorizado
     */
    function isAuthorized(address authorizedAddress) external view returns (bool autorizado);

    /**
     * @notice Obtém o endereço do token usado pelo escrow
     * @return tokenAddress Endereço do token ERC20
     */
    function getEscrowToken() external view returns (address tokenAddress);

    /**
     * @notice Obtém o saldo disponível para movimentação
     * @param token Endereço do token
     * @return saldo Saldo disponível
     */
    function getAvailableBalance(address token) external view returns (uint256 saldo);

    /**
     * @notice Evento emitido quando uma transferência autorizada ocorre
     */
    event AuthorizedTransferExecuted(
        address indexed token, address indexed from, address indexed to, uint256 amount, address authorizedBy
    );

    /**
     * @notice Evento emitido quando uma autorização é adicionada/removida
     */
    event AuthorizationChanged(address indexed authorizedAddress, bool indexed authorized, address changedBy);
}
