// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IMasonry.sol";

interface IBondTreasury {
    function totalVested() external view returns (uint256);
}

contract Treasury is ContractGuard, Operator {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    address[] public excludedFromTotalSupply;

    // core components
    address public Polystone;
    address public Gravel;
    address public Rock;

    address public masonry;
    address public bondTreasury;
    address public PolyOracle;

    // price
    uint256 public PolyPriceOne;
    uint256 public PolyPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    uint256 public bondSupplyExpansionPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of Poly price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochPolyPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra Poly during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(
        address indexed from,
        uint256 PolyAmount,
        uint256 bondAmount
    );
    event BoughGravels(
        address indexed from,
        uint256 PolyAmount,
        uint256 bondAmount
    );
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event MasonryFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier checkCondition() {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getPolyPrice() > PolyPriceCeiling)
            ? 0
            : getPolyCirculatingSupply().mul(maxSupplyContractionPercent).div(
                10000
            );
    }

    modifier checkOperator() {
        require(
            IBasisAsset(Polystone).operator() == address(this) &&
                IBasisAsset(Gravel).operator() == address(this) &&
                IBasisAsset(Rock).operator() == address(this) &&
                Operator(masonry).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getPolyPrice() public view returns (uint256 PolyPrice) {
        try IOracle(PolyOracle).consult(Polystone, 1e18) returns (
            uint144 price
        ) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult Poly price from the oracle");
        }
    }

    function getPolyUpdatedPrice() public view returns (uint256 _PolyPrice) {
        try IOracle(PolyOracle).twap(Polystone, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult Poly price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnablePolyLeft()
        public
        view
        returns (uint256 _burnablePolyLeft)
    {
        uint256 _PolyPrice = getPolyPrice();
        if (_PolyPrice <= PolyPriceOne) {
            uint256 _PolySupply = getPolyCirculatingSupply();
            uint256 _bondMaxSupply = _PolySupply.mul(maxDebtRatioPercent).div(
                10000
            );
            uint256 _bondSupply = IERC20(Gravel).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnablePoly = _maxMintableBond.mul(_PolyPrice).div(
                    1e18
                );
                _burnablePolyLeft = Math.min(
                    epochSupplyContractionLeft,
                    _maxBurnablePoly
                );
            }
        }
    }

    function getRedeemableBonds()
        public
        view
        returns (uint256 _redeemableBonds)
    {
        uint256 _PolyPrice = getPolyPrice();
        if (_PolyPrice > PolyPriceCeiling) {
            uint256 _totalPoly = IERC20(Polystone).balanceOf(address(this));
            uint256 _rate = getGravelPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalPoly.mul(1e18).div(_rate);
            }
        }
    }

    function getGravelDiscountRate() public view returns (uint256 _rate) {
        uint256 _PolyPrice = getPolyPrice();
        if (_PolyPrice <= PolyPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = PolyPriceOne;
            } else {
                uint256 _bondAmount = PolyPriceOne.mul(1e18).div(_PolyPrice); // to burn 1 Poly
                uint256 _discountAmount = _bondAmount
                    .sub(PolyPriceOne)
                    .mul(discountPercent)
                    .div(10000);
                _rate = PolyPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getGravelPremiumRate() public view returns (uint256 _rate) {
        uint256 _PolyPrice = getPolyPrice();
        if (_PolyPrice > PolyPriceCeiling) {
            uint256 _PolyPricePremiumThreshold = PolyPriceOne
                .mul(premiumThreshold)
                .div(100);
            if (_PolyPrice >= _PolyPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _PolyPrice
                    .sub(PolyPriceOne)
                    .mul(premiumPercent)
                    .div(10000);
                _rate = PolyPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = PolyPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _Poly,
        address _Gravel,
        address _Rock,
        uint256 _startTime
    ) public notInitialized onlyOperator {
        Polystone = _Poly;
        Gravel = _Gravel;
        Rock = _Rock;
        startTime = _startTime;

        PolyPriceOne = 10**18;
        PolyPriceCeiling = PolyPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [
            0 ether,
            500000 ether,
            1000000 ether,
            1500000 ether,
            2000000 ether,
            5000000 ether,
            10000000 ether,
            20000000 ether,
            50000000 ether
        ];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for masonry
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn Poly and mint Gravel)
        maxDebtRatioPercent = 3500; // Upto 35% supply of Gravel to purchase

        bondSupplyExpansionPercent = 500; // maximum 5% emissions per epoch for POL bonds

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 12 epochs with 5% expansion
        bootstrapEpochs = 12;
        bootstrapSupplyExpansionPercent = 500;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(Polystone).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function setbondTreasury(address _bondTreasury) external onlyOperator {
        bondTreasury = _bondTreasury;
    }

    function setGenesis(address _genesisPool) external onlyOperator {
        excludedFromTotalSupply.push(_genesisPool);
    }

    function setOracle(address _oracle) external onlyOperator {
        PolyOracle = _oracle;
    }

    function setMasonry(address _masonry) external onlyOperator {
        masonry = _masonry;
    }

    function setGravelTreasury(address _bondTreasury) external onlyOperator {
        bondTreasury = _bondTreasury;
        excludedFromTotalSupply.push(_bondTreasury);
    }

    function setPolyOracle(address _PolyOracle) external onlyOperator {
        PolyOracle = _PolyOracle;
    }

    function setPolyPriceCeiling(uint256 _PolyPriceCeiling)
        external
        onlyOperator
    {
        require(
            _PolyPriceCeiling >= PolyPriceOne &&
                _PolyPriceCeiling <= PolyPriceOne.mul(120).div(100),
            "out of range"
        ); // [$1.0, $1.2]
        PolyPriceCeiling = _PolyPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent)
        external
        onlyOperator
    {
        require(
            _maxSupplyExpansionPercent >= 10 &&
                _maxSupplyExpansionPercent <= 1000,
            "_maxSupplyExpansionPercent: out of range"
        ); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value)
        external
        onlyOperator
        returns (bool)
    {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value)
        external
        onlyOperator
        returns (bool)
    {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function seGravelDepletionFloorPercent(uint256 _bondDepletionFloorPercent)
        external
        onlyOperator
    {
        require(
            _bondDepletionFloorPercent >= 500 &&
                _bondDepletionFloorPercent <= 10000,
            "out of range"
        ); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(
        uint256 _maxSupplyContractionPercent
    ) external onlyOperator {
        require(
            _maxSupplyContractionPercent >= 100 &&
                _maxSupplyContractionPercent <= 1500,
            "out of range"
        ); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent)
        external
        onlyOperator
    {
        require(
            _maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000,
            "out of range"
        ); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(
        uint256 _bootstrapEpochs,
        uint256 _bootstrapSupplyExpansionPercent
    ) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(
            _bootstrapSupplyExpansionPercent >= 100 &&
                _bootstrapSupplyExpansionPercent <= 1000,
            "_bootstrapSupplyExpansionPercent: out of range"
        ); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate)
        external
        onlyOperator
    {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent)
        external
        onlyOperator
    {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold)
        external
        onlyOperator
    {
        require(
            _premiumThreshold >= PolyPriceCeiling,
            "_premiumThreshold exceeds PolyPriceCeiling"
        );
        require(
            _premiumThreshold <= 150,
            "_premiumThreshold is higher than 1.5"
        );
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt)
        external
        onlyOperator
    {
        require(
            _mintingFactorForPayingDebt >= 10000 &&
                _mintingFactorForPayingDebt <= 20000,
            "_mintingFactorForPayingDebt: out of range"
        ); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    function seGravelSupplyExpansionPercent(uint256 _bondSupplyExpansionPercent)
        external
        onlyOperator
    {
        bondSupplyExpansionPercent = _bondSupplyExpansionPercent;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updatePolyPrice() internal {
        try IOracle(PolyOracle).update() {} catch {}
    }

    function getPolyCirculatingSupply() public view returns (uint256) {
        IERC20 PolyErc20 = IERC20(Polystone);
        uint256 totalSupply = PolyErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (
            uint8 entryId = 0;
            entryId < excludedFromTotalSupply.length;
            ++entryId
        ) {
            balanceExcluded = balanceExcluded.add(
                PolyErc20.balanceOf(excludedFromTotalSupply[entryId])
            );
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _PolyAmount, uint256 targetPrice)
        external
        onlyOneBlock
        checkCondition
        checkOperator
    {
        require(
            _PolyAmount > 0,
            "Treasury: cannot purchase bonds with zero amount"
        );

        uint256 PolyPrice = getPolyPrice();
        require(PolyPrice == targetPrice, "Treasury: Poly price moved");
        require(
            PolyPrice < PolyPriceOne, // price < $1
            "Treasury: PolyPrice not eligible for bond purchase"
        );

        require(
            _PolyAmount <= epochSupplyContractionLeft,
            "Treasury: not enough bond left to purchase"
        );

        uint256 _rate = getGravelDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _PolyAmount.mul(_rate).div(1e18);
        uint256 PolySupply = getPolyCirculatingSupply();
        uint256 newBondSupply = IERC20(Gravel).totalSupply().add(_bondAmount);
        require(
            newBondSupply <= PolySupply.mul(maxDebtRatioPercent).div(10000),
            "over max debt ratio"
        );

        IBasisAsset(Polystone).burnFrom(msg.sender, _PolyAmount);
        IBasisAsset(Gravel).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(
            _PolyAmount
        );
        _updatePolyPrice();

        emit BoughGravels(msg.sender, _PolyAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice)
        external
        onlyOneBlock
        checkCondition
        checkOperator
    {
        require(
            _bondAmount > 0,
            "Treasury: cannot redeem bonds with zero amount"
        );

        uint256 PolyPrice = getPolyPrice();
        require(PolyPrice == targetPrice, "Treasury: Poly price moved");
        require(
            PolyPrice > PolyPriceCeiling, // price > $1.01
            "Treasury: PolyPrice not eligible for bond purchase"
        );

        uint256 _rate = getGravelPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _PolyAmount = _bondAmount.mul(_rate).div(1e18);
        require(
            IERC20(Polystone).balanceOf(address(this)) >= _PolyAmount,
            "Treasury: treasury has no more budget"
        );

        seigniorageSaved = seigniorageSaved.sub(
            Math.min(seigniorageSaved, _PolyAmount)
        );

        IBasisAsset(Gravel).burnFrom(msg.sender, _bondAmount);
        IERC20(Polystone).safeTransfer(msg.sender, _PolyAmount);

        _updatePolyPrice();

        emit RedeemedBonds(msg.sender, _PolyAmount, _bondAmount);
    }

    function _sendToMasonry(uint256 _amount) internal {
        IBasisAsset(Polystone).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(Polystone).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(Polystone).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(Polystone).safeApprove(masonry, 0);
        IERC20(Polystone).safeApprove(masonry, _amount);
        IMasonry(masonry).allocateSeigniorage(_amount);
        emit MasonryFunded(now, _amount);
    }

    function _sendToBondTreasury(uint256 _amount) internal {
        uint256 treasuryBalance = IERC20(Polystone).balanceOf(bondTreasury);
        uint256 treasuryVested = IBondTreasury(bondTreasury).totalVested();
        if (treasuryVested >= treasuryBalance) return;
        uint256 unspent = treasuryBalance.sub(treasuryVested);
        if (_amount > unspent) {
            IBasisAsset(Polystone).mint(bondTreasury, _amount.sub(unspent));
        }
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _PolySupply)
        internal
        returns (uint256)
    {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_PolySupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkCondition
        checkEpoch
        checkOperator
    {
        _updatePolyPrice();
        previousEpochPolyPrice = getPolyPrice();
        uint256 PolySupply = getPolyCirculatingSupply().sub(seigniorageSaved);
        _sendToBondTreasury(
            PolySupply.mul(bondSupplyExpansionPercent).div(10000)
        );
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToMasonry(
                PolySupply.mul(bootstrapSupplyExpansionPercent).div(10000)
            );
        } else {
            if (previousEpochPolyPrice > PolyPriceCeiling) {
                // Expansion ($Poly Price > 1 $FTM): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(Gravel).totalSupply();
                uint256 _percentage = previousEpochPolyPrice.sub(PolyPriceOne);
                uint256 _savedForBond;
                uint256 _savedForMasonry;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(PolySupply)
                    .mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (
                    seigniorageSaved >=
                    bondSupply.mul(bondDepletionFloorPercent).div(10000)
                ) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForMasonry = PolySupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = PolySupply.mul(_percentage).div(
                        1e18
                    );
                    _savedForMasonry = _seigniorage
                        .mul(seigniorageExpansionFloorPercent)
                        .div(10000);
                    _savedForBond = _seigniorage.sub(_savedForMasonry);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond
                            .mul(mintingFactorForPayingDebt)
                            .div(10000);
                    }
                }
                if (_savedForMasonry > 0) {
                    _sendToMasonry(_savedForMasonry);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(Polystone).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(Polystone), "Polystone");
        require(address(_token) != address(Gravel), "bond");
        require(address(_token) != address(Rock), "share");
        _token.safeTransfer(_to, _amount);
    }

    function masonrySetOperator(address _operator) external onlyOperator {
        IMasonry(masonry).setOperator(_operator);
    }

    function masonrySetLockUp(
        uint256 _withdrawLockupEpochs,
        uint256 _rewardLockupEpochs
    ) external onlyOperator {
        IMasonry(masonry).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function masonryAllocateSeigniorage(uint256 amount) external onlyOperator {
        IMasonry(masonry).allocateSeigniorage(amount);
    }

    function masonryGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IMasonry(masonry).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
