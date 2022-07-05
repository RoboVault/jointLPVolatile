import pytest
from brownie import config
from brownie import Contract
from brownie import interface, project

VELO = '0x3c8B650257cFb5f272f799F5e2b4e65093a11a05'
VELO_ROUTER = '0xa132DAB612dB5cB9fC9Ac426A0Cc215A3423F9c9'
VELO_PRICE = 0.007

ZIP_ROUTER = '0xE6Df0BB08e5A97b40B21950a0A51b94c4DbA0Ff6'


#TOKENS
USDC = '0x7F5c764cBc14f9669B88837ca1490cCa17c31607'
WETH = '0x4200000000000000000000000000000000000006'

#AAVE Lend Tokens
AUSDC = '0x625E7708f30cA75bfd92586e17077590C60eb4cD'
AWETH = '0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8'

USDC_WHALE = '0xDecC0c09c3B5f6e92EF4184125D5648a66E35298'
WETH_WHALE = '0xaa30D6bba6285d0585722e2440Ff89E23EF68864'

POOL_ADDRESS_PROVIDER = '0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb'


aTokenDict = {
    USDC : AUSDC,
    WETH : AWETH
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


CONFIG = {

    'USDCWETHVELO': {
        'LP': '0x79c912FEF520be002c2B6e57EC4324e260f38E50',
        'tokens' : [USDC, WETH],
        'farm' : '0xE2CEc8aB811B648bA7B1691Ce08d5E800Dd0a60a',
        'farmPID' : 0,
        'comptroller' : POOL_ADDRESS_PROVIDER,
        'harvest_tokens': [VELO],
        'harvestWhales' : ['0x9c7305eb78a432ced5C4D14Cac27E8Ed569A2e26'],
        'compToken': VELO,
        'router': VELO_ROUTER,
        'lpType' : 'solid'
    },



}


@pytest.fixture
def conf():
    yield CONFIG['USDCWETHVELO']

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
def aTokens(conf, tokens):
    nTokens = 2
    #tokenList = conf['tokens']
    aTokens = []
    for i in range(nTokens) : 
        token = tokens[i]
        aTokens = aTokens + [aTokenDict[token.address]]
    # token_address = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"  # USDC
    # token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield aTokens



@pytest.fixture
def jointLP(pm, gov, conf, keeper ,rewards, guardian, management, jointLPHolderUniV2, jointLPHolderVelo) : 
    lp = conf['LP']
    farmToken = conf['harvest_tokens'][0]
    nTokens = 2
    if conf['lpType'] == 'uniV2':
        jointLP = jointLPHolderUniV2.deploy(lp, conf['farm'] , conf['farmPID'], conf['router'], farmToken, {'from' : gov})
    else : 
        jointLP = jointLPHolderVelo.deploy(lp, conf['farm'] , conf['farmPID'], conf['router'], farmToken, {'from' : gov})


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
def strategies(strategist, StrategyInsurance, MockAaveOracle, accounts  ,keeper, vaults, tokens, gov, conf, jointLP, providerAAVE):

    # Set the mock price oracle (oracle fails when running through tests)
    pool_address_provider = interface.IPoolAddressesProvider(POOL_ADDRESS_PROVIDER)
    old_oracle = pool_address_provider.getPriceOracle()
    oracle = MockAaveOracle.deploy(old_oracle, {'from': accounts[0]})

    admin = accounts.at(pool_address_provider.owner(), True)
    pool_address_provider.setPriceOracle(oracle, {'from': admin})

    strategies = []
    i = 0
    for vault in vaults : 
        token = tokens[i]
        strategy = providerAAVE.deploy(vault, jointLP, aTokenDict[tokens[i].address], POOL_ADDRESS_PROVIDER, ZIP_ROUTER, VELO, {"from": strategist} )
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
    yield  project.JointlpvolatileProject.providerAAVE

@pytest.fixture
def jointLP_contract(conf):
    # yield  project.CoreStrategyProject.USDCWFTMScreamLqdrSpooky

    if conf['lpType'] == 'uniV2':
        yield  project.JointlpvolatileProject.jointLPHolderUniV2
    else : 
        yield  project.JointlpvolatileProject.jointLPHolderVelo



@pytest.fixture
def whales(tokens, Contract) : 
    ZIP_ROUTER = '0xE6Df0BB08e5A97b40B21950a0A51b94c4DbA0Ff6'

    altRouterContract = Contract(ZIP_ROUTER)
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