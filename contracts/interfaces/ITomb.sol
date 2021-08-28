// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ITomb {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function burnThreshold() external view returns (uint256);
    function taxTiersTwaps() external view returns (uint256[] memory);
    function taxTiersRates() external view returns (uint256[] memory);
}
