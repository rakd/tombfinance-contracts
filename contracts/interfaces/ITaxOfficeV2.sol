// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ITaxOfficeV2 {
    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external;

    function addLiquidityTaxFree(
        address token,
        uint256 amtTomb,
        uint256 amtToken,
        uint256 amtTombMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        );

    function addLiquidityETHTaxFree(
        uint256 amtTomb,
        uint256 amtTombMin,
        uint256 amtFtmMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        );
}
