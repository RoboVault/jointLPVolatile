import brownie
from brownie import interface, Contract, accounts
import pytest
import time 


def calculateLosses(tokens, strategies,amounts):
    losses = []
    for i in range(len(tokens)) : 
        loss = strategies[i].estimatedTotalAssets() / amounts[i]
        losses.append(loss)
        print("Loss  " + str(i) + " - ")
        print(loss)

    return losses



def offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct):
    # use other AMM's LP to force some swaps 
    solidRouter = '0xa38cd27185a464914D3046f0AB9d43356B34829D'

    if conf['lpType'] == 'uniV2' :
        router = Contract(conf['router'])
    else : 
        router = Contract(solidRouter)

    whale = whales[tokenIndex]
    token = tokens[tokenIndex]
    if tokenIndex == 0 : 
        swapTo = tokens[1]
    
    if tokenIndex == 1 : 
        swapTo = tokens[0]

    swapAmtMax = token.balanceOf(conf['LP'])*swapPct
    swapAmt = min(swapAmtMax, token.balanceOf(whale))
    print("Force Large Swap - to offset debt ratios")
    token.approve(router, 2**256-1, {"from": whale})
    if conf['lpType'] == 'uniV2' :  
        router.swapExactTokensForTokens(swapAmt, 0, [token, swapTo], whale, 2**256-1, {"from": whale})
    else : 
        router.swapExactTokensForTokensSimple(swapAmt, 0, token, swapTo, False, whale, 2**256-1, {"from": whale})


def test_rebalanceDebtA(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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

    lossesPreRebalance = calculateLosses(tokens, strategies, amounts)

    print('rebalance debt')
    jointLP.rebalanceDebt()

    lossesPostRebalance = calculateLosses(tokens, strategies, amounts)


    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))

def test_rebalanceDebtB(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    swapPct = 0.03
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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

    lossesPreRebalance = calculateLosses(tokens, strategies, amounts)

    print('rebalance debt')
    jointLP.rebalanceDebt()

    lossesPostRebalance = calculateLosses(tokens, strategies, amounts)

    debtRatio0 = jointLP.calcDebtRatioToken(0)
    debtRatio1 = jointLP.calcDebtRatioToken(1)

    print('Debt Ratio A :  {0}'.format(debtRatio0))
    print('Debt Ratio B :  {0}'.format(debtRatio1))



def test_operation_offsetA(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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
        assert strategy.estimatedTotalAssets() / amounts[i] < 0.005


def test_operation_offsetB(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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
        assert strategy.estimatedTotalAssets() / amounts[i] < 0.005



def test_price_offset_checks_A(
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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

    lossesPreRebalance = calculateLosses(tokens, strategies, amounts)

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

    lossesPostRebalance = calculateLosses(tokens, strategies, amounts)


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
    chain, accounts, whales, Contract, gov, tokens, vaults, strategies, jointLP, user, strategist, amounts, RELATIVE_APPROX, conf
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
    swapPct = 0.15
    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
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
    jointLP,
    ibTokens,
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
        scToken = ibTokens[i]
        vault = vaults[i]
        newStrategy = strategy_contract.deploy(vault, newJointLP, scToken, conf['comptroller'], conf['router'], conf['compToken'], {"from": strategist} )        
        newStrategies = newStrategies + [newStrategy]

    newJointLP.initaliseStrategies(newStrategies, {"from": gov})

    tokenIndex = 0
    swapPct = 0.02

    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
    jointLP.setPriceSource(False, 500, {'from' : gov})

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
    jointLP,
    ibTokens,
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
        scToken = ibTokens[i]
        vault = vaults[i]
        newStrategy = strategy_contract.deploy(vault, newJointLP, scToken, conf['comptroller'], conf['router'], conf['compToken'], {"from": strategist} )        
        newStrategies = newStrategies + [newStrategy]

    newJointLP.initaliseStrategies(newStrategies, {"from": gov})

    tokenIndex = 1
    swapPct = 0.02

    offSetDebtRatio(gov, whales, tokens, conf, Contract, tokenIndex, swapPct)
    jointLP.setPriceSource(False, 500, {'from' : gov})

    chain.sleep(1)
    chain.mine(1)

    for i in range(len(tokens)) : 
        strategy = strategies[i]
        newStrategy = newStrategies[i]
        vault = vaults[i]
        vault.migrateStrategy(strategy, newStrategy, {"from": gov})
        amount = amounts[i]
        assert (pytest.approx(newStrategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)  == amount )


