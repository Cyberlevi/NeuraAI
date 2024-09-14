// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract NeuraAI is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    uint256 public reflectionFeePercentage = 2;
    uint256 public developmentFeePercentage = 2;
    uint256 public liquidityFeePercentage = 1;
    uint256 public buybackFeePercentage = 1;
    uint256 public burnPercentage = 1;
    uint256 public minStakingPeriod = 1 days;  // Minimális staking időszak
    uint256 public lastBuybackTime;            // Az utolsó buyback időbélyegzője
    uint256 public buybackInterval = 1 days;   // Buyback időköz
    address public developmentFund;
    address public liquidityPool;
    uint256 public maxTxAmount = 1000 * 10 ** decimals();
    uint256 public maxTxPercentage = 5;
    uint256 public buybackThreshold = 1000 * 10 ** decimals();
    uint256 public stakingRewardRate = 5;
    uint256 public _totalReflections;
    uint256 public maxReflectionDistribute = 100;
    bool public paused = false;

    mapping(address => bool) public whitelist;
    mapping(address => uint256) public lockEndTime;
    mapping(address => uint256) public stakingBalance;
    mapping(address => uint256) public lastStakeTime;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) private _reflections;
    address[] private _allHolders;
    mapping(address => bool) private _holders;

    struct Proposal {
        string description;
        uint256 voteCount;
        bool executed;
    }

    Proposal[] public proposals;

    // Events
    event Paused();
    event Unpaused();
    event Buyback(uint256 amount);
    event ReflectionDistributed(uint256 amount, uint256 count);
    event Voted(address indexed voter, uint256 proposalIndex);
    event FeeUpdated(uint256 reflectionFee, uint256 developmentFee, uint256 liquidityFee, uint256 buybackFee, uint256 burnPercentage);
    event StakingPeriodUpdated(uint256 minStakingPeriod);

    constructor(address _developmentFund, address _liquidityPool) 
        ERC20("NeuraAI", "NAI") 
    {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
        developmentFund = _developmentFund;
        liquidityPool = _liquidityPool;
        lastBuybackTime = block.timestamp;  // Buyback időzítő inicializálása
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused.");
        _;
    }

    // Új: Szerződés szünetelés eseményekkel
    function pauseContract() public onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpauseContract() public onlyOwner {
        paused = false;
        emit Unpaused();
    }

    // Új: Frissíthető díjak százalékos arányai
    function updateFees(
        uint256 _reflectionFeePercentage,
        uint256 _developmentFeePercentage,
        uint256 _liquidityFeePercentage,
        uint256 _buybackFeePercentage,
        uint256 _burnPercentage
    ) public onlyOwner {
        reflectionFeePercentage = _reflectionFeePercentage;
        developmentFeePercentage = _developmentFeePercentage;
        liquidityFeePercentage = _liquidityFeePercentage;
        buybackFeePercentage = _buybackFeePercentage;
        burnPercentage = _burnPercentage;
        emit FeeUpdated(reflectionFeePercentage, developmentFeePercentage, liquidityFeePercentage, buybackFeePercentage, burnPercentage);
    }

    // Új: Staking minimális időszak frissítése
    function updateMinStakingPeriod(uint256 _minStakingPeriod) public onlyOwner {
        minStakingPeriod = _minStakingPeriod;
        emit StakingPeriodUpdated(minStakingPeriod);
    }

    // Maximális tranzakció limit százalék alapú vizsgálat
    function _checkTransferLimits(address from, uint256 amount) internal view whenNotPaused {
        uint256 maxAllowedTxAmount = (totalSupply() * maxTxPercentage) / 100;
        require(amount <= maxAllowedTxAmount, "Transfer amount exceeds the max allowed percentage.");
        require(whitelist[from], "Sender is not whitelisted.");
        require(block.timestamp > lockEndTime[from], "Tokens are locked.");
    }

    function _handleTransferFees(address from, address to, uint256 amount) internal {
        uint256 reflectionFee = (amount * reflectionFeePercentage) / 100;
        uint256 developmentFee = (amount * developmentFeePercentage) / 100;
        uint256 liquidityFee = (amount * liquidityFeePercentage) / 100;
        uint256 buybackFee = (amount * buybackFeePercentage) / 100;
        uint256 burnAmount = (amount * burnPercentage) / 100;
        uint256 amountAfterFee = amount - reflectionFee - developmentFee - liquidityFee - buybackFee - burnAmount;

        _distributeReflection(reflectionFee);
        super._transfer(from, developmentFund, developmentFee);
        super._transfer(from, liquidityPool, liquidityFee);
        super._transfer(from, to, amountAfterFee);

        _handleBuyback(buybackFee);
        _burn(from, burnAmount);
    }

    function _afterCustomTransfer(address from, address to, uint256 amount) internal {
        _handleTransferFees(from, to, amount);
    }

    // Új: Buyback kezelése küszöb alapján és automatikus buyback időzítő
    function _handleBuyback(uint256 buybackFee) internal {
        if (buybackFee > 0 && balanceOf(address(this)) >= buybackThreshold) {
            _buyback(buybackFee);
        }
        // Automatikus buyback ellenőrzés
        if (block.timestamp >= lastBuybackTime + buybackInterval) {
            uint256 availableForBuyback = balanceOf(address(this));
            if (availableForBuyback >= buybackThreshold) {
                _buyback(availableForBuyback);
                lastBuybackTime = block.timestamp;
            }
        }
    }

    function _buyback(uint256 amount) private nonReentrant {
        if (amount > 0) {
            _burn(address(this), amount);
            emit Buyback(amount);
        }
    }

    function manualBuybackAndBurn(uint256 amount) public onlyOwner nonReentrant {
        _buyback(amount);
    }

    // Reflektív elosztás eseménnyel
    function _distributeReflection(uint256 reflectionAmount) private {
        uint256 supply = totalSupply();
        if (supply > 0 && _allHolders.length > 0) {
            uint256 reflectionPerToken = reflectionAmount / supply;
            uint256 count = 0;

            for (uint256 i = 0; i < _allHolders.length && count < maxReflectionDistribute; i++) {
                address holder = _allHolders[i];
                uint256 holderBalance = balanceOf(holder);
                uint256 reflectionShare = holderBalance * reflectionPerToken;
                if (reflectionShare > 0) {
                    _reflections[holder] += reflectionShare;
                    count++;
                }
            }

            emit ReflectionDistributed(reflectionAmount, count);
        }
    }

    function distributeReflectionPublic(uint256 reflectionAmount) public onlyOwner nonReentrant {
        _distributeReflection(reflectionAmount);
    }

    function claimReflection() public nonReentrant {
        uint256 reflection = _reflections[msg.sender];
        require(reflection > 0, "No reflection to claim.");
        _reflections[msg.sender] = 0;
        _mint(msg.sender, reflection);
    }

    // Szavazás eseménnyel
    function createProposal(string memory description) public onlyOwner {
        proposals.push(Proposal({
            description: description,
            voteCount: 0,
            executed: false
        }));
    }

    function voteOnProposal(uint256 proposalIndex) public {
        Proposal storage proposal = proposals[proposalIndex];
        require(!proposal.executed, "Proposal already executed.");
        require(!hasVoted[proposalIndex][msg.sender], "Already voted.");
        proposal.voteCount += balanceOf(msg.sender);
        hasVoted[proposalIndex][msg.sender] = true;
        emit Voted(msg.sender, proposalIndex);  // Szavazás esemény
    }

    function executeProposal(uint256 proposalIndex) public onlyOwner {
        Proposal storage proposal = proposals[proposalIndex];
        require(!proposal.executed, "Proposal already executed.");
        require(proposal.voteCount > totalSupply() / 2, "Not enough votes to execute.");
        proposal.executed = true;
        // Implementálja a javaslat végrehajtásának logikáját itt
    }

    // Új: Staking pool implementáció
    function stake(uint256 amount) public whenNotPaused nonReentrant {
        require(amount > 0, "Cannot stake 0 tokens.");
        require(block.timestamp >= lastStakeTime[msg.sender] + minStakingPeriod, "Staking period has not passed yet.");
        _transfer(msg.sender, address(this), amount);
        stakingBalance[msg.sender] += amount;
        lastStakeTime[msg.sender] = block.timestamp;
    }

    function unstake(uint256 amount) public whenNotPaused nonReentrant {
        require(amount > 0, "Cannot unstake 0 tokens.");
        require(stakingBalance[msg.sender] >= amount, "Insufficient staking balance.");
        require(block.timestamp >= lastStakeTime[msg.sender] + minStakingPeriod, "Staking period has not passed yet.");
        uint256 reward = calculateStakingReward(msg.sender);
        stakingBalance[msg.sender] -= amount;
        _transfer(address(this), msg.sender, amount + reward);
    }

    function calculateStakingReward(address account) public view returns (uint256) {
        uint256 stakedTime = block.timestamp - lastStakeTime[account];
        uint256 reward = (stakingBalance[account] * stakingRewardRate * stakedTime) / (365 days * 100);
        return reward;
    }

    function addToWhitelist(address account) public onlyOwner {
        whitelist[account] = true;
    }

    function removeFromWhitelist(address account) public onlyOwner {
        whitelist[account] = false;
    }

    function lockTokens(address account, uint256 lockTime) public onlyOwner {
        lockEndTime[account] = block.timestamp + lockTime;
    }

    function unlockTokens(address account) public onlyOwner {
        lockEndTime[account] = 0;
    }

    function transferWithCustomLogic(address from, address to, uint256 amount) public {
        require(whitelist[from] || from == owner(), "Only whitelisted users or owner can use custom logic.");  // Access control
        _checkTransferLimits(from, amount);
        _afterCustomTransfer(from, to, amount);
    }

    function _addHolder(address account) private {
        if (!_holders[account]) {
            _holders[account] = true;
            _allHolders.push(account);
        }
    }

    function _removeHolder(address account) private {
        if (_holders[account]) {
            _holders[account] = false;
            for (uint256 i = 0; i < _allHolders.length; i++) {
                if (_allHolders[i] == account) {
                    _allHolders[i] = _allHolders[_allHolders.length - 1];
                    _allHolders.pop();
                    break;
                }
            }
        }
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        _checkTransferLimits(sender, amount);
        super._transfer(sender, recipient, amount);
        _afterCustomTransfer(sender, recipient, amount);
        _addHolder(recipient);
        if (balanceOf(sender) == 0) {
            _removeHolder(sender);
        }
    }

    function _mint(address account, uint256 amount) internal virtual override {
        super._mint(account, amount);
        _addHolder(account);
    }

    function _burn(address account, uint256 amount) internal virtual override {
        super._burn(account, amount);
        if (balanceOf(account) == 0) {
            _removeHolder(account);
        }
    }
}

