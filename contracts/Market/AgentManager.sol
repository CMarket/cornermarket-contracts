// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./library/TransferHelper.sol";
import "./interfaces/ICornerMarket.sol";

contract AgentManager is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public payToken;
    address public cornerMarket;
    uint public depositAmount;
    uint public fines;
    mapping(address => uint) public collaterals;
    mapping(address => bool) public validate;
    event Deposit(address account, address payToken, uint depositAmount);
    event Withdraw(address account, address payToken, uint withdrawAmount);
    event MarginDecrease(address account, uint decreaseAmount, uint remainAmount);
    event Take(address account, address token, uint takeAmount);

    constructor(address _payToken, uint _depositAmount, address _cornerMarket) {
        payToken = _payToken;
        depositAmount = _depositAmount;
        cornerMarket = _cornerMarket;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
    }

    function deposit() external {
        require(!validate[msg.sender], "already validated");
        TransferHelper.safeTransferFrom(payToken, msg.sender, address(this), depositAmount);
        collaterals[msg.sender] += depositAmount;
        validate[msg.sender] = true;
        emit Deposit(msg.sender, payToken, depositAmount);
    }

    function withdraw() external {
        require(ICornerMarket(cornerMarket).referrerExitTime(msg.sender) <= getBlockTimestamp(), "some coupon not reach end time");
        uint withdrableAmount = collaterals[msg.sender];
        collaterals[msg.sender] = 0;
        validate[msg.sender] = false;
        TransferHelper.safeTransfer(payToken, msg.sender, withdrableAmount);
        emit Withdraw(msg.sender, payToken, withdrableAmount);
    }

    function deduct(address account, uint amount) external onlyRole(OPERATOR_ROLE) {
        require(amount <= collaterals[account], "amount out of range");
        collaterals[account] -= amount;
        fines += amount;
        if (collaterals[account] == 0) {
            validate[account] = false;
        }
        emit MarginDecrease(account, amount, collaterals[account]);
    }

    function take(address token, uint amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) {
            TransferHelper.safeTransferETH(msg.sender, amount);
        } else {
            TransferHelper.safeTransfer(token, msg.sender, amount);
        }
        emit Take(msg.sender, token, amount);
    }

    function getBlockTimestamp() internal view returns (uint) {
        //solhint-disable-next-line not-rely-on-time
        return block.timestamp;
    }
}
