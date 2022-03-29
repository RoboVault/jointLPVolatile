pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;


import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/balancerv2.sol";

contract PriceOffsetter {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 public want;
    IERC20 public short;

    bytes32 public balancerPoolId;
    uint8 constant numTokens = 2;
    uint8 public tokenIndexWant;
    uint8 public tokenIndexShort;
    uint256 constant slippageAdj = 2000;
    uint256 public poolWeightWant;

    uint256 constant BASIS_PRECISION = 10000;

    IBalancerVault internal balancerVault;
    IBalancerPool internal wantShortLP;
    IAsset[] internal assets;

    constructor(
        address _want,
        address _short, 
        address _wantShortLp,
        address _balancerVault,
        uint256 _poolWeightWant

    )
        public
    {
        // config = _config;
        // initialise token interfaces
        want = IERC20(_want);
        short = IERC20(_short);
        wantShortLP = IBalancerPool(_wantShortLp);
        balancerPoolId = wantShortLP.getPoolId();

        balancerVault = IBalancerVault(_balancerVault);
        poolWeightWant = _poolWeightWant;

        approveContracts();

        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);


        assets = new IAsset[](numTokens);

        tokenIndexWant = type(uint8).max;
        tokenIndexShort = type(uint8).max;


        for (uint8 i = 0; i < numTokens; i++) {
            if (tokens[i] == want) {
                tokenIndexWant = i;
            }
            if (tokens[i] == short) {
                tokenIndexShort = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }


    }

    function approveContracts() internal {
        want.safeApprove(address(balancerVault), uint256(-1));
        short.safeApprove(address(balancerVault), uint256(-1));
    }

    function totalTokenInLp(address _token) public view returns (uint256 _amount){
        uint256 bal;
        (IERC20[] memory tokens, uint256[] memory totalBalances, uint256 lastChangeBlock) = balancerVault.getPoolTokens(balancerPoolId);
        for (uint8 i = 0; i < numTokens; i++) {
            uint256 tokenPooled = totalBalances[i];
            if (tokenPooled > 0) {
                IERC20 token = tokens[i];
                if (address(token) == _token) {
                    bal += tokenPooled;
                }
            }
        }
        return bal;
    }


    function addToLp() external {
        //uint256 _amountWant = convertViaLpPrice(_amountShort.mul(poolWeightWant).div(BASIS_PRECISION.sub(poolWeightWant)), address(want));
        uint256 balWant = want.balanceOf(address(this));
        uint256 balShort = short.balanceOf(address(this));
        _joinPool(balWant, balShort);
    }

    // join pool given exact token in
    function _joinPool(uint256 _amountInWant, uint256 _amountInShort) internal {
        uint256[] memory maxAmountsIn = new uint256[](numTokens);
        uint256 expectedBptOutWant = wantShortLP.totalSupply().mul(_amountInWant).mul(slippageAdj).div(totalTokenInLp(address(want))).div(BASIS_PRECISION).mul(poolWeightWant).div(BASIS_PRECISION);
        uint256 expectedBptOutShort = wantShortLP.totalSupply().mul(_amountInShort).mul(slippageAdj).div(totalTokenInLp(address(short))).div(BASIS_PRECISION).mul(BASIS_PRECISION.sub(poolWeightWant)).div(BASIS_PRECISION);
        maxAmountsIn[tokenIndexWant] = _amountInWant;
        maxAmountsIn[tokenIndexShort] = _amountInShort;
        bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, expectedBptOutWant.add(expectedBptOutShort));
        IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
        balancerVault.joinPool(balancerPoolId, address(this), address(this), request);
        
    }


}

