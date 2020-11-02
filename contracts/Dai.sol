//pragma solidity 0.5.8;
pragma solidity >=0.4.25 <0.7.0;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20Burnable.sol";

contract Dai is ERC20Detailed, ERC20Mintable {
    constructor() public ERC20Detailed("Dai", "Dai", 18) {}
}
