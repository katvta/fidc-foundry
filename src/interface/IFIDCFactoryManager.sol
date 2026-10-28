// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IFIDCFactoryManager
 * @notice Interface para FactoryManager que cria e gerencia FIDCs usando Diamond pattern
 * @dev Garante que apenas FIDCs criados/registrados podem ser operados
 */
interface IFIDCFactoryManager {
    // struct para criação de FIDC
    struct CreateFIDCParams {
        string projectId;
        address tenantOwner;
        address stable;
        address manager;
        string fidcName;
        string ticker;
        uint32 juniorYieldBPS;
        uint32 grace;
        uint32 seniorYieldBPS;
        uint32 mezzYieldBPS;
        uint256 maxQuotas;
        uint256 maxSenior;
        uint256 maxMezz;
        uint256 maxJunior;
        uint32 feePlatform;
        address walletPlatform;
        uint256 assetPrice;
    }

    /**
     * @notice Cria um novo FIDC usando Diamond pattern (nova assinatura com struct)
     * @dev Deploy + diamondCut + init atômico. Preferir essa assinatura para evitar "stack too deep".
     * @param params Struct com todos os parâmetros de criação
     * @return fidcId ID único do FIDC
     * @return fidcDiamond Endereço do Diamond proxy
     * @return recebivelAddress Endereço do contrato Receivable
     */
    function createFIDCWithParams(CreateFIDCParams calldata params)
        external
        returns (uint256 fidcId, address fidcDiamond, address recebivelAddress);

    /**
     * @notice Cria um novo FIDC usando Diamond pattern (assinatura legacy)
     * @dev Mantida para compatibilidade. Internamente chama createFIDCWithParams.
     * @return fidcId ID único do FIDC
     * @return fidcDiamond Endereço do Diamond proxy
     * @return recebivelAddress Endereço do contrato Receivable
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
    ) external returns (uint256 fidcId, address fidcDiamond, address recebivelAddress);

    /**
     * @notice Verifica se um endereço é um FIDC válido criado por este factory
     * @param fidcDiamond Endereço a verificar
     * @return true se é um FIDC válido
     */
    function isFIDC(address fidcDiamond) external view returns (bool);

    /**
     * @notice Retorna o endereço do Diamond para um fidcId
     * @param fidcId ID do FIDC
     * @return fidcDiamond Endereço do Diamond (address(0) se não existe)
     */
    function getFIDC(uint256 fidcId) external view returns (address fidcDiamond);

    /**
     * @notice Retorna o endereço do Receivable para um fidcId
     * @param fidcId ID do FIDC
     * @return recebivelAddress Endereço do Receivable (address(0) se não existe)
     */
    function getReceivable(uint256 fidcId) external view returns (address recebivelAddress);

    /**
     * @notice Retorna o tenantOwner de um FIDC
     * @param fidcId ID do FIDC
     * @return tenantOwner Endereço do tenantOwner (address(0) se não existe)
     */
    function getTenantOwner(uint256 fidcId) external view returns (address tenantOwner);

    /**
     * @notice ✅ FIX: Adiciona operator (execução)
     * @dev Permite que Gateway (UnifiedFactoryManager) crie FIDCs
     * @param operator Endereço do operator a adicionar
     */
    function addOperator(address operator) external;

    /**
     * @notice ✅ FIX: Remove operator
     * @param operator Endereço do operator a remover
     */
    function removeOperator(address operator) external;
}

