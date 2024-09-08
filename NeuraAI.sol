// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract NeuraAI is ERC20, ERC20Burnable, Ownable {
    uint256 public reflectionFeePercentage = 2; // 2% visszaosztás a tulajdonosoknak
    uint256 public developmentFeePercentage = 2; // 2% a fejlesztési alapba
    uint256 public liquidityFeePercentage = 1; // 1% automatikusan likviditásba
    uint256 public buybackFeePercentage = 1; // 1% visszavásárlásra
    uint256 public burnPercentage = 1; // 1% automatikusan elégetve
    address public developmentFund; // Fejlesztési alap cím
    address public liquidityPool; // Likviditási pool cím
    uint256 public maxTxAmount = 1000 * 10 ** decimals(); // Maximum tranzakciós összeg
    uint256 public maxTxPercentage = 5; // Maximum 5% a teljes kínálatból
    mapping(address => bool) public whitelist; // Fehérlistás címek
    mapping(address => uint256) public lockEndTime; // Zárolási idő
    mapping(address => uint256) public votes;
    mapping(bytes32 => uint256) public proposals;

    mapping(address => uint256) public stakingBalance;
    mapping(address => uint256) public lastStakeTime;
    uint256 public stakingRewardRate = 5; // Éves 5%-os jutalom a stakingre

    mapping(address => uint256) private _reflections;
    uint256 private _totalReflections;

    address[] private _allHolders; // A címek listája, akiknek tokenjük van
    mapping(address => bool) private _holders; // Címek, akik rendelkeznek tokenekkel

    // constructor, ahol msg.sender lesz az alapértelmezett tulajdonos (Ownable), és átadjuk az ERC20 paramétereket
    constructor(address _developmentFund, address _liquidityPool) ERC20("NeuraAI", "NAI") Ownable(msg.sender) {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
        developmentFund = _developmentFund;
        liquidityPool = _liquidityPool;
    }

    // Anti-whale mechanizmus: korlátozzuk a maximális tranzakció méretét
    modifier antiWhale(uint256 amount) {
        if (amount > (totalSupply() * maxTxPercentage) / 100) {
            require(false, unicode"Tul nagy tranzakcio");
        }
        _;
    }

    // DAO funkció: új javaslat létrehozása
    function createProposal(bytes32 proposalId) public onlyOwner {
        proposals[proposalId] = 0;
    }

    // DAO funkció: szavazás egy javaslatra
    function vote(bytes32 proposalId) public {
        require(balanceOf(msg.sender) > 0, "Nincs szavazati jog");
        require(votes[msg.sender] == 0, unicode"Mar szavaztal");
        proposals[proposalId] += balanceOf(msg.sender); 
        votes[msg.sender] = balanceOf(msg.sender);
    }

    // Szavazatok lekérése
    function getVotes(bytes32 proposalId) public view returns (uint256) {
        return proposals[proposalId];
    }

    // Általános tranzakció függvény, ahol kiszámítjuk a különböző díjakat, és alkalmazzuk az automatikus buyback és égetési funkciókat
    function transferWithFees(address sender, address recipient, uint256 amount) internal antiWhale(amount) {
        require(amount <= maxTxAmount, "Transfer amount exceeds the maxTxAmount.");
        require(whitelist[sender], "Sender is not whitelisted.");
        require(block.timestamp > lockEndTime[sender], "Tokens are locked.");

        // Tranzakciós díjak kiszámítása
        uint256 reflectionFee = (amount * reflectionFeePercentage) / 100;
        uint256 developmentFee = (amount * developmentFeePercentage) / 100;
        uint256 liquidityFee = (amount * liquidityFeePercentage) / 100;
        uint256 buybackFee = (amount * buybackFeePercentage) / 100;
        uint256 burnAmount = (amount * burnPercentage) / 100;
        uint256 amountAfterFee = amount - reflectionFee - developmentFee - liquidityFee - buybackFee - burnAmount;

        // Visszaosztás frissítése
        _distributeReflection(reflectionFee);

        // Fejlesztési díj átutalása a fejlesztési alapnak
        super._transfer(sender, developmentFund, developmentFee);

        // Likviditási díj átutalása a likviditási poolnak
        super._transfer(sender, liquidityPool, liquidityFee);

        // Buyback mechanizmus
        _buyback(buybackFee);

        // Tokenek égetése (defláció)
        _burn(sender, burnAmount);

        // A maradék token átutalása a címzettnek
        super._transfer(sender, recipient, amountAfterFee);
    }

    // Buyback mechanizmus: visszavásárlás és égetés
    function _buyback(uint256 amount) private {
        if (amount > 0) {
            _burn(address(this), amount); // Egyszerű égetés
        }
    }

    // Visszaosztás a token birtokosok között
    function _distributeReflection(uint256 reflectionAmount) private {
        uint256 supply = totalSupply();
        if (supply > 0 && _allHolders.length > 0) {
            uint256 reflectionPerToken = reflectionAmount / supply;
            for (uint256 i = 0; i < _allHolders.length; i++) {
                address holder = _allHolders[i];
                uint256 holderBalance = balanceOf(holder);
                uint256 reflectionShare = holderBalance * reflectionPerToken;
                if (reflectionShare > 0) {
                    _reflections[holder] += reflectionShare;
                }
            }
        }
    }

    // Token birtokosok lekérhetik a felhalmozott visszaosztásukat
    function claimReflection() public {
        uint256 reflection = _reflections[msg.sender];
        require(reflection > 0, unicode"Nincs visszaosztasra jogosult token");
        
        if (reflection > 0) {
            _reflections[msg.sender] = 0;
            _mint(msg.sender, reflection); // Visszaosztás kiutalása
        }
    }

    // Staking funkció
    function stake(uint256 amount) public {
        require(amount > 0, "Cannot stake 0 tokens");
        _transfer(msg.sender, address(this), amount);
        stakingBalance[msg.sender] += amount;
        lastStakeTime[msg.sender] = block.timestamp;
    }

    function unstake() public {
        uint256 stakedAmount = stakingBalance[msg.sender];
        require(stakedAmount > 0, "No tokens staked");

        uint256 stakingTime = block.timestamp - lastStakeTime[msg.sender];
        uint256 reward = (stakedAmount * stakingRewardRate * stakingTime) / (365 days);

        _transfer(address(this), msg.sender, stakedAmount + reward);
        stakingBalance[msg.sender] = 0;
    }

    // Fehérlistára felvétel
    function addToWhitelist(address account) public onlyOwner {
        whitelist[account] = true;
    }

    // Tokenek zárolása egy meghatározott időre
    function lockTokens(address account, uint256 lockTime) public onlyOwner {
        lockEndTime[account] = block.timestamp + lockTime;
    }

    // Frissítjük a tulajdonosokat minden token átutalás után
    function _afterTokenTransfer(address from, address to) internal {
        if (balanceOf(to) > 0 && !_holders[to]) {
            _holders[to] = true;
            _allHolders.push(to); // Új cím hozzáadása a listához
        }

        // Ha az "from" cím teljesen kiürül, eltávolíthatjuk (ha szükséges)
        if (balanceOf(from) == 0 && _holders[from]) {
            _holders[from] = false;
        }
    }
}
