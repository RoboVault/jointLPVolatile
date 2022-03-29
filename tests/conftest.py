import pytest
from brownie import config
from brownie import Contract
from brownie import interface, project

SPIRIT_ROUTER = '0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52'
SPOOKY_ROUTER = '0xF491e7B69E4244ad4002BC14e878a34207E38c29'

SPOOKY_MASTERCHEF = '0x2b2929E785374c651a81A63878Ab22742656DcDd'
BOO = '0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE'

'Stables'
USDC = '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75'
FUSDT = '0x049d68029688eAbF473097a2fC38ef61633A3C7A'
MIM = '0x82f0B8B456c1A451378467398982d4834b6829c1'
DAI = '0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E'
WFTM = '0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83'

'SCREAM Lend Tokens'
SCUSDC = '0xE45Ac34E528907d0A0239ab5Db507688070B20bf'
SCFUSDT = '0x02224765BC8D54C21BB51b0951c80315E1c263F9'
SCMIM =  '0x90B7C21Be43855aFD2515675fc307c084427404f'
SCDAI = '0x8D9AED9882b4953a0c9fa920168fa1FDfA0eBE75'
SCWFTM = '0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d'

scTokenDict = {
    USDC : SCUSDC,
    FUSDT : SCFUSDT,
    MIM : SCMIM,
    DAI : SCDAI,
    WFTM : SCWFTM
}

'Reward Tokens'
SCREAM = '0xe0654C8e6fd4D733349ac7E09f6f23DA256bF475'
CRV = '0x1E4F97b9f9F913c46F1632781732927B9019C68b'
GEIST = '0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d'

CONFIG = {

    'USDCFTMSpooky': {
        'LP': '0x2b4C76d0dc16BE1C31D4C1DC53bF9B45987Fc75c',
        'tokens' : [USDC, WFTM],
        'farm' : SPOOKY_MASTERCHEF,
        'farmPID' : 2,
        'comptroller' : '0x260E596DAbE3AFc463e75B6CC05d8c46aCAcFB09',
        'harvest_tokens': [BOO],
        'compToken': SCREAM,
        'router': SPOOKY_ROUTER
    },


}


@pytest.fixture
def conf():
    yield CONFIG['USDCFTMSpooky']

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
    lp = Contract(conf['LP'])
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
def jointLP(pm, gov, conf, keeper ,rewards, guardian, management) : 
    lp = conf['LP']
    jointLPContract = project.JointlpProject.jointLPHolderUniV2
    farmToken = conf['harvest_tokens'][0]
    nTokens = 2
    jointLP = jointLPContract.deploy(lp, conf['farm'] , conf['farmPID'], conf['router'], farmToken, {'from' : gov})
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
def strategies(strategist, keeper, vaults, tokens, gov, conf, jointLP):
    strategyProvider = project.JointlpProject.Strategy
    strategies = []
    i = 0
    for vault in vaults : 
        strategy = strategyProvider.deploy(vault, jointLP, scTokenDict[tokens[i].address], conf['comptroller'], conf['router'], conf['compToken'], {"from": strategist} )
        strategies = strategies + [strategy]
        vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
        i += 1

    jointLP.initaliseStrategies(strategies, {"from": gov})
    #strategy.setKeeper(keeper)
    yield strategies

@pytest.fixture
def strategy_contract():
    # yield  project.CoreStrategyProject.USDCWFTMScreamLqdrSpooky
    yield  project.JointlpProject.Strategy

@pytest.fixture
def jointLP_contract():
    # yield  project.CoreStrategyProject.USDCWFTMScreamLqdrSpooky
    yield  project.JointlpProject.jointLPHolderUniV2


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