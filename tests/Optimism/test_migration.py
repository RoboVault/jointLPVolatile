import brownie
from brownie import interface, Contract, accounts
import pytest
import time 

ZIP_ROUTER = '0xE6Df0BB08e5A97b40B21950a0A51b94c4DbA0Ff6'

def test_migration(
    chain,
    tokens,
    vaults,
    strategies,
    amounts,
    strategy_contract,
    jointLP_contract,
    aTokens,
    conf,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
):
    # Deposit to the vault and harvest
    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
        chain.sleep(5)
        chain.mine(5)
        strategy.harvest()
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    farmToken = conf['harvest_tokens'][0]
    
    newJointLP = jointLP_contract.deploy(conf['LP'], conf['farm'] , conf['farmPID'], conf['router'], farmToken, {'from' : gov})

    newStrategies = []

    for i in range(len(tokens)) : 
        token = tokens[i]
        aToken = aTokens[i]
        vault = vaults[i]
        newStrategy = strategy_contract.deploy(vault, newJointLP, aToken, conf['comptroller'],ZIP_ROUTER, conf['compToken'], {"from": strategist} )        
        newStrategies = newStrategies + [newStrategy]

    newJointLP.initaliseStrategies(newStrategies, {"from": gov})
    
    chain.sleep(1)
    chain.mine(1)

    for i in range(len(tokens)) : 
        strategy = strategies[i]
        newStrategy = newStrategies[i]
        vault = vaults[i]
        vault.migrateStrategy(strategy, newStrategy, {"from": gov})
        amount = amounts[i]
        assert (pytest.approx(newStrategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)  == amount )


