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

import "./interfaces/balancerv2.sol";
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
}

/// @title Manages LP from two provider strats
/// @author Robovault
/// @notice This contract takes tokens from two provider strats creates LP and manages the position 
/// @dev Design to interact with two strategies from single asset vaults 


contract jointLPHolderBalancer is Ownable {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    
    /// @notice Do we check oracle price vs lp price when rebalancing / withdrawing
    // helps avoid sandwhich attacks
    bool public doPriceCheck = true;
    uint256 internal numTokens = 2;
    uint256 public slippageAdj = 9990; // 99.9%
    uint256 constant BASIS_PRECISION = 10000;
    uint256 constant TOKEN_WEIGHT_PRECISION = 1000000000000000000;
    uint256 public rebalancePercent = 10000;
    /// @notice to make sure we don't try to do tiny rebalances with insufficient swap amount when withdrawing have some buffer 
    uint256 bpsRebalanceDiff = 50;
    // @we rebalance if debt ratio for either assets goes above this ratio 
    uint256 debtUpper = 10250;
    // @max difference between LP & oracle prices to complete rebalance / withdraw 
    uint256 public priceSourceDiff = 500; // 5% Default
    bool public initialisedStrategies = false; 

    address keeper; 
    address strategist;

    bytes32 public balancerPoolId;
    IBalancerVault internal balancerVault = IBalancerVault(0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce);
    IBalancerPool internal lp;
    IAsset[] internal assets;


    IERC20[] public tokens;
    IERC20[] public rewardTokens;

    IMasterChefv2 farm;
    IUniswapV2Router01 router;
    address weth;
    uint256 farmPid;
    uint256 minOut;

    mapping (IERC20 => address) public strategies; 
    mapping (IERC20 => uint256) public tokenWeights; 


    constructor (
        address _lp, 
        address _farm,
        uint256 _pid,
        address _rewardToken,
        address _router,
        uint256 _minOut

    ) public {
        lp = IBalancerPool(_lp);

        balancerPoolId = lp.getPoolId();
        lp.approve(address(balancerVault), uint256(-1));
        (IERC20[] memory poolTokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        assets = new IAsset[](numTokens);
        uint256[] memory weights = lp.getNormalizedWeights();

        for (uint256 i = 0; i < numTokens; i++){
            tokens.push(IERC20(poolTokens[i]));
            tokens[i].approve(address(balancerVault), uint256(-1));
            assets[i] = IAsset(address(tokens[i]));
            tokenWeights[tokens[i]] = weights[i];
        }
        
        farmPid = _pid;
        farm = IMasterChefv2(_farm);
        router = IUniswapV2Router01(_router);
        weth = router.WETH();
        rewardTokens.push(IERC20(_rewardToken));
        IERC20(_rewardToken).approve(_router, uint256(-1));
        lp.approve(_farm, uint256(-1));
        minOut = _minOut;
        
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
            lpBalancePull = Math.min(lpBalancePull, wantAmount.mul(BASIS_PRECISION).div(amountInLp));
        }

        for (uint256 i = 0; i < numTokens; i++){
            amountInLp = getLpReserves(i);
            wantAmount = Math.min(IStrat(strategies[tokens[i]]).wantAvailable(), amountInLp.mul(lpBalancePull).div(BASIS_PRECISION));
            IStrat(strategies[tokens[i]]).provideWant(wantAmount);
        }

        _joinPool(lpBalancePull.mul(slippageAdj).div(BASIS_PRECISION));
        //_depositToFarm();


    }


    function getLpReserves(uint256 _index) public view returns (uint256 _amount){
        (IERC20[] memory tokens, uint256[] memory totalBalances, uint256 lastChangeBlock) = balancerVault.getPoolTokens(balancerPoolId);
        return totalBalances[_index];
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
        uint256 lpRemovePercent;
        uint256 debtRatio0 = calcDebtRatioToken(0);
        uint256 debtRatio1 = calcDebtRatioToken(1);

        uint256 tokenWeight0 = tokenWeights[tokens[0]];
        uint256 tokenWeight1 = tokenWeights[tokens[1]];

        if (debtRatio0 > debtRatio1.add(bpsRebalanceDiff)) {
            lpRemovePercent = (debtRatio0.sub(debtRatio1)).mul(TOKEN_WEIGHT_PRECISION).div(tokenWeight0).mul(_rebalancePercent).div(BASIS_PRECISION);
            _withdrawLp(lpRemovePercent);
            uint256 _lpOut = lpRemovePercent.mul(lpBalance()).div(BASIS_PRECISION);
            _removeLpRebalance(_lpOut, 1);
        }

        if (debtRatio1 > debtRatio0.add(bpsRebalanceDiff)) {
            lpRemovePercent = (debtRatio1.sub(debtRatio0)).mul(TOKEN_WEIGHT_PRECISION).div(tokenWeight1).mul(_rebalancePercent).div(BASIS_PRECISION);
            _withdrawLp(lpRemovePercent);
            uint256 _lpOut = lpRemovePercent.mul(lpBalance()).div(BASIS_PRECISION);
            _removeLpRebalance(_lpOut, 0);
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
        tokens[1].transfer(strategy0, bal1);

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

        if (address(tokens[0]) == _token) {
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
        uint256 weight0 = tokenWeights[tokens[0]];
        uint256 weight1 = tokenWeights[tokens[1]];

        if (_tokenA == address(tokens[0])) { 
            return(_amountIn.mul(token1Amt).div(token0Amt).mul(weight0).div(weight1));
        } else {
            return(_amountIn.mul(token0Amt).div(token1Amt).mul(weight1).div(weight0));
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


    function countLpPooled() public view returns (uint256) {
        (uint256 _amount, ) = farm.userInfo(farmPid, address(this));
        return _amount;
    }

    // join pool given exact token in
    function _joinPool(uint256 _expectedBptOut) internal {
        uint256[] memory maxAmountsIn = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++){
            maxAmountsIn[i] = tokens[i].balanceOf(address(this));

        }

        bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, _expectedBptOut);
        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
        balancerVault.joinPool(balancerPoolId, address(this), address(this), request);
        
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
        _removeAllLp(_debtProportion, lpOut);
    }

    function _removeAllLp(uint256 _debtProportion, uint256 _lpOut) internal {
        uint256[] memory amountsOut = new uint256[](numTokens);
        uint256[] memory minAmountsOut = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++){
            amountsOut[i] = debtOutstanding(address(tokens[i])).mul(_debtProportion).div(BASIS_PRECISION).mul(slippageAdj).div(BASIS_PRECISION);
            minAmountsOut[i] = amountsOut[i].mul(minOut).div(BASIS_PRECISION);
        }

        bytes memory userData = abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, _lpOut);
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
        balancerVault.exitPool(balancerPoolId, address(this), address(this), request);
    }


    function _removeLpRebalance(uint256 _lpOut, uint256 _tokenIndex) internal {
        uint256[] memory amountsOut = new uint256[](numTokens);
        uint256[] memory minAmountsOut = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++){
            if (i == _tokenIndex){
                uint256 wantInLp = getLpReserves(i);
                uint256 lpSupply = lp.totalSupply();
                amountsOut[i] = wantInLp.mul(_lpOut).div(lpSupply).mul(TOKEN_WEIGHT_PRECISION).div(tokenWeights[tokens[i]]);
                minAmountsOut[i] = amountsOut[i].mul(minOut).div(BASIS_PRECISION);
            }
        }

        bytes memory userData = abi.encode(IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT, amountsOut, _lpOut);
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
        balancerVault.exitPool(balancerPoolId, address(this), address(this), request);
    }



    function harvestRewards() external onlyKeepers {
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

    receive() external payable {}

}