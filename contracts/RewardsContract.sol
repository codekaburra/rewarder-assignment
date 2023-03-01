//SPDX-License-Identifier: MIT
// File: @openzeppelin/contracts/ownership/Ownable.sol
pragma solidity ^0.8.7;

contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract StakedWrapper {
    uint256 public totalSupply;
    uint128 public buyback = 2; //defined in percentage
    mapping(address => uint256) private _balances;
    IERC20 public stakedToken;
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    // Comment: hardcoding address here is not a good practice, suggested to move to constructor or make it const here
    address public beneficiary = address(0xDbfd6dAbD2Eaf53e5dBDc5E96fFB7E5E6B201F69); 

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    string constant _transferErrorMessage = "staked token transfer failed";

    function stakeFor(address forWhom, uint128 amount) public payable virtual {
        IERC20 st = stakedToken;
        if (st == IERC20(address(0))) {
            //eth
            /**
             * Vulnerabilities: according to https://docs.soliditylang.org/en/v0.8.0/control-structures.html#checked-or-unchecked-arithmetic
             * all "unchecked" should be removed as revert on over- and underflow by default
             * transaction should be revert if over/underflow happens instead of go on invalid calculation 
             */
            unchecked {
                totalSupply += msg.value;
                _balances[forWhom] += msg.value;
            }
        } else {
            require(msg.value == 0, "Zero Eth not allowed"); // Comment: contradicts with error msg.
            require(amount > 0, "Stake should be greater than zero");
            require(st.transferFrom(msg.sender, address(this), amount), _transferErrorMessage);
            unchecked {
                totalSupply += amount;
                _balances[forWhom] += amount;
            }
        }
        emit Staked(forWhom, amount);
    }

    function withdraw(uint128 amount) public virtual {
        require(amount <= _balances[msg.sender], "withdraw: balance is lower");
        // Comment: to be safe, compare with totalSupply as well. i.e. require(amount <=totalSupply, "withdraw: balance is lower than totalSupply");
        unchecked {
            _balances[msg.sender] -= amount;
            totalSupply = totalSupply - amount;
        }

        IERC20 st = stakedToken;
        // Comment: ERC20 case missing handling for buyback 
        // Comment: buyback to beneficiary for ETH transfer missing result checking
        // Edited: share param for both ETH & ERC20 transfer

        /** 
         * Vulnerabilities: for buyback calculation
         * missing range checking for buyback param, if buyback>100 (i.e. > 100%), the whole calculation are invalid as amountToBeneficiary > user staked balance
         * Even if added range checking within setBuyback() function, the original buyback param is hardcoded.
         * Suggested to move it to constructor & call setBuyback() for safe
        */
        uint128 amountToBeneficiary = (amount * buyback) / 100;
        uint128 amountToUser = amount - amountToBeneficiary;
        if (st == IERC20(address(0))) { // Comment: unnecessary wrapping as IERC20 here. can be just : if (stakedToken==address(0))
            //eth
            (bool successBeneficiary_, ) = beneficiary.call{value: amountToBeneficiary}(""); 
            require(successBeneficiary_, "eth transfer failure - beneficiary"); // Edited: add transfer result checking 
            (bool success_, ) = msg.sender.call{value: amountToUser}("");
            require(success_, "eth transfer failure");
        } else {
            // Comment & Edited: ERC20 case missing handling for buyback , add it back
            require(stakedToken.transfer(beneficiary, amountToBeneficiary), _transferErrorMessage);
            require(stakedToken.transfer(msg.sender, amountToUser), _transferErrorMessage);
        }
        // Comment: personal practice , will keep buyback amount to beneficiary in Withdrawn event as well for reference.
        emit Withdrawn(msg.sender, amount);
    }
}

contract RewardsETH is StakedWrapper, Ownable { // Edited: Contract Name Mismatched
    IERC20 public rewardToken;
    uint256 public rewardRate;
    uint64 public periodFinish;
    uint64 public lastUpdateTime;
    uint128 public rewardPerTokenStored;
    struct UserRewards {
        uint128 userRewardPerTokenPaid;
        uint128 rewards;
    }
    mapping(address => UserRewards) public userRewards;
    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);
    uint256 public maxStakingAmount = 2 * 10 ** 0 * 10 ** 17; //0.2 ETH

    constructor(IERC20 _rewardToken, IERC20 _stakedToken) {
        rewardToken = _rewardToken;
        stakedToken = _stakedToken;
    }

    // Comment: updateReward() should be a function instead of modifier
    modifier updateReward(address account) {
        uint128 _rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        rewardPerTokenStored = _rewardPerTokenStored;
        userRewards[account].rewards = earned(account);
        userRewards[account].userRewardPerTokenPaid = _rewardPerTokenStored;
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint64) {
        uint64 blockTimestamp = uint64(block.timestamp);
        return blockTimestamp < periodFinish ? blockTimestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint128) {
        uint256 totalStakedSupply = totalSupply;
        if (totalStakedSupply == 0) {
            return rewardPerTokenStored;
        }
        unchecked {
            uint256 rewardDuration = lastTimeRewardApplicable() - lastUpdateTime;
            return uint128(rewardPerTokenStored + (rewardDuration * rewardRate * 1e18) / totalStakedSupply);
        }
    }

    function earned(address account) public view returns (uint128) {
        unchecked {
            return
                uint128(
                    (balanceOf(account) * (rewardPerToken() - userRewards[account].userRewardPerTokenPaid)) /
                        1e18 +
                        userRewards[account].rewards
                );
        }
    }

    function stake(uint128 amount) external payable {
        // Comment: should be checking overall staked amount instead of per each stake() call
        // Edit if above comment valid: require((balanceOf(msg.sender) + amount) <= maxStakingAmount, "amount exceed max staking amount");
        require(amount < maxStakingAmount, "amount exceed max staking amount");
        stakeFor(msg.sender, amount);
    }

    function stakeFor(address forWhom, uint128 amount) public payable override updateReward(forWhom) {
        super.stakeFor(forWhom, amount);
    }

    function withdraw(uint128 amount) public override updateReward(msg.sender) {
        super.withdraw(amount);
    }

    function exit() external {
        getReward();
        withdraw(uint128(balanceOf(msg.sender)));
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            userRewards[msg.sender].rewards = 0;
            require(rewardToken.transfer(msg.sender, reward), "reward transfer failed");
            emit RewardPaid(msg.sender, reward);
        }
    }

    function setRewardParams(uint128 reward, uint64 duration) external onlyOwner {
        unchecked {
            require(reward > 0);
            rewardPerTokenStored = rewardPerToken();
            uint64 blockTimestamp = uint64(block.timestamp);
            uint256 maxRewardSupply = rewardToken.balanceOf(address(this));
            if (rewardToken == stakedToken) maxRewardSupply -= totalSupply;
            uint256 leftover = 0;
            if (blockTimestamp >= periodFinish) {
                rewardRate = reward / duration;
            } else {
                uint256 remaining = periodFinish - blockTimestamp;
                leftover = remaining * rewardRate;
                rewardRate = (reward + leftover) / duration;
            }
            require(reward + leftover <= maxRewardSupply, "not enough tokens");
            lastUpdateTime = blockTimestamp;
            periodFinish = blockTimestamp + duration;
            emit RewardAdded(reward);
        }
    }

    function withdrawReward() external onlyOwner {
        uint256 rewardSupply = rewardToken.balanceOf(address(this)); //ensure funds staked by users can't be transferred out if(rewardToken == stakedToken)
        rewardSupply -= totalSupply;
        require(rewardToken.transfer(msg.sender, rewardSupply));
        rewardRate = 0;
        periodFinish = uint64(block.timestamp);
    }

    function setMaxStakingAmount(uint256 value) external onlyOwner {
        require(value > 0);
        maxStakingAmount = value;
    }

    function setBuyback(uint128 value) external onlyOwner {
        // Comment: this function should be move to StakedWrapper contract instead as buyback param is within StakedWrapper and shared with constructor
        // Vulnerabilities: add range checking 0-100 , otherwise withdrawal amount will be more then balance
        require(value<=100, "setBuyback: value out of range"); // Edited
        buyback = value;
    }

    function setBuyBackAddr(address addr) external onlyOwner {
        // Comment: optional - depends on use cases : check non zero address ?
        beneficiary = addr;
    }
}


/**
 * Extra code practice suggestion
 * 1. Ether transfer is expensive and shouldn't be done twice for users, keep track of beneficiary eligible amount, then make a function for beneficiary to withdraw them
 * 2. Items ordering (vars -> mapping -> event -> constructor -> functions)
 */