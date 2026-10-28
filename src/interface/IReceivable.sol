// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IReceivable {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;

    /**
     * @notice ✅ FIX: Adicionado burnFrom para queimar do contrato
     * @dev Permite queimar tokens de um endereço específico (necessário para queimar do FIDC)
     */
    function burnFrom(address from, uint256 amount) external;
}
