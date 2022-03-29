// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from  "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


import "./interfaces/Curve.sol";
import "./interfaces/Gauge.sol";
import "./interfaces/uniswap.sol";

interface ERC20Decimals {
    function decimals() external view returns (uint256);
}


interface IStrat {
    function strategist() external view returns (address);
    function keeper() external view returns (address);
    function want() external view returns (address);
    function wantAvailable() external view returns(uint256);
    function provideWant(uint256 _wantAmount) external; 
    function totalDebt() external view returns (uint256);
    function debtJoint() external view returns (uint256);
    function adjustJointDebtOnWithdraw(uint256 _debtProportion) external;
}

contract jointLPHolder is Ownable {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;


    uint256 internal numTokens;
    uint256 public slippageAdj = 9900; // 99%
    uint256 constant BASIS_PRECISION = 10000;
    bool public initialisedStrategies = false; 

    address keeper; 
    address strategist;

    IERC20 public lpGauge;
    IERC20[] public tokens;
    IERC20[] public rewardTokens;

    ICurveFi internal lpEntry;
    Gauge internal gauge;
    IUniswapV2Router01 router;
    address weth;

    mapping (IERC20 => address) public strategies; 

    constructor (
        address _lpEntry, 
        address _crvLp,
        uint256 _numTokens,
        address _gauge,
        address _router,
        address _rewardToken

    ) public {
        numTokens = _numTokens;
        lpEntry = ICurveFi(_lpEntry);
        for (uint256 i = 0; i < _numTokens; i++){

            IERC20 newToken = IERC20(lpEntry.underlying_coins(i));
            newToken.approve(_lpEntry, uint256(-1));
            tokens.push(newToken);

        }

        gauge = Gauge(_gauge);
        router = IUniswapV2Router01(_router);
        weth = router.WETH();
        rewardTokens.push(IERC20(_rewardToken));

        IERC20(_rewardToken).approve(_router, uint256(-1));
        lpGauge = IERC20(_crvLp);
        lpGauge.approve(_gauge, uint256(-1));


    }

    function setKeeper(address _keeper) external onlyAuthorized {
        require(_keeper != address(0));
        keeper = _keeper;
    }


    function initaliseStrategies(address[] memory _strategies) external onlyAuthorized {
        require(initialisedStrategies == false);
        initialisedStrategies = true;

        for (uint i = 0; i < numTokens; i++){
            IStrat strategy = IStrat(_strategies[i]);
            strategies[IERC20(strategy.want())] = address(strategy);
        }
    }

    function _isStrategy(address _strategy) internal view returns(bool) {
        bool isStrategy = false;
        for (uint256 i = 0; i < numTokens; i++){
            if (_strategy == strategies[tokens[i]]){
                isStrategy = true;
            }
        }
        return (isStrategy);
    } 

    // modifiers
    modifier onlyStrategies() {
        require(_isStrategy(msg.sender));
        _;
    }

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    modifier onlyKeepers() {
        _onlyKeepers();
        _;
    }

    function _onlyAuthorized() internal {
        require(msg.sender == strategist || msg.sender == owner());
    }

    function _onlyKeepers() internal {
        require(
            msg.sender == keeper ||
                msg.sender == owner()

        );
    }

    // 
    function addToJoint() external onlyStrategies {
        // proportion of want in LP that is pulled as when we add we do so prporitionally from each strategy 
        // initialise to uint(-1) so we can take min while looping through tokens 
        uint256 lpBalancePull = uint256(-1);
        uint256 amountInLp;
        uint256 wantAmount; 
        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = lpEntry.balances(i);
            wantAmount = IStrat(strategies[tokens[i]]).wantAvailable();
            lpBalancePull = Math.min(lpBalancePull, wantAmount.mul(BASIS_PRECISION).div(amountInLp));
        }

        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = lpEntry.balances(i);
            wantAmount = Math.min(IStrat(strategies[tokens[i]]).wantAvailable(), amountInLp.mul(lpBalancePull).div(BASIS_PRECISION));
            IStrat(strategies[tokens[i]]).provideWant(wantAmount);
        }

        _depositLp();
        _depositToFarm();


    }

    function debtOutstanding(address _token) public view returns(uint256) {
        address strategy = strategies[IERC20(_token)];
        return(IStrat(strategy).debtJoint());
    }

    // calculates the Profit / Loss by comparing balances of each token vs amount of Debt 
    function calculateProfit(address _token) public view returns(uint256 _loss, uint256 _profit) {

        uint256[3] memory amountsOut;

        for (uint256 i = 0; i < numTokens; i++){
            amountsOut[i] = debtOutstanding(address(tokens[i]));
        }

        uint256 lpOut = lpEntry.calc_token_amount(amountsOut, true);
        uint256 lpAmt = lpBalance();

        if (lpOut > lpAmt) {
            _profit = (debtOutstanding(_token).mul(lpOut).div(lpAmt)).sub(debtOutstanding(_token));
            _loss = 0;
        } else {
            _profit = 0;
            _loss = debtOutstanding(_token).sub(debtOutstanding(_token).mul(lpOut).div(lpAmt));
        }

    }

    function lpBalance() public view returns(uint256){
        // Amount of LP deposited 
        uint256 lpAmt = lpGauge.balanceOf(address(this));
        return(gauge.balanceOf(address(this)).add(lpAmt));

    }

    function _depositLp() internal {
        uint256[3] memory amountsIn;
        uint256 lpOut; 

        for (uint256 i = 0; i < numTokens; i++){
            amountsIn[i] = tokens[i].balanceOf(address(this));
        }

        lpOut = lpEntry.calc_token_amount(amountsIn, false);
        
        if (lpOut > 0){
            lpEntry.add_liquidity(amountsIn, lpOut.mul(slippageAdj).div(BASIS_PRECISION), true);      
        }
    }

    function _depositToFarm() internal {
        uint256 lpAmt = lpGauge.balanceOf(address(this));
        if(lpAmt > 0) { 
            gauge.deposit(lpAmt);
        }

    }

    function _withdrawFromFarm(uint256 _amount) internal {
        if (_amount > 0){
            uint256 _lpUnpooled = lpGauge.balanceOf(address(this));
            if (_amount > _lpUnpooled){
                gauge.withdraw(_amount.sub(_lpUnpooled));
            }
            
        }
        
    }

    function withdraw(uint256 _debtProportion) external onlyStrategies {
        _withdrawLp(_debtProportion);
        for (uint256 i = 0; i < numTokens; i++){
            address strategy = strategies[tokens[i]];
            tokens[i].transfer(strategy, tokens[i].balanceOf(address(this)));
            IStrat(strategy).adjustJointDebtOnWithdraw(_debtProportion);
        }

    }

    function _withdrawLp(uint256 _debtProportion) internal {
        
        uint256 lpOut = lpBalance().mul(_debtProportion).div(BASIS_PRECISION);
        _withdrawFromFarm(lpOut);
        uint256[3] memory amountsOut;

        for (uint256 i = 0; i < numTokens; i++){
            amountsOut[i] = debtOutstanding(address(tokens[i])).mul(slippageAdj).div(BASIS_PRECISION);
        }

        
        uint256 lpRequired = lpEntry.calc_token_amount(amountsOut, true);
        // calculated if in loss or not 
        if (lpRequired < lpOut) { 
            lpEntry.remove_liquidity_imbalance(amountsOut, lpOut, true);
            
        } else {
            // update amount Out to account for slippage 
            for (uint256 i = 0; i < numTokens; i++){
                amountsOut[i] = amountsOut[i].mul(lpOut).mul(slippageAdj).div(lpRequired).div(BASIS_PRECISION);
            }

            lpEntry.remove_liquidity_imbalance(amountsOut, lpOut, true);
        }
        

    }

    function harvestRewards() external onlyKeepers {
        _harvestInternal();
    }

    function _harvestInternal() internal {
        //gauge.claim_rewards();

        
        for (uint256 i = 0; i < rewardTokens.length; i++){
            uint256 farmAmount = rewardTokens[i].balanceOf(address(this));
            _sellRewardTokens(rewardTokens[i],farmAmount);
        }

    }

    // this sells reward tokenss in proportion to their debt & automatically sends proceeds to relevant strategy 
    function _sellRewardTokens(IERC20 rewardToken, uint256 farmAmount) internal {

        //uint256 farmAmount = rewardToken.balanceOf(address(this));
        

        for (uint256 i = 0; i < numTokens; i++){
            uint256 balance = rewardToken.balanceOf(address(this));
            address strategyTo = strategies[tokens[i]];
            uint256 saleAmount = farmAmount.mul(getDebtProportion(address(tokens[i]))).div(BASIS_PRECISION);
            router.swapExactTokensForTokens(
                Math.min(saleAmount,balance),
                0,
                getTokenOutPath(address(rewardToken), address(tokens[i])),
                address(this),
                now
            );
        }



    }

    function getDebtProportion(address _token) public view returns(uint256) {

        uint256 debtAdj;
        uint256 debtToken;
        uint256 debtAdjTotal;
        for (uint256 i = 0; i < numTokens; i++){
            uint256 decimalAdj = 10 ** ((uint256(ERC20(address(tokens[i])).decimals()).sub(4)));
            debtAdj = debtOutstanding(address(tokens[i])).div(decimalAdj);
            debtAdjTotal = debtAdjTotal.add(debtAdj); 
            if (_token == address(tokens[i])) { 
                debtToken = debtAdj;
            }
        }

        return(debtAdj.mul(BASIS_PRECISION).div(debtAdjTotal));
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


}