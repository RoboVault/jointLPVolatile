import brownie
from brownie import interface, Contract, accounts
import pytest
import time 


def getWhaleAddress(Contract, tokens) : 
    spookyRouter = '0xF491e7B69E4244ad4002BC14e878a34207E38c29'
    altRouterContract = Contract(spookyRouter)
    factory = Contract(altRouterContract.factory())
    whale = factory.getPair(tokens[0], tokens[1])
    return(whale)


def offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user):
    # use other AMM's LP to force some swaps 
    whale = getWhaleAddress(Contract, tokens)
    token = tokens[tokenIndex]
    
    swapAmt = swapPct*token.balanceOf(whale)
    assert swapAmt > 0
    token.transfer(priceOffsetter, swapAmt, {"from": whale})
    assert token.balanceOf(priceOffsetter) > 0
    priceOffsetter.addToLp({"from": user})
    assert token.balanceOf(priceOffsetter) == 0 
    
    lpAddress = priceOffsetter.wantShortLP()
    lp = Contract(lpAddress)
    assert lp.balanceOf(priceOffsetter) > 0


def test_rebalanceDebtA(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
) : 
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

    tokenIndex = 0
    swapPct = 0.03
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))
    # set price source to off
    jointLP.setPriceSource(False, 500, {'from' : gov})

    print('rebalance debt')
    jointLP.rebalanceDebt()

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))

def test_rebalanceDebtB(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
) : 
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

    tokenIndex = 1
    swapPct = 0.1
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))

    # set price source to off
    jointLP.setPriceSource(False, 500, {'from' : gov})

    print('rebalance debt')
    jointLP.rebalanceDebt()

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))



def test_operation_offsetA(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
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

    tokenIndex = 0
    swapPct = 0.02
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    # set price source to off
    jointLP.setPriceSource(False, 500, {'from' : gov})


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


def test_reduce_debt_offsetA(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
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
        
    tokenIndex = 0
    swapPct = 0.02
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)

    # set price source to off
    jointLP.setPriceSource(False, 500, {'from' : gov})


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
        strategy = strategies[i]
        vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
        chain.sleep(5)
        chain.mine(5)
        #chain.mine(1)

        strategy.harvest()
        assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero


def test_operation_offsetB(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
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

    tokenIndex = 1
    swapPct = 0.02
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    # set price source to off
    jointLP.setPriceSource(False, 500, {'from' : gov})


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


def test_reduce_debt_offsetB(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
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
        
    tokenIndex = 1
    swapPct = 0.02
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)

    # set price source to off
    jointLP.setPriceSource(False, 500, {'from' : gov})


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
        assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero



def test_price_offset_checks_A(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
) : 
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

    tokenIndex = 0
    swapPct = 0.1
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))

    print('rebalance debt - should fail')
    with brownie.reverts():
        jointLP.rebalanceDebt()

    # we sleep for maxReport delay time so we can check harvest trigger is returning false 
    chain.sleep(86401)
    chain.mine(1)

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
        with brownie.reverts():
            vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 

        assert strategy.harvestTrigger(1) == False

    jointLP.setPriceSource(False, 500, {'from' : gov})
    
    print("Turn Off Price Check & Rebalance")

    jointLP.rebalanceDebt()

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))


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
        vault.withdraw(withdrawAmt, user, 1000, {'from' : user})  


def test_price_offset_checks_B(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf, priceOffsetter
) : 
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

    tokenIndex = 1
    swapPct = 0.1
    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)
    chain.sleep(5)
    chain.mine(5)
    #assert False
    assert strategy.debtJoint() > 0

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))

    print('rebalance debt - should fail')
    with brownie.reverts():
        jointLP.rebalanceDebt()

    # we sleep for maxReport delay time so we can check harvest trigger is returning false 
    chain.sleep(86401)
    chain.mine(1)

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
        with brownie.reverts():
            vault.withdraw(withdrawAmt, user, 500, {'from' : user}) 

        assert strategy.harvestTrigger(1) == False

    jointLP.setPriceSource(False, 500, {'from' : gov})
    
    print("Turn Off Price Check & Rebalance")
    
    jointLP.rebalanceDebt()

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))


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
        vault.withdraw(withdrawAmt, user, 1000, {'from' : user})  


def test_migration_offsetA(
    chain,
    tokens,
    vaults,
    strategies,
    amounts,
    strategy_contract,
    jointLP_contract,
    scTokens,
    conf,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
    whales,
    Contract
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
        scToken = scTokens[i]
        vault = vaults[i]
        newStrategy = strategy_contract.deploy(vault, newJointLP, scToken, conf['comptroller'], conf['router'], conf['compToken'], {"from": strategist} )        
        newStrategies = newStrategies + [newStrategy]

    newJointLP.initaliseStrategies(newStrategies, {"from": gov})

    tokenIndex = 0
    swapPct = 0.02

    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)

    chain.sleep(1)
    chain.mine(1)

    for i in range(len(tokens)) : 
        strategy = strategies[i]
        newStrategy = newStrategies[i]
        vault = vaults[i]
        vault.migrateStrategy(strategy, newStrategy, {"from": gov})
        amount = amounts[i]
        assert (pytest.approx(newStrategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)  == amount )

def test_migration_offsetB(
    chain,
    tokens,
    vaults,
    strategies,
    amounts,
    strategy_contract,
    jointLP_contract,
    scTokens,
    conf,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
    whales,
    Contract
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
        scToken = scTokens[i]
        vault = vaults[i]
        newStrategy = strategy_contract.deploy(vault, newJointLP, scToken, conf['comptroller'], conf['router'], conf['compToken'], {"from": strategist} )        
        newStrategies = newStrategies + [newStrategy]

    newJointLP.initaliseStrategies(newStrategies, {"from": gov})

    tokenIndex = 1
    swapPct = 0.02

    offSetDebtRatio(jointLP, priceOffsetter, tokens ,tokenIndex, swapPct, user)

    chain.sleep(1)
    chain.mine(1)

    for i in range(len(tokens)) : 
        strategy = strategies[i]
        newStrategy = newStrategies[i]
        vault = vaults[i]
        vault.migrateStrategy(strategy, newStrategy, {"from": gov})
        amount = amounts[i]
        assert (pytest.approx(newStrategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)  == amount )


