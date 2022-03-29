import brownie
from brownie import interface, Contract, accounts
import pytest
import time 
import eth_abi


def test_operation(
    chain, accounts, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
):
    # Deposit to the vault
    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
    
        assert token.balanceOf(vault.address) == amount
        
        # harvest
    chain.sleep(5)
    chain.mine(5)

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        strategy.harvest()
        strat = strategy
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        user_balance_before = token.balanceOf(user)
        withdrawPct = 1
        amount = amounts[i]
        withdrawAmt = int(withdrawPct * amount)
        strategy = strategies[i]
        chain.sleep(5)
        chain.mine(5)
        vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 
        assert (pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before + withdrawAmt)


def test_reduce_debt(
    chain, accounts, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
):
    # Deposit to the vault
    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
        assert token.balanceOf(vault.address) == amount
        
        # harvest
    chain.sleep(5)
    chain.mine(5)

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        strategy.harvest()
        strat = strategy
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        user_balance_before = token.balanceOf(user)
        withdrawPct = 1
        amount = amounts[i]
        withdrawAmt = int(withdrawPct * amount)
        strategy = strategies[i]
        chain.sleep(5)
        chain.mine(5)
        vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
        chain.sleep(5)
        chain.mine(5)
        #chain.mine(1)

        strategy.harvest()
        assert pytest.approx(token.balanceOf(vault), rel=RELATIVE_APPROX) == amount



"""

def test_emergency_exit(
    chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(5)
    chain.mine(5)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(5)
    chain.mine(5)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero
    assert pytest.approx(token.balanceOf(vault), rel=RELATIVE_APPROX) == amount
"""

def test_profitable_harvest(
    chain, accounts, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
):
    # Deposit to the vault
    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
        assert token.balanceOf(vault.address) == amount
        
        # harvest
    chain.sleep(5)
    chain.mine(5)
    before_pps = []

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        strategy.harvest()
        strat = strategy
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
        before_pps += [vault.pricePerShare()]

    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0


    harvest = interface.ERC20(conf['harvest_tokens'][0])
    harvestWhale = accounts.at('0xa48d959AE2E88f1dAA7D5F611E01908106dE7598', True)
    sendAmount = 100 * 1e18
    for t in range(1) :
        harvest.transfer(jointLP, sendAmount, {'from': harvestWhale})
        chain.sleep(1)
        chain.mine(1)
        jointLP.harvestRewards({'from' : gov})
        for i in range(len(tokens)) :
            strategy = strategies[i]
            strategy.harvest()
            chain.sleep(500)
            chain.mine(1)


    for i in range(len(tokens)) : 
        vault = vaults[i]
        assert vault.pricePerShare() > before_pps[i]



def test_increase_debt_50_100(
    chain, accounts, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
):
    # Deposit to the vault
    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
        vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})

    chain.sleep(5)
    chain.mine(5)

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        strategy = strategies[i]
        amount = amounts[i]
        strategy.harvest()
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount*.5
        
    chain.sleep(5)
    chain.mine(5)
    #assert False

    for i in range(len(tokens)) : 
        token = tokens[i]
        vault = vaults[i]
        user_balance_before = token.balanceOf(user)
        withdrawPct = 1
        amount = amounts[i]
        withdrawAmt = int(withdrawPct * amount)
        strategy = strategies[i]
        chain.sleep(5)
        chain.mine(5)
        vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
        chain.sleep(5)
        chain.mine(5)
        #chain.mine(1)

        strategy.harvest()
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount


