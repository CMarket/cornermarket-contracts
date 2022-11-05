// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
interface IVoucher is IERC1155 {
    function batchBurn( address from,uint256[] memory ids,uint256[] memory amounts ) external   ;
    function batchMint( address to,uint256[] memory ids,uint256[] memory amounts,bytes memory data ) external   ;
    function burn( address from,uint256 id,uint256 amount ) external   ;
    function mint( address to,uint256 id,uint256 amount,bytes memory data ) external   ;
    function owner(  ) external view returns (address ) ;
}