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
import "./interfaces/ipriceoracle.sol";


interface IMasterChefv2 {
    function harvest(uint256 pid, address to) external;

    function emergencyWithdraw(uint256 _pid) external;

    function withdraw(
        uint256 pid,
        uint256 amount,
        address to
    ) external;

    function deposit(
        uint256 pid,
        uint256 amount,
        address to
    ) external;

    function lqdrPerBlock() external view returns (uint256);

    function lpToken(uint256 pid) external view returns (address);

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (uint256, uint256);

}

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
    function getOraclePrice() external view returns (uint256);
    function isInProfit() external view returns(bool);
    function estimatedTotalAssets() external view returns(uint256); 
}

/// @title Manages LP from two provider strats
/// @author Robovault
/// @notice This contract takes tokens from two provider strats creates LP and manages the position 
/// @dev Design to interact with two strategies from single asset vaults 


contract jointLPHolderUniV2 is Ownable {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    
    /// @notice Do we check oracle price vs lp price when rebalancing / withdrawing
    // helps avoid sandwhich attacks
    bool public doPriceCheck = true;
    uint256 internal numTokens = 2;
    uint256 public slippageAdj = 9900; // 99%
    uint256 constant BASIS_PRECISION = 10000;
    uint256 constant STD_PRECISION = 1e12;
    uint256 public rebalancePercent = 10000;
    /// @notice to make sure we don't try to do tiny rebalances with insufficient swap amount when withdrawing have some buffer 
    uint256 bpsRebalanceDiff = 50;
    // @we rebalance if debt ratio for either assets goes above this ratio 
    uint256 debtUpper = 10250;
    uint256 public lastRewardSale; 
    // time between sales of reward token -> to avoid both providers calling within same time 
    uint256 public minRewardSaleTime = 3600;

    // @max difference between LP & oracle prices to complete rebalance / withdraw 
    uint256 public priceSourceDiff = 250; // 2.5% Default
    bool public initialisedStrategies = false; 

    address keeper; 
    address strategist;

    // this relative to STD_PRECISION so 1e14 is 1 / 1e4 
    uint256 lpDust = 1e4; 

    IUniswapV2Pair public lp;
    IERC20[] public tokens;
    IERC20[] public rewardTokens;

    IMasterChefv2 farm;
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
        lastRewardSale = block.timestamp;
        lp = IUniswapV2Pair(_lp);
        IERC20(address(lp)).safeApprove(_router, uint256(-1));

        farmPid = _pid;
        IERC20 newToken0 = IERC20(lp.token0());
        newToken0.approve(_router, uint256(-1));
        tokens.push(newToken0);

        IERC20 newToken1 = IERC20(lp.token1());
        newToken1.approve(_router, uint256(-1));
        tokens.push(newToken1);

        farm = IMasterChefv2(_farm);
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

    function setLpDust(uint256 _lpDust) external onlyAuthorized {
        lpDust = _lpDust;
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

    /// @notice for doing price check against oracle price + setting max difference 
    function setPriceSource(bool _doPriceCheck, uint256 _priceSourceDiff) external onlyAuthorized {
        doPriceCheck = _doPriceCheck;
        priceSourceDiff = _priceSourceDiff;

    }

    /// @notice set other paramaters used by jointLP 
    function setParamaters(uint256 _slippageAdj, uint256 _bpsRebalanceDiff, uint256 _rebalancePercent, uint256 _debtUpper) external onlyAuthorized {
        slippageAdj = _slippageAdj;
        bpsRebalanceDiff = _bpsRebalanceDiff;
        rebalancePercent = _rebalancePercent;
        debtUpper = _debtUpper;
    }

    /// @notice here we withdraw from farm 
    function removeFromFarmAuth() external onlyAuthorized {
        farm.emergencyWithdraw(farmPid);
    }

    /// @notice called in emergency to pull all funds from LP and send tokens back to provider strats
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

    /// @notice called in emergency to pull all funds from LP and send tokens back to provider strats while not rebalancing
    function withdrawAllFromJointNoRebalance() external onlyAuthorized {

        _withdrawLp(BASIS_PRECISION);
        for (uint256 i = 0; i < numTokens; i++){
            address strategy = strategies[tokens[i]];
            tokens[i].transfer(strategy, tokens[i].balanceOf(address(this)));
            IStrat(strategy).adjustJointDebtOnWithdraw(BASIS_PRECISION);
        }
    }


    /// @notice called by either of the provider strategies 
    /// pulls in want from both provider strategies to create LP and deposit to farm 
    function addToJoint() external onlyStrategies {
        // proportion of want in LP that is pulled as when we add we do so prporitionally from each strategy 
        // initialise to uint(-1) so we can take min while looping through tokens 
        uint256 lpBalancePull = uint256(-1);
        uint256 amountInLp;
        uint256 wantAmount; 
        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = getLpReserves(i);
            wantAmount = IStrat(strategies[tokens[i]]).wantAvailable();
            lpBalancePull = Math.min(lpBalancePull, wantAmount.mul(STD_PRECISION).div(amountInLp));
        }
        
        bool providerPercentLargerThanDust = lpBalancePull > lpDust;

        // here we make sure the % of want added from both strats is more than lpDust 
        if (providerPercentLargerThanDust) {
            _processWantFromProviders(lpBalancePull);
        }

        
    


    }

    function _processWantFromProviders(uint256 _lpBalancePull) internal {
        uint256 amountInLp;
        uint256 wantAmount; 

        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = getLpReserves(i);
            wantAmount = Math.min(IStrat(strategies[tokens[i]]).wantAvailable(), amountInLp.mul(_lpBalancePull).div(STD_PRECISION));
            IStrat(strategies[tokens[i]]).provideWant(wantAmount);
        }

        _depositLp();
        _depositToFarm();

    }

    /// @notice here we rebalance if prices have moved and pushed one of the debt ratios above debt upper 
    // we first check price difference of LP vs oracles to make sure no price maniupation
    // we then check debt ratio for one of the tokens is > debt upper 
    // we then call rebalance Debt Internal 
    // finally we send the rebalanced tokens back to the associated strategy & adjust it's JointDebt 
    function rebalanceDebt() external onlyKeepers {
        require(_testPriceSource());
        require(calcDebtRatioToken(0) > debtUpper || calcDebtRatioToken(1) > debtUpper);
        _rebalanceDebtInternal(rebalancePercent);
        _adjustDebtOnRebalance();

    }

    /// @notice checks LP price against oracle prices 
    function _testPriceSource() internal view returns (bool) {
        if (doPriceCheck){
            uint256 _amountIn = tokens[0].totalSupply();
            uint256 lpPrice = convertAtoB(address(tokens[0]), address(tokens[1]), _amountIn);
            uint256 oraclePrice = convertAtoBOracle(address(tokens[0]), address(tokens[1]), _amountIn);
            uint256 priceSourceRatio = lpPrice.mul(BASIS_PRECISION).div(oraclePrice);

            return (priceSourceRatio > BASIS_PRECISION.sub(priceSourceDiff) &&
                priceSourceRatio < BASIS_PRECISION.add(priceSourceDiff));
        }
        return true;
    }

    /// @notice rebalances the position to bring back to delta neutral position 
    // we first find the difference between the debt ratios 
    // we remove a portion of the LP equal to half of the difference of the debt ratios in LP (adjusted by rebalcne percent)
    // we then swap the asset which has the lower debt ratio for the asset with higher debt ratio 
    function _rebalanceDebtInternal(uint256 _rebalancePercent) internal {
        // this will be the % of balance for either short A or short B swapped 
        uint256 swapAmt;
        uint256 lpRemovePercent;
        uint256 debtRatio0 = calcDebtRatioToken(0);
        uint256 debtRatio1 = calcDebtRatioToken(1);


        //. @notice we add some noise to check there is big enough difference between the debt ratios (0.5%) as we also call this during liquidate Position All
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

    /// @notice after a rebalance, tokens in excess of LP are returned to the provider strategies 
    // we also adjust the jointDebt paramater which is essentially the debt from the provider strat to the joint LP holder 
    function _adjustDebtOnRebalance() internal {
        uint256 bal0 = tokens[0].balanceOf(address(this));
        uint256 bal1 = tokens[1].balanceOf(address(this));
        address strategy0 = strategies[tokens[0]];
        address strategy1 = strategies[tokens[1]];

        tokens[0].transfer(strategy0, bal0);
        tokens[1].transfer(strategy1, bal1);

        IStrat(strategy0).adjustJointDebtOnWithdraw(bal0.mul(BASIS_PRECISION).div(debtOutstanding(address(tokens[0]))));
        IStrat(strategy1).adjustJointDebtOnWithdraw(bal1.mul(BASIS_PRECISION).div(debtOutstanding(address(tokens[1]))));

    }

    /// @notice debt from provider strat to joint LP holder 
    function debtOutstanding(address _token) public view returns(uint256) {
        address strategy = strategies[IERC20(_token)];
        return(IStrat(strategy).debtJoint());
    }

    /// @notice calculates the Profit / Loss by comparing balances of each token vs amount of Debt 
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

    function calcDebtRatioToken(uint256 _tokenIndex) public view returns(uint256) {
        return(debtOutstanding(address(tokens[_tokenIndex])).mul(BASIS_PRECISION).div(balanceToken(_tokenIndex))); 
    }

    function calcDebtRatio() public view returns(uint256, uint256) {
        return(calcDebtRatioToken(0), calcDebtRatioToken(1));
    }

    /// @notice checks that both provider strategies are in profit 
    function allStratsInProfit() public view returns(bool) {
        return(IStrat(strategies[tokens[0]]).isInProfit() && IStrat(strategies[tokens[1]]).isInProfit());


    }

    function balanceToken(uint256 _tokenIndex) public view returns(uint256) {
        uint256 lpAmount = getLpReserves(_tokenIndex);
        uint256 tokenBalance = lpBalance().mul(lpAmount).div(lp.totalSupply());
        return(tokenBalance);
    }

    /// @notice here we calculate the balances of token if we rebalance 
    // this is because as prices in LP move one of the provider strat will be in profit while the other will be in loss
    // here we calculate if we rebalance what will the balances of each token be 
    function balanceTokenWithRebalance(uint256 _tokenIndex) public view returns(uint256) {

        uint256 tokenBalance0 = balanceToken(0);
        uint256 tokenBalance1 = balanceToken(1);
        uint256 debtRatio0 = calcDebtRatioToken(0);
        uint256 debtRatio1 = calcDebtRatioToken(1);

        uint256 swapPct;

        if (debtRatio0 > debtRatio1) {
            swapPct = (debtRatio0.sub(debtRatio1)).div(2);
            uint256 swapAmount = tokenBalance1.mul(swapPct).div(BASIS_PRECISION); 
            uint256 amountIn = convertAtoB(address(tokens[1]), address(tokens[0]), swapAmount);
            tokenBalance0 = tokenBalance0.add(amountIn);
            tokenBalance1 = tokenBalance1.sub(swapAmount);

        } else {
            swapPct = (debtRatio1.sub(debtRatio0)).div(2);
            uint256 swapAmount = tokenBalance0.mul(swapPct).div(BASIS_PRECISION); 
            uint256 amountIn = convertAtoB(address(tokens[0]), address(tokens[1]), swapAmount);
            tokenBalance0 = tokenBalance0.sub(swapAmount);
            tokenBalance1 = tokenBalance1.add(amountIn);
        }

        if (_tokenIndex == 0) {
            return(tokenBalance0);
        } else {
            return(tokenBalance1);
        }

    }

    // how much of the lP token do we hold 
    function lpBalance() public view returns(uint256){
        return(lp.balanceOf(address(this)).add(countLpPooled()));
    }

    /// @notice simple helper function to convert tokens based on LP price 
    function convertAtoB(address _tokenA, address _tokenB, uint256 _amountIn) 
        public
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
    // @notice simple helper function to convert tokens based on oracle prices 
    function convertAtoBOracle(address _tokenA, address _tokenB, uint256 _amountIn) 
        public
        view
        returns (uint256 _amountOut)
    {
        address StratA = strategies[IERC20(_tokenA)];
        address StratB = strategies[IERC20(_tokenB)];

        uint256 priceA = IStrat(StratA).getOraclePrice();
        uint256 priceB = IStrat(StratB).getOraclePrice();

        return(priceA.mul(_amountIn).div(priceB));
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
        (uint256 _amount, ) = farm.userInfo(farmPid, address(this));
        return _amount;
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
            farm.deposit(farmPid, lpAmt, address(this)); /// deposit LP tokens to farm
        }

    }

    function _withdrawFromFarm(uint256 _amount) internal {
        if (_amount > 0){
            uint256 _lpUnpooled = lp.balanceOf(address(this));
            if (_amount > _lpUnpooled){
                farm.withdraw(farmPid, _amount.sub(_lpUnpooled), address(this));
            }
            
        }
        
    }

    /// @notice each of the provider strategies can withdraw a proportion of the tokens they've provided 
    // here we first check prices for manipulation 
    // then we rebalance based on the portion being withdrawn this means each provider strat takes roughly the same P&L 
    // we then withdraw the required LP and return the required tokens to each provider strat & adjust the jointDebt paramater
    function withdraw(uint256 _debtProportion) external onlyStrategies {
        // when withdrawing small amounts transaction will potentially fail
        _debtProportion = Math.max(_debtProportion, 50);

        require(_testPriceSource());
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
        lastRewardSale = block.timestamp;
    }

    function canHarvestJoint() public view returns(bool) {
        uint256 timeSinceSale = block.timestamp.sub(lastRewardSale);
        return(timeSinceSale >= minRewardSaleTime && lpBalance() > 0);
    }

    function harvestFromProvider() external onlyStrategies {
        _harvestInternal();
    }

    function _harvestInternal() internal {
        //gauge.claim_rewards();
        farm.harvest(farmPid, address(this));
        
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