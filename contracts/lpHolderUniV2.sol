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


import "./interfaces/uniswap.sol";
import "./interfaces/farm.sol";


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

contract jointLPHolderUniV2 is Ownable {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 internal numTokens = 2;
    uint256 public slippageAdj = 9900; // 99%
    uint256 constant BASIS_PRECISION = 10000;
    uint256 public rebalancePercent = 10000;
    uint256 bpsRebalanceDiff = 50;
    uint256 debtUpper = 10250;
    bool public initialisedStrategies = false; 

    address keeper; 
    address strategist;

    IUniswapV2Pair public lp;
    IERC20[] public tokens;
    IERC20[] public rewardTokens;

    IFarmMasterChef farm;
    IUniswapV2Router01 router;
    address weth;
    uint256 farmPid;

    mapping (IERC20 => address) public strategies; 

    constructor (
        address _lp, 
        address _farm,
        uint256 _pid,
        address _router,
        address _rewardToken

    ) public {
        lp = IUniswapV2Pair(_lp);
        IERC20(address(lp)).safeApprove(_router, uint256(-1));

        farmPid = _pid;
        IERC20 newToken0 = IERC20(lp.token0());
        newToken0.approve(_router, uint256(-1));
        tokens.push(newToken0);

        IERC20 newToken1 = IERC20(lp.token1());
        newToken1.approve(_router, uint256(-1));
        tokens.push(newToken1);

        farm = IFarmMasterChef(_farm);
        router = IUniswapV2Router01(_router);
        weth = router.WETH();
        rewardTokens.push(IERC20(_rewardToken));

        IERC20(_rewardToken).approve(_router, uint256(-1));
        lp.approve(_farm, uint256(-1));


    }

    function setStrategist(address _strategist) external onlyAuthorized {
        require(_strategist != address(0));
        strategist = _strategist;
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

    function _onlyStrategist() internal {
        require(msg.sender == strategist);
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
            msg.sender == strategist ||
            msg.sender == owner()

        );
    }

    function setParamaters(uint256 _slippageAdj, uint256 _bpsRebalanceDiff, uint256 _rebalancePercent, uint256 _debtUpper) external onlyAuthorized {
        slippageAdj = _slippageAdj;
        bpsRebalanceDiff = _bpsRebalanceDiff;
        rebalancePercent = _rebalancePercent;
        debtUpper = _debtUpper;
    }

    function removeFromFarmAuth() external onlyAuthorized {
        farm.withdraw(farmPid, countLpPooled());
    }

    // called in emergency to pull all funds from LP and send tokens back to provider strats
    function withdrawAllFromJoint() external onlyAuthorized {
        uint256 _debtProportion = BASIS_PRECISION;
        _rebalanceDebtInternal(_debtProportion);
        _withdrawLp(_debtProportion);
        for (uint256 i = 0; i < numTokens; i++){
            address strategy = strategies[tokens[i]];
            tokens[i].transfer(strategy, tokens[i].balanceOf(address(this)));
            IStrat(strategy).adjustJointDebtOnWithdraw(_debtProportion);
        }
    }

    // called in emergency to pull all funds from LP and send tokens back to provider strats while not rebalancing
    function withdrawAllFromJointNoRebalance() external onlyAuthorized {

        _withdrawLp(BASIS_PRECISION);
        for (uint256 i = 0; i < numTokens; i++){
            address strategy = strategies[tokens[i]];
            tokens[i].transfer(strategy, tokens[i].balanceOf(address(this)));
            IStrat(strategy).adjustJointDebtOnWithdraw(BASIS_PRECISION);
        }
    }


    // 
    function addToJoint() external onlyStrategies {
        // proportion of want in LP that is pulled as when we add we do so prporitionally from each strategy 
        // initialise to uint(-1) so we can take min while looping through tokens 
        uint256 lpBalancePull = uint256(-1);
        uint256 amountInLp;
        uint256 wantAmount; 
        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = getLpReserves(i);
            wantAmount = IStrat(strategies[tokens[i]]).wantAvailable();
            lpBalancePull = Math.min(lpBalancePull, wantAmount.mul(BASIS_PRECISION).div(amountInLp));
        }

        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = getLpReserves(i);
            wantAmount = Math.min(IStrat(strategies[tokens[i]]).wantAvailable(), amountInLp.mul(lpBalancePull).div(BASIS_PRECISION));
            IStrat(strategies[tokens[i]]).provideWant(wantAmount);
        }

        _depositLp();
        //_depositToFarm();


    }

    function rebalanceDebt() external onlyKeepers {
        //require(_testPriceSource());
        require(calcDebtRatio(0) > debtUpper || calcDebtRatio(1) > debtUpper);
        _rebalanceDebtInternal(rebalancePercent);
        _adjustDebtOnRebalance();

    }

    function _rebalanceDebtInternal(uint256 _rebalancePercent) internal {
        // this will be the % of balance for either short A or short B swapped 
        uint256 swapAmt;
        uint256 lpRemovePercent;
        uint256 debtRatio0 = calcDebtRatio(0);
        uint256 debtRatio1 = calcDebtRatio(1);


        // note we add some noise to check there is big enough difference between the debt ratios (0.5%) as we also call this during liquidate Position All
        if (debtRatio0 > debtRatio1.add(bpsRebalanceDiff)) {
            lpRemovePercent = (debtRatio0.sub(debtRatio1)).div(2).mul(_rebalancePercent).div(BASIS_PRECISION);
            _withdrawLp(lpRemovePercent);
            swapExactFromTo(address(tokens[1]), address(tokens[0]), tokens[1].balanceOf(address(this)));
        }

        if (debtRatio1 > debtRatio0.add(bpsRebalanceDiff)) {
            lpRemovePercent = (debtRatio1.sub(debtRatio0)).div(2).mul(_rebalancePercent).div(BASIS_PRECISION);
            _withdrawLp(lpRemovePercent);
            swapExactFromTo(address(tokens[0]), address(tokens[1]), tokens[0].balanceOf(address(this)));
        }

    }

    function _adjustDebtOnRebalance() internal {
        uint256 bal0 = tokens[0].balanceOf(address(this));
        uint256 bal1 = tokens[1].balanceOf(address(this));
        address strategy0 = strategies[tokens[0]];
        address strategy1 = strategies[tokens[1]];

        tokens[0].transfer(strategy0, bal0);
        tokens[1].transfer(strategy0, bal1);

        IStrat(strategy0).adjustJointDebtOnWithdraw(bal0.mul(BASIS_PRECISION).div(debtOutstanding(address(tokens[0]))));
        IStrat(strategy1).adjustJointDebtOnWithdraw(bal1.mul(BASIS_PRECISION).div(debtOutstanding(address(tokens[1]))));

    }

    function debtOutstanding(address _token) public view returns(uint256) {
        address strategy = strategies[IERC20(_token)];
        return(IStrat(strategy).debtJoint());
    }

    // calculates the Profit / Loss by comparing balances of each token vs amount of Debt 
    function calculateProfit(address _token) public view returns(uint256 _loss, uint256 _profit) {

        uint256 debt = debtOutstanding(_token);
        uint256 tokenIndex;

        if (lp.token0() == _token) {
            tokenIndex = 0;
        } else {
            tokenIndex = 1;
        }


        uint256 balance = balanceTokenWithRebalance(tokenIndex);

        if (balance >= debt) {
            _profit = balance.sub(debt);
            _loss = 0;
        } else {
            _profit = 0;
            _loss = debt.sub(balance);
        }

    }

    function calcDebtRatio(uint256 _tokenIndex) public view returns(uint256) {
        return(debtOutstanding(address(tokens[_tokenIndex])).mul(BASIS_PRECISION).div(balanceToken(_tokenIndex))); 
    }

    function balanceToken(uint256 _tokenIndex) public view returns(uint256) {
        uint256 lpAmount = getLpReserves(_tokenIndex);
        uint256 tokenBalance = lpBalance().mul(lpAmount).div(lp.totalSupply());
        return(tokenBalance);
    }

    function balanceTokenWithRebalance(uint256 _tokenIndex) public view returns(uint256) {
        uint256 lpAmount = getLpReserves(_tokenIndex);
        uint256 tokenBalance = lpBalance().mul(lpAmount).div(lp.totalSupply());

        uint256 debtRatio0 = calcDebtRatio(0);
        uint256 debtRatio1 = calcDebtRatio(1);

        uint256 amtSub0;
        uint256 amtSub1; 
        uint256 amtIn0;
        uint256 amtIn1;

        if (debtRatio0 > debtRatio1) {
            amtSub1 = balanceToken(1).mul(debtRatio0.sub(debtRatio1)).div(BASIS_PRECISION).div(2); 
            amtIn0 = convertAtoB(address(tokens[1]), address(tokens[0]), amtSub1);

        } else {
            uint256 amtSub0 = balanceToken(0).mul(debtRatio1.sub(debtRatio0)).div(BASIS_PRECISION).div(2); 
            uint256 amtIn1 = convertAtoB(address(tokens[0]), address(tokens[1]), amtSub0);
        }

        if (_tokenIndex == 0) {
            return(tokenBalance.add(amtIn0).sub(amtSub0));
        } else {
            return(tokenBalance.add(amtIn1).sub(amtSub1));
        }

    }


    function lpBalance() public view returns(uint256){
        return(lp.balanceOf(address(this)).add(countLpPooled()));
    }

    function convertAtoB(address _tokenA, address _tokenB, uint256 _amountIn) 
        internal
        view
        returns (uint256 _amountOut)
    {
        uint256 token0Amt = getLpReserves(0);
        uint256 token1Amt = getLpReserves(1);

        if (_tokenA == address(tokens[0])) { 
            return(_amountIn.mul(token1Amt).div(token0Amt));
        } else {
            return(_amountIn.mul(token0Amt).div(token1Amt));
        }
    }

    function getLpReserves(uint256 _index)
        public
        view
        returns (uint256 _balance)
    {
        (uint112 reserves0, uint112 reserves1, ) = lp.getReserves();
        if (_index == 0) { 
            return(uint256(reserves0));
        } else {
            return(uint256(reserves1));
        }
    }

    function countLpPooled() public view returns (uint256) {
        return farm.userInfo(farmPid, address(this)).amount;
    }

    function _depositLp() internal {

        uint256 _amount0 = tokens[0].balanceOf(address(this));
        uint256 _amount1 = tokens[1].balanceOf(address(this));
        if (_amount0 >0 && _amount1 >0){

            router.addLiquidity(
                address(tokens[0]),
                address(tokens[1]),
                _amount0,
                _amount1,
                _amount0.mul(slippageAdj).div(BASIS_PRECISION),
                _amount1.mul(slippageAdj).div(BASIS_PRECISION),
                address(this),
                now
            );

        }


    }

    function _depositToFarm() internal {
        uint256 lpAmt = lp.balanceOf(address(this));
        if(lpAmt > 0) { 
            farm.deposit(farmPid, lpAmt); /// deposit LP tokens to farm
        }

    }

    function _withdrawFromFarm(uint256 _amount) internal {
        if (_amount > 0){
            uint256 _lpUnpooled = lp.balanceOf(address(this));
            if (_amount > _lpUnpooled){
                farm.withdraw(farmPid, _amount.sub(_lpUnpooled));
            }
            
        }
        
    }

    function withdraw(uint256 _debtProportion) external onlyStrategies {
        _rebalanceDebtInternal(_debtProportion);
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
        _removeAllLp(lpOut);
    }

    function _removeAllLp(uint256 _amount) internal {
        uint256 amount0 = getLpReserves(0);
        uint256 amount1 = getLpReserves(1);

        uint256 lpIssued = lp.totalSupply();

        uint256 amount0Min =
            _amount.mul(amount0).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        uint256 amount1Min =
            _amount.mul(amount1).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        router.removeLiquidity(
            address(tokens[0]),
            address(tokens[1]),
            _amount,
            amount0Min,
            amount1Min,
            address(this),
            now
        );
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

    function swapExactFromTo(
        address _swapFrom,
        address _swapTo,
        uint256 _amountIn
    )   internal 
        returns (uint256 _slippage)
    {
        IERC20 fromToken = IERC20(_swapFrom);
        uint256 fromBalance = fromToken.balanceOf(address(this));
        uint256 expectedAmountOut = convertAtoB(_swapFrom, _swapTo, _amountIn);
        // do this to avoid small swaps that will fail
        if (fromBalance < 1 || expectedAmountOut < 1) return (0);
        uint256 minOut = 0;
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amountIn,
                minOut,
                getTokenOutPath(address(_swapFrom), address(_swapTo)),
                address(this),
                now
            );
        uint256 _slippage = expectedAmountOut.sub(amounts[amounts.length - 1]);        
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
            
            tokens[i].transfer(strategyTo, tokens[i].balanceOf(address(this)));
        }
    }

    function getDebtProportion(address _token) public view returns(uint256) {
        return((BASIS_PRECISION).div(2));
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