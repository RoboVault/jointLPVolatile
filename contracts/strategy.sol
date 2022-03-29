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
import "./interfaces/ctoken.sol";
// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

interface IJointVault {
    function addToJoint() external;
    function calculateProfit(address _token) external view returns(uint256 _loss, uint256 _profit);
    function withdraw(uint256 _debtProportion) external;
}

contract Strategy is BaseStrategy {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IJointVault jointVault; 
    ICTokenErc20 public cTokenLend;
    IUniswapV2Router01 router;
    IComptroller comptroller;
    IERC20 compToken;

    modifier onlyJoint() {
        _onlyJoint();
        _;
    }

    function _onlyJoint() internal {
        require(msg.sender == address(jointVault));
    }


    uint256 constant STD_PRECISION = 1e18;
    uint256 constant BASIS_PRECISION = 10000;
    address weth;
    // amount of Debt to Joint Strategy 
    uint256 public debtJoint; 
    bool internal forceHarvestTriggerOnce;

    constructor(
        address _vault,
        address _jointVault,
        address _cTokenLend,
        address _comptroller,
        address _router,
        address _compToken

        ) public BaseStrategy(_vault) {

        jointVault = IJointVault(_jointVault);
        cTokenLend = ICTokenErc20(_cTokenLend);
        comptroller = IComptroller(_comptroller);
        router = IUniswapV2Router01(_router);
        weth = router.WETH();
        compToken = IERC20(_compToken);

        want.approve(_jointVault, uint256(-1));
        want.approve(_cTokenLend, uint256(-1));
        compToken.approve(_router, uint256(-1));

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cTokenLend);
        comptroller.enterMarkets(cTokens);

        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "StrategyJointLpProvider";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return (balanceLend().add(balanceJoint()).add(balanceOfWant()));
    }

    function balanceLend() public view returns (uint256) {
        return (
            cTokenLend
                .balanceOf(address(this))
                .mul(cTokenLend.exchangeRateStored())
                .div(1e18)
        );
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

    // how much want is available to move to join LP provider 
    function wantAvailable() public view returns(uint256) {
        return(balanceOfWant().add(balanceLend()));
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
            _debtPayment = Math.min(balanceOfWant(), _debtOutstanding);
        }

        

        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
    }

    function _withdraw(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        /// 1) check how much want is available 
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
                uint256 amountFromJoint = _amountNeeded.sub(balanceWant);
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



    }

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyAuthorized {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }


    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        bool isInProfit = totalAssets > totalDebt;

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return isInProfit;
        }

        // otherwise, we don't harvest
        return false;
    }


    function adjustPosition(uint256 _debtOutstanding) internal override {
        
        uint256 wantBefore = balanceOfWant();

        if (_debtOutstanding >= wantBefore) {
            return;
        }

        jointVault.addToJoint();
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

        want.transfer(address(jointVault), _wantAmount);
        debtJoint = debtJoint.add(_wantAmount);

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
            cTokenLend.mint(amount);
        }
        
    }

    function _redeemWant(uint256 _redeem_amount) internal {
        if (_redeem_amount > 0){
            cTokenLend.redeemUnderlying(_redeem_amount);
        }
    }

    function _sellCompWant() internal virtual {
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

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }
}