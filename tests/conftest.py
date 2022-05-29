import pytest
from brownie import config
from brownie import Contract
from brownie import interface, project

SPIRIT_ROUTER = '0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52'
SPOOKY_ROUTER = '0xF491e7B69E4244ad4002BC14e878a34207E38c29'

SPOOKY_MASTERCHEF = '0x2b2929E785374c651a81A63878Ab22742656DcDd'
BOO = '0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE'

lqdrMasterChef = '0x6e2ad6527901c9664f016466b8DA1357a004db0f'
lqdr = '0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9'

#TOKENS
USDC = '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75'
FUSDT = '0x049d68029688eAbF473097a2fC38ef61633A3C7A'
MIM = '0x82f0B8B456c1A451378467398982d4834b6829c1'
DAI = '0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E'
WFTM = '0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83'
FRAX = '0xdc301622e621166BD8E82f2cA0A26c13Ad0BE355'
WETH = '0x74b23882a30290451A17c44f4F05243b6b58C76d'

#SCREAM Lend Tokens
SCUSDC = '0xE45Ac34E528907d0A0239ab5Db507688070B20bf'
SCFUSDT = '0x02224765BC8D54C21BB51b0951c80315E1c263F9'
SCMIM =  '0x90B7C21Be43855aFD2515675fc307c084427404f'
SCDAI = '0x8D9AED9882b4953a0c9fa920168fa1FDfA0eBE75'
SCWFTM = '0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d'
SCFRAX = '0x4E6854EA84884330207fB557D1555961D85Fc17E'
SCWETH = '0xC772BA6C2c28859B7a0542FAa162a56115dDCE25'


IBUSDC = '0x328A7b4d538A2b3942653a9983fdA3C12c571141'
IBWFTM = '0xd528697008aC67A21818751A5e3c58C8daE54696'

screamComptroller = '0x260E596DAbE3AFc463e75B6CC05d8c46aCAcFB09'
hndComptroller = '0x0F390559F258eB8591C8e31Cf0905E97cf36ACE2'
ibComptroller = '0x4250A6D3BD57455d7C6821eECb6206F507576cD2'

scTokenDict = {
    USDC : SCUSDC,
    FUSDT : SCFUSDT,
    MIM : SCMIM,
    DAI : SCDAI,
    WFTM : SCWFTM,
    FRAX : SCFRAX,
    WETH : SCWETH
}

ibTokenDict = {
    USDC : IBUSDC,
    WFTM : IBWFTM
    
}


"""
'HND Lend Tokens'
hUSDC = '0x243E33aa7f6787154a8E59d3C27a66db3F8818ee'
hFRAX = '0xb4300e088a3AE4e624EE5C71Bc1822F68BB5f2bc'
hWFTM = '0xfCD8570AD81e6c77b8D252bEbEBA62ed980BD64D'
hMIM = '0xa8cD5D59827514BCF343EC19F531ce1788Ea48f8'

'HND Gauges'

gUSDC : '0x110614276F7b9Ae8586a1C1D9Bc079771e2CE8cF'
gUSDT : '0xbF689f50cB446f171F08691367f7D9398b24D382'
gMIM : '0x26596af66A10Cb6c6fe890273eD37980D50f2448'
gFRAX : '0x2c7a9d9919f042C4C120199c69e126124d09BE7c'
gDAI : '0xB8481A3cE515EA8cAa112dba0D1ecfc03937fbcD'


hndTokenDict = {
    USDC : hUSDC,
    FRAX : hFRAX,
    MIM : hMIM,
    WFTM : hWFTM
}

gaugeDict = {
    USDC : gUSDC,
    FRAX : gFRAX,
    MIM : gMIM,
}

chosenLenderDict = {
    USDC : 'scream',
    FRAX : 'hnd',
    WFTM : 'scream',
    MIM : 'scream'
}
"""
'Reward Tokens'
SCREAM = '0xe0654C8e6fd4D733349ac7E09f6f23DA256bF475'
HND = '0x10010078a54396F62c96dF8532dc2B4847d47ED3'
CRV = '0x1E4F97b9f9F913c46F1632781732927B9019C68b'
GEIST = '0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d'
oxd = '0xc5A9848b9d145965d821AaeC8fA32aaEE026492d'
solid = '0x888EF71766ca594DED1F0FA3AE64eD2941740A20'

CONFIG = {

    'USDCFTMSpookyBOO': {
        'LP': '0x2b4C76d0dc16BE1C31D4C1DC53bF9B45987Fc75c',
        'tokens' : [USDC, WFTM],
        'farm' : SPOOKY_MASTERCHEF,
        'farmPID' : 2,
        'comptroller' : ibComptroller,
        'harvest_tokens': [BOO],
        'harvestWhale' : 0xa48d959AE2E88f1dAA7D5F611E01908106dE7598,
        'compToken': SCREAM,
        'router': SPOOKY_ROUTER,
        'lpType' : 'uniV2'
    },

    'USDCFTMSpookyLQDR': {
        'LP': '0x2b4C76d0dc16BE1C31D4C1DC53bF9B45987Fc75c',
        'tokens' : [USDC, WFTM],
        'farm' : lqdrMasterChef,
        'farmPID' : 11,
        'comptroller' : ibComptroller,
        'harvest_tokens': [lqdr],
        'harvestWhales' : [lqdrMasterChef],
        'compToken': SCREAM,
        'router': SPOOKY_ROUTER,
        'lpType' : 'uniV2'
    },

    'WETHFTMSpookyLQDR': {
        'LP': '0xf0702249F4D3A25cD3DED7859a165693685Ab577',
        'tokens' : [WETH, WFTM],
        'farm' : lqdrMasterChef,
        'farmPID' : 15,
        'comptroller' : screamComptroller,
        'harvest_tokens': [lqdr],
        'harvestWhales' : [lqdrMasterChef],
        'compToken': SCREAM,
        'router': SPOOKY_ROUTER,
        'lpType' : 'uniV2'
    }
}


@pytest.fixture
def conf():
    yield CONFIG['USDCFTMSpookyLQDR']

@pytest.fixture
def gov(accounts):
    yield accounts.at("0x7601630eC802952ba1ED2B6e4db16F699A0a5A87", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]

@pytest.fixture
def router(conf):
    yield Contract(conf['router'])


@pytest.fixture
def amounts(accounts, tokens, user, whales):
    amounts = []
    i = 0 
    for whale in whales : 
        reserve = accounts.at(whale, force=True)
        token = tokens[i]
        amount = 10_000 * 10 ** token.decimals()
        # we need some tokens left over to do price offsets 
        amount = int(min(amount, 0.1*token.balanceOf(reserve)))
        token.transfer(user, amount, {"from": reserve})
        i += 1
        amounts = amounts + [amount]
    yield amounts


@pytest.fixture
def weth():
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
    yield interface.IERC20Extended(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def tokens(conf, Contract):
    nTokens = 2
    #lp = Contract(conf['LP'])
    #tokenList = conf['tokens']
    tokens = []

    token = conf['tokens'][0]
    tokens = tokens + [interface.IERC20Extended(token)]

    token = conf['tokens'][1]
    tokens = tokens + [interface.IERC20Extended(token)]

    yield tokens

@pytest.fixture
def scTokens(conf, tokens):
    nTokens = 2
    #tokenList = conf['tokens']
    scTokens = []
    for i in range(nTokens) : 
        token = tokens[i]
        scTokens = scTokens + [scTokenDict[token.address]]
    # token_address = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"  # USDC
    # token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield scTokens

@pytest.fixture
def ibTokens(conf, tokens):
    nTokens = 2
    #tokenList = conf['tokens']
    ibTokens = []
    for i in range(nTokens) : 
        token = tokens[i]
        ibTokens = ibTokens + [ibTokenDict[token.address]]
    # token_address = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"  # USDC
    # token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield ibTokens

@pytest.fixture
def jointLP(pm, gov, conf, keeper ,rewards, guardian, management, jointLPHolderUniV2) : 
    lp = conf['LP']
    farmToken = conf['harvest_tokens'][0]
    nTokens = 2
    if conf['lpType'] == 'uniV2':
        jointLP = jointLPHolderUniV2.deploy(lp, conf['farm'] , conf['farmPID'], conf['router'], farmToken, {'from' : gov})
    
    jointLP.setKeeper(keeper)
    yield jointLP



@pytest.fixture
def vaults(pm, gov, rewards, guardian, management, tokens):
    tokenList = tokens
    vaults = []
    Vault = pm(config["dependencies"][0]).Vault
    for token in tokenList : 
        vault = guardian.deploy(Vault)
        vault.initialize(token, gov, rewards, "", "", guardian, management)
        vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
        vault.setManagement(management, {"from": gov})
        assert vault.token() == token.address
        vaults = vaults + [vault]

    yield vaults

@pytest.fixture
def strategies(strategist, StrategyInsurance  ,keeper, vaults, tokens, gov, conf, jointLP, Strategy):


    strategies = []
    i = 0
    for vault in vaults : 
        token = tokens[i]
        strategy = Strategy.deploy(vault, jointLP, ibTokenDict[tokens[i].address], ibComptroller, conf['router'], SCREAM, {"from": strategist} )
        insurance = StrategyInsurance.deploy(strategy, {'from' : strategist})
        strategy.setInsurance(insurance, {'from': gov})
        strategies = strategies + [strategy]
        vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
        i += 1

    jointLP.initaliseStrategies(strategies, {"from": gov})
    #strategy.setKeeper(keeper)
    yield strategies

@pytest.fixture
def strategy_contract():
    # yield  project.CoreStrategyProject.USDCWFTMScreamLqdrSpooky
    yield  project.JointlpvolatileProject.Strategy

@pytest.fixture
def jointLP_contract():
    # yield  project.CoreStrategyProject.USDCWFTMScreamLqdrSpooky
    yield  project.JointlpvolatileProject.jointLPHolderUniV2


@pytest.fixture
def whales(tokens, Contract) : 
    router = SPIRIT_ROUTER
    altRouterContract = Contract(router)
    factory = Contract(altRouterContract.factory())
    whales = []
    tokenList = tokens
    whale = factory.getPair(tokens[0], tokens[1])
    
    for token in tokenList : 
        
        whales = whales + [whale]

    return(whales)

@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-2


# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass