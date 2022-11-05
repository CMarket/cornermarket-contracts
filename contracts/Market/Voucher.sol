// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract Voucher is ERC1155, Ownable {
    string baseURI;
    constructor(string memory uri_) ERC1155(uri_) {
        baseURI = uri_;
    }

    function mint(address to, uint256 id, uint256 amount, bytes memory data) public virtual onlyOwner {
        _mint(to, id, amount, data);
    }

    function batchMint(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data) public virtual onlyOwner {
        _mintBatch(to, ids, amounts, data);
    }

    function burn(address from, uint256 id, uint256 amount) public virtual onlyOwner {
        _burn(from, id, amount);
    }

    function batchBurn(address from, uint256[] memory ids, uint256[] memory amounts) public virtual onlyOwner {
        _burnBatch(from, ids, amounts);
    }

    function uri(uint256 tokenId) override public view returns (string memory) {
        return string (abi.encodePacked(baseURI, Strings.toString(tokenId)));
    }
}