// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./library/TransferHelper.sol";
import "./interfaces/IVoucher.sol";
import "./interfaces/IAgentManager.sol";

contract CornerMarketStorage {
    uint constant HUNDRED_PERCENT = 10000;
    uint constant MAX_REWARD_RATE = 2000;
    uint constant MAX_SALE_PERIOD = 180 days;
    uint constant PROFIT_TYPE_BUY_REFERRER = 1;
    uint constant PROFIT_TYPE_COUPON_REFERRER = 2;
    uint constant PROFIT_TYPE_PLATFORM = 3;
    uint constant PROFIT_TYPE_MERCHANT = 4;
    uint constant PROFIT_TYPE_REFUND_TAX = 5;
    uint constant REFUND_TAX_RATE_MAX = 1000;
    enum CouponStatus{
        NOT_EXISTS,
        SELLING,
        BLOCK
    }
    enum RewardRateTarget{
        PLATFORM,
        BUYREFERRER,
        COUPONREFERRER
    }
    struct CouponMetadata{
        address owner;
        address payToken;
        uint pricePerCoupon;
        uint saleStart;
        uint saleEnd;
        uint useStart;
        uint useEnd;
        uint quota;
        uint refundTaxRate;
    }
    struct CouponMetadataStorage{
        address owner;
        address referrer;
        address payToken;
        uint pricePerCoupon;
        uint saleStart;
        uint saleEnd;
        uint useStart;
        uint useEnd;
        uint quota;
        uint refundTaxRate;
        uint sold;
        uint refund;
        uint verified;
        CouponStatus status;
    }
    struct Withdrawable{
        mapping(address => uint) earnings;
        mapping(address => uint) withdrawn;
    }
    struct Referralship{
        address referrer;
        uint expires;
    }
    Counters.Counter internal tokenId;
    mapping(uint => CouponMetadataStorage) public coupons;
    mapping(address => bool) public supportTokens;
    mapping(address => uint) public deposit;
    mapping(address => Withdrawable) internal revenue;
    mapping(address => Referralship) referrals;
    address public couponContract;
    uint public protectPeriod;
    uint public buyReferrerRewardRate;
    uint public couponReferrerRewardRate;
    uint public platformRewardRate;
    address public platformAccount;
    address public agentManager;
    mapping(address => uint) public referrerExitTime;
}

contract CornerMarket is CornerMarketStorage, AccessControl, IERC1155Receiver, ReentrancyGuard {
    using Counters for Counters.Counter;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    event CouponCreated(uint tokenId, CouponMetadata meta);
    event CouponStatusChange(uint tokenId, CouponStatus newStatus, CouponStatus oldStatus);
    event SupportTokenChange(address indexed token, bool newState, bool oldState);
    event BuyCoupon(address indexed payer, uint tokenId, uint amount, address payToken, uint payAmount, address indexed receiver);
    event Refund(uint tokenId, uint amount, address payer, address payToken, uint payAmount, address indexed receiver);
    event ReferrerUpdate(address indexed newReferrer, address oldReferrer, uint newExpire);
    event ReferrerRewardRateChange(RewardRateTarget target, uint newRewardRate, uint oldRewardRate);
    event PlatformAccountChange(address indexed newPlatformAccount, address oldPlatformAccount);
    event Verified(uint tokenId, uint amount, address indexed fromAccount, address indexed payToken, uint totalAmount);
    event Settlement(uint tokenId, uint profitType, address indexed account, address payToken, uint sharedAmount);
    event WithdrawEarnings(address indexed account, address payToken, uint amount);
    event CouponSaleTimeExtended(uint tokenId, uint newEndTime, uint oldEndTime);
    event Take(address account, address token, uint takeAmount);
    event ReferrerExitTimeExtended(address account, uint newExitTime, uint oldExitTime);
    event AgentManagerChange(address newAgentManager, address oldAgentManager);
    event ProtectPeriodChange(uint newPeriod, uint oldPeriod);

    constructor(address voucher, address _platformAccount) {
        require(_platformAccount != address(0), "invalid platform account");
        protectPeriod = 180 days;
        buyReferrerRewardRate = 500; // 500 = 5%
        couponReferrerRewardRate = 200; // 200 = 2%
        platformRewardRate = 300; // 300 = 3%
        couponContract = voucher;
        platformAccount = _platformAccount;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
    }
    
    function createCoupon(CouponMetadata memory meta) external {
        require(meta.useStart >= getBlockTimestamp(), "time error");
        require(meta.saleEnd > meta.saleStart, "sale time error");
        require(meta.useEnd > meta.useStart, "use time error");
        require(meta.saleEnd - meta.saleStart <= MAX_SALE_PERIOD, "sale time error");
        require(supportTokens[meta.payToken], "token not supported");
        require(IAgentManager(agentManager).validate(msg.sender), "referrer is not a valid agent");
        require(meta.refundTaxRate <= REFUND_TAX_RATE_MAX, "exceed max refund tax rate");
        tokenId.increment();
        uint id = tokenId.current();
        coupons[id] = CouponMetadataStorage({
            owner: meta.owner,
            referrer: msg.sender,
            payToken: meta.payToken,
            pricePerCoupon: meta.pricePerCoupon,
            saleStart: meta.saleStart,
            saleEnd: meta.saleEnd,
            useStart: meta.useStart,
            useEnd: meta.useEnd,
            quota: meta.quota,
            refundTaxRate: meta.refundTaxRate,
            sold: 0,
            refund: 0,
            verified: 0,
            status: CouponStatus.SELLING
        });

        emit CouponCreated(id, meta);
        if (meta.useEnd > referrerExitTime[msg.sender]) {
            emit ReferrerExitTimeExtended(msg.sender, meta.useEnd, referrerExitTime[msg.sender]);
            referrerExitTime[msg.sender] = meta.useEnd;
        }
    }
    
    // function setCouponContract(address voucher) external onlyRole(DEFAULT_ADMIN_ROLE) {
    //     couponContract = voucher;
    // }

    function blockCoupon(uint id) external onlyRole(OPERATOR_ROLE) {
        CouponMetadataStorage storage cms = coupons[id];
        require(cms.status == CouponStatus.SELLING, "invalid coupon");
        emit CouponStatusChange(id, CouponStatus.BLOCK, cms.status);
        cms.status = CouponStatus.BLOCK;
    }

    function setSupportToken(address token, bool support) external onlyRole(OPERATOR_ROLE) {
        require(supportTokens[token] != support, "not change");
        emit SupportTokenChange(token, support, supportTokens[token]);
        supportTokens[token] = support;
    }

    function setReferrerRewardRate(RewardRateTarget target, uint rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(rate <= MAX_REWARD_RATE, "out of range");
        if (target == RewardRateTarget.BUYREFERRER) {
            emit ReferrerRewardRateChange(target, rate, buyReferrerRewardRate);
            buyReferrerRewardRate = rate;
        }
        if (target == RewardRateTarget.COUPONREFERRER) {
            emit ReferrerRewardRateChange(target, rate, couponReferrerRewardRate);
            couponReferrerRewardRate = rate;
        }
        if (target == RewardRateTarget.PLATFORM) {
            emit ReferrerRewardRateChange(target, rate, platformRewardRate);
            platformRewardRate = rate;
        }
    }

    function setPlatformAccount(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "invalid account");
        emit PlatformAccountChange(account, platformAccount);
        platformAccount = account;
    }
    function setAgentManager(address _agentManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_agentManager != address(0), "invalid address");
        emit AgentManagerChange(_agentManager, agentManager);
        agentManager = _agentManager;
    }

    function setProtectPeriod(uint peroid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit ProtectPeriodChange(peroid, protectPeriod);
        protectPeriod = peroid;
    }
    function buyCoupon(uint id, uint amount, address receiver, address referrer) external nonReentrant {
        CouponMetadataStorage storage cms = coupons[id];
        require(cms.status == CouponStatus.SELLING, "coupon not for sale");
        require(cms.sold + amount - cms.refund <= cms.quota, "exceed quota");
        require(getBlockTimestamp() >= cms.saleStart && getBlockTimestamp() <= cms.saleEnd, "invalid sale period");
        uint payAmount = cms.pricePerCoupon * amount;
        TransferHelper.safeTransferFrom(cms.payToken, msg.sender, address(this), payAmount);
        deposit[cms.payToken] += payAmount;
        cms.sold += amount;
        emit BuyCoupon(msg.sender, id, amount, cms.payToken, payAmount, receiver);
        IVoucher(couponContract).mint(receiver, id, amount, "");
        Referralship storage ref = referrals[receiver];
        if (ref.referrer == address(0)) {
            uint nextExpire = getBlockTimestamp() + protectPeriod;
            emit ReferrerUpdate(referrer, ref.referrer, nextExpire);
            ref.referrer = referrer;
            ref.expires = nextExpire;
        }
    }

    function getRevenue(address user, address token) external view returns(uint, uint) {
        return (revenue[user].earnings[token], revenue[user].withdrawn[token]);
    }

    function verifyCoupon(uint id, uint amount) external nonReentrant {
        CouponMetadataStorage storage cms = coupons[id];
        require(getBlockTimestamp() >= cms.useStart && getBlockTimestamp() <= cms.useEnd, "out of use day ranges");
        IVoucher(couponContract).safeTransferFrom(msg.sender, address(this), id, amount, "");
        IVoucher(couponContract).burn(address(this), id, amount);

        uint totalAmount = cms.pricePerCoupon * amount;
        uint assignableAmount = totalAmount;
        emit Verified(id, amount, msg.sender, cms.payToken, totalAmount);
        if (buyReferrerRewardRate > 0) {
            uint referrerReward = totalAmount * buyReferrerRewardRate / HUNDRED_PERCENT;
            Referralship storage ref = referrals[msg.sender];
            address referrerAddress = ref.referrer;
            if (referrerAddress == address(0) || getBlockTimestamp() > ref.expires) {
                referrerAddress = platformAccount;
            }
            //referrer get paid and remove this part from total
            revenue[referrerAddress].earnings[cms.payToken] += referrerReward;
            _withdraw(cms.payToken, referrerAddress);
            emit Settlement(id, PROFIT_TYPE_BUY_REFERRER, referrerAddress, cms.payToken, referrerReward);
            assignableAmount -= referrerReward;
        }
        if (couponReferrerRewardRate > 0) {
            uint referrerReward = totalAmount * couponReferrerRewardRate / HUNDRED_PERCENT;
            address referrerAddress = cms.referrer;
            if (referrerAddress == address(0)) {
                referrerAddress = platformAccount;
            }
            revenue[referrerAddress].earnings[cms.payToken] += referrerReward;
            _withdraw(cms.payToken, referrerAddress);
            emit Settlement(id, PROFIT_TYPE_COUPON_REFERRER, referrerAddress, cms.payToken, referrerReward);
            assignableAmount -= referrerReward;
        }
        if (platformRewardRate > 0) {
            uint referrerReward = totalAmount * platformRewardRate / HUNDRED_PERCENT;
            revenue[platformAccount].earnings[cms.payToken] += referrerReward;
            _withdraw(cms.payToken, platformAccount);
            emit Settlement(id, PROFIT_TYPE_PLATFORM, platformAccount, cms.payToken, referrerReward);
            assignableAmount -= referrerReward;
        }
        //merchant get paid
        revenue[cms.owner].earnings[cms.payToken] += assignableAmount;
        _withdraw(cms.payToken, cms.owner);
        emit Settlement(id, PROFIT_TYPE_MERCHANT, cms.owner, cms.payToken, assignableAmount);

        cms.verified += amount;
    }

    function refundCoupon(uint id, uint amount, address receiver) external nonReentrant {
        CouponMetadataStorage storage cms = coupons[id];
        IVoucher(couponContract).safeTransferFrom(msg.sender, address(this), id, amount, "");
        IVoucher(couponContract).burn(address(this), id, amount);

        uint refundAmount = cms.pricePerCoupon * amount;
        cms.refund += amount;
        if (cms.refundTaxRate > 0) {
            uint tax = refundAmount * cms.refundTaxRate / HUNDRED_PERCENT;
            TransferHelper.safeTransfer(cms.payToken, cms.owner, tax);
            emit Settlement(id, PROFIT_TYPE_REFUND_TAX, platformAccount, cms.payToken, tax);
            refundAmount = refundAmount - tax;
        }
        TransferHelper.safeTransfer(cms.payToken, receiver, refundAmount);
        
        emit Refund(id, amount, msg.sender, cms.payToken, refundAmount, receiver);
    }

    // function withdraw(address[] memory tokens, address account) external {
    //     uint count = tokens.length;
    //     for(uint i = 0; i < count; i++) {
    //         address token = tokens[i];
    //         _withdraw(token, account);
    //     }
    // }

    function _withdraw(address token, address account) internal {
        uint withdrableAmount = revenue[account].earnings[token] - revenue[account].withdrawn[token];
        if (withdrableAmount > 0) {
            revenue[account].withdrawn[token] = revenue[account].earnings[token];
            TransferHelper.safeTransfer(token, account, withdrableAmount);
            emit WithdrawEarnings(account, token, withdrableAmount);
        }
    }
    

    function getBlockTimestamp() internal view returns (uint) {
        //solhint-disable-next-line not-rely-on-time
        return block.timestamp;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControl, IERC165) virtual view returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    function take(address token, uint amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) {
            TransferHelper.safeTransferETH(msg.sender, amount);
        } else {
            TransferHelper.safeTransfer(token, msg.sender, amount);
        }
        emit Take(msg.sender, token, amount);
    }
    function currentId() external view returns(uint) {
        return tokenId.current();
    }
}