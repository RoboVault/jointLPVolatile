// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";


interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

import "./interfaces/uniswap.sol";
import "./interfaces/aave/IAToken.sol";
import "./interfaces/aave/IVariableDebtToken.sol";
import "./interfaces/aave/IPool.sol";
import "./interfaces/aave/IAaveOracle.sol";

import {IStrategyInsurance} from "./StrategyInsurance.sol";


interface IJointVault {
    function addToJoint() external;
    function calculateProfit(address _token) external view returns(uint256 _loss, uint256 _profit);
    function withdraw(uint256 _debtProportion) external;
    function allStratsInProfit() external view returns(bool);
    function harvestFromProvider() external;
    function canHarvestJoint() external view returns(bool);
    function name() external view returns (string memory);
    function calcDebtRatioToken(uint256 _tokenIndex) external view returns(uint256);
}

contract providerAAVE is BaseStrategy {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IJointVault public jointVault; 

    IPool pool;
    IAToken aToken;
    IAaveOracle public oracle;

    IUniswapV2Router01 router;

    IERC20 compToken;

    IStrategyInsurance public insurance;

    modifier onlyJoint() {
        _onlyJoint();
        _;
    }

    function _onlyJoint() internal {
        require(msg.sender == address(jointVault));
    }

    uint256 public wantDecimals;

    uint256 public jointTokenIndex;
    uint256 public otherJointTokenIndex;
    uint256 constant STD_PRECISION = 1e18;
    uint256 constant BASIS_PRECISION = 10000;
    address weth;
    // amount of Debt to Joint Strategy 
    uint256 public debtJoint; 
    // this % of want must be available before adding to Joint 
    uint256 public debtJointMin = 500; 
    // max amount of want that can be provided to Joint 
    uint256 public debtJointMax = 9500;    
    // this % of want must be in lend before calling redeemWant (avoids issue with tiny amounts blocking withdrawals)
    uint256 public lendDustPercent = 10; 
    bool public forceHarvestTriggerOnce;
    bool public sellJointRewardsAtHarvest = true; 
    bool public sellCompAtHarvest = false; 

    // we look at how far debt Ratio is from 100% and take some fee equal to a portion of it's magnitude
    uint256 public debtDifferenceFee = 2000; 

    constructor(
        address _vault,
        address _jointVault,
        address _aToken,
        address _poolAddressesProvider,
        address _router,
        address _compToken

        ) public BaseStrategy(_vault) {

        wantDecimals = IERC20Extended(address(want)).decimals();

        jointVault = IJointVault(_jointVault);

        IPoolAddressesProvider provider =
            IPoolAddressesProvider(_poolAddressesProvider);
        pool = IPool(provider.getPool());
        oracle = IAaveOracle(provider.getPriceOracle());

        aToken = IAToken(_aToken);

        router = IUniswapV2Router01(_router);
        weth = router.WETH();
        compToken = IERC20(_compToken);

        want.approve(_jointVault, uint256(-1));
        want.approve(address(pool), uint256(-1));
        compToken.approve(_router, uint256(-1));

        maxReportDelay = 43200; // 12 hours
        minReportDelay = 28800; // 8 hours 
        profitFactor = 1500;
        
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "StrategyJointLpProvider";
    }

    function jointLPName() external view returns (string memory) {
        return (jointVault.name());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return (balanceLend().add(balanceJoint()).add(balanceOfWant()));
    }

    function balanceLend() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function balanceJoint() public view returns(uint256) {

        if (debtJoint ==0) {
            return(0);
        } else {
            (uint256 loss, uint256 profit) = jointVault.calculateProfit(address(want));
            return(debtJoint.add(profit).sub(loss));
        }
    }

    function balanceOfWant() public view returns(uint256) {
        return(want.balanceOf(address(this)));
    }

    function calcDebtRatio() public view returns(uint256) {
        if (debtJoint ==0) {
            return(0);
        }
        else {
            return jointVault.calcDebtRatioToken(jointTokenIndex);
        }
    }

    // how much want is available to move to join LP provider 
    function wantAvailable() public view returns(uint256) {
        uint256 wantFree = balanceOfWant().add(balanceLend());
        uint256 assets = estimatedTotalAssets();
        uint256 jointMin = debtJointMin.mul(assets).div(BASIS_PRECISION);
        // we check that free want is enough to cover existing jointMin held in strat & bigger than jointMin required to add to Joint  
        if (wantFree > jointMin.mul(2)){ 
            return(wantFree.sub(jointMin));
        } else {
            return(0);
        }
    }

    function getOraclePrice() public view returns(uint256) {
        uint256 wantOPrice = oracle.getAssetPrice(address(want));
        return(wantOPrice.mul(10**(18 - wantDecimals)));
    }


    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _harvestRewards();
        
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        
        if (totalAssets > totalDebt) {
            _profit = totalAssets.sub(totalDebt);
            (uint256 amountFreed, uint256 _slippage) = _withdraw(_debtOutstanding.add(_profit));
            uint256 balanceWant = balanceOfWant();
            if (_debtOutstanding > balanceWant) {
                _debtPayment = balanceWant;
                _profit = 0;
            } else {
                _debtPayment = _debtOutstanding;
                _profit = Math.min(_profit, balanceWant.sub(_debtPayment));
            }
            
        } else {
            _withdraw(_debtOutstanding);
            _loss = totalDebt.sub(totalAssets);
            _debtPayment = balanceOfWant();
        }

        debtJoint = balanceJoint();

        // Check if we're net loss or net profit
        if (_loss >= _profit) {
            _profit = 0;
            _loss = _loss.sub(_profit);
            insurance.reportLoss(totalDebt, _loss);
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
            uint256 insurancePayment =
                insurance.reportProfit(totalDebt, _profit);
            _profit = _profit.sub(insurancePayment);

            // double check insurance isn't asking for too much or zero
            if (insurancePayment > 0 && insurancePayment < _profit) {
                want.transfer(address(insurance), insurancePayment);
            }
        }
    }

    function _harvestRewards() internal {
        if (sellCompAtHarvest){
            _harvestComp();
        }
        if (sellJointRewardsAtHarvest && jointVault.canHarvestJoint()){
            jointVault.harvestFromProvider();
        }
    }

    function _withdraw(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        /// 1) check how much want is available 
        uint256 jointDebtRatio = calcDebtRatio();
        uint256 debtRatioDiff; 
        uint256 amountFromJoint;
        if (jointDebtRatio > BASIS_PRECISION) {
            debtRatioDiff = jointDebtRatio.sub(BASIS_PRECISION);
        } else {
            debtRatioDiff = BASIS_PRECISION.sub(jointDebtRatio);
        }

        uint256 balanceWant = balanceOfWant();
        if (_amountNeeded <= balanceWant) {
            return (_amountNeeded, 0);
        }

        // 2) first get want from lend 
        uint256 balanceInLend = balanceLend();
        _redeemWant(balanceInLend);
        balanceWant = balanceOfWant();

        if (_amountNeeded <= balanceWant) {
            // if enough we add back to collateral 
            _lendWant(balanceWant.sub(_amountNeeded));
            return (_amountNeeded, 0);
        } else {
            // if not enough after removing from lend we pull from joint 
            if (debtJoint > 0) {
                amountFromJoint = _amountNeeded.sub(balanceWant);
                uint256 debtProportion = Math.min(amountFromJoint.mul(BASIS_PRECISION).div(debtJoint), BASIS_PRECISION);
                if (debtProportion > 9500){
                    debtProportion = BASIS_PRECISION;
                }
                jointVault.withdraw(debtProportion);
    
            }
        }

        /// 3) then get want from joint vault
        _liquidatedAmount = balanceOfWant();
        if (_liquidatedAmount < _amountNeeded) { 
            _loss = _amountNeeded.sub(_liquidatedAmount);
        }

        if (amountFromJoint > 0) {
            uint256 _jointFee = amountFromJoint.mul(debtRatioDiff).div(BASIS_PRECISION).mul(debtDifferenceFee).div(BASIS_PRECISION);
            _loss = _loss.add(_jointFee);
        }

    }

    function setInsurance(address _insurance) external onlyAuthorized {
        require(address(insurance) == address(0));
        insurance = IStrategyInsurance(_insurance);
    }

    function migrateInsurance(address _newInsurance) external onlyGovernance {
        require(address(_newInsurance) == address(0));
        insurance.migrateInsurance(_newInsurance);
        insurance = IStrategyInsurance(_newInsurance);
    }


    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyAuthorized {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    function setLendDustPercent(uint256 _lendDustPercent) external onlyAuthorized {
        lendDustPercent = _lendDustPercent;
    }

    function setDebtDifferenceFee(uint256 _debtDifferenceFee) external onlyAuthorized {
        debtDifferenceFee = _debtDifferenceFee;
    }


    function setdebtJointThresholds(uint256 _debtJointMin, uint256 _debtJointMax) external onlyAuthorized {
        debtJointMin = _debtJointMin;
        debtJointMax = _debtJointMax;
    }

    function setJointTokenIndex(uint256 _jointTokenIndex) external onlyJoint {
        jointTokenIndex = _jointTokenIndex;
    }

    function setOtherJointTokenIndex(uint256 _otherJointTokenIndex) external onlyJoint {
        otherJointTokenIndex = _otherJointTokenIndex;
    }

    function isInProfit() public view returns(bool) {
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        return(totalAssets > totalDebt);
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return jointVault.allStratsInProfit();
        }

        // otherwise, we don't harvest
        return false;
    }


    function adjustPosition(uint256 _debtOutstanding) internal override {
        
        uint256 wantBefore = balanceOfWant();

        if (_debtOutstanding >= wantBefore) {
            return;
        }

        uint256 stratPercentFree = wantAvailable().mul(BASIS_PRECISION).div(estimatedTotalAssets());

        if (stratPercentFree > debtJointMin){
            jointVault.addToJoint();
        }

        uint256 wantAfter = balanceOfWant();

        if (wantAfter > 0) { 
            _lendWant(wantAfter);
        }

        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
    }

    // this is called by LpVault 
    function provideWant(uint256 _wantAmount) external onlyJoint {
        uint256 balanceWant = balanceOfWant();

        if (balanceWant < _wantAmount) {
            uint256 redeemAmount = _wantAmount.sub(balanceWant);
            _redeemWant(redeemAmount);
        }

        uint256 transferAmount = Math.min(_wantAmount, want.balanceOf(address(this)));

        want.transfer(address(jointVault), transferAmount);
        debtJoint = debtJoint.add(transferAmount);

    }

    function adjustJointDebtOnWithdraw(uint256 _debtProportion) external onlyJoint {
        debtJoint = debtJoint.mul(BASIS_PRECISION.sub(_debtProportion)).div(BASIS_PRECISION);
    }

    function liquidatePositionAuth(uint256 _amount) external onlyAuthorized {
        liquidatePosition(_amount);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceWant = balanceOfWant();
        uint256 totalAssets = estimatedTotalAssets();

        // if estimatedTotalAssets is less than params.debtRatio it means there's
        // been a loss (ignores pending harvests). This type of loss is calculated
        // proportionally
        // This stops a run-on-the-bank if there's IL between harvests.
        uint256 newAmount = _amountNeeded;
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets.mul(STD_PRECISION).div(totalDebt);
            newAmount = _amountNeeded.mul(ratio).div(STD_PRECISION);
            _loss = _amountNeeded.sub(newAmount);
        }

        // Liquidate the amount needed
        (, uint256 _slippage) = _withdraw(newAmount);
        _loss = _loss.add(_slippage);

        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        _liquidatedAmount = balanceOfWant();
        if (_liquidatedAmount.add(_loss) > _amountNeeded) {
            _liquidatedAmount = _amountNeeded.sub(_loss);
        } else {
            _loss = _amountNeeded.sub(_liquidatedAmount);
        }
    }

    function liquidateJointAuth() external onlyAuthorized {
        if (debtJoint > 0){
            jointVault.withdraw(BASIS_PRECISION);
        }
    }

    function liquidateLendAuth() external onlyAuthorized {
        _redeemWant(balanceLend());
    }

    function liquidateAllPositionsAuth() external onlyAuthorized {
        liquidateAllPositions();
    }

    function liquidateAllPositions() internal override returns (uint256) {
        
        _redeemWant(balanceLend());
        if (debtJoint > 0){
            jointVault.withdraw(BASIS_PRECISION);
        }

        return (want.balanceOf(address(this)));
    }

    function _getTotalDebt() internal view returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function _lendWant(uint256 amount) internal {
        if (amount > 0){
            pool.supply(address(want), amount, address(this), 0);
        }
        
    }

    function _redeemWant(uint256 _redeem_amount) internal {
        // we add this in as can get some weird errors when tiny amount of lend left blocking withdrawals
        uint256 redeemDust = _getTotalDebt().mul(lendDustPercent).div(BASIS_PRECISION);
        
        if (_redeem_amount > redeemDust){
            pool.withdraw(address(want), _redeem_amount, address(this));
        }
    }

    function _harvestComp() internal {
        
    }


    function _sellCompWant() internal {
        uint256 compBalance = compToken.balanceOf(address(this));
        if (compBalance == 0) return;
        router.swapExactTokensForTokens(
            compBalance,
            0,
            getTokenOutPath(address(compToken), address(want)),
            address(this),
            now
        );
    }

    function getTokenOutPath(address _token_in, address _token_out)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositions();
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}


    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }
}