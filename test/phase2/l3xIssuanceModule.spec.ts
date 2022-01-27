import "module-alias/register";

import { Account } from "@utils/test/types";
import { ADDRESS_ZERO, MAX_UINT_256, ZERO } from "@utils/constants";
import { 
  StandardTokenMock,
    UniswapV2Router02,
} from "@utils/contracts";
import {
  getWaffleExpect,
  getAccounts,
    getAaveV2Fixture,
    getUniswapFixture,//for aave
} from "@utils/test/index";
import { ethers } from "hardhat";
import { bitcoin, ether } from "@utils/common/unitsUtils";
import { abi as ZooTokenABI } from "../../artifacts/contracts/protocol/ZooToken.sol/ZooToken.json";

//for aave
import {  AaveV2Fixture } from "@utils/fixtures";

import {BigNumber, Contract} from "ethers";
import { WETH9__factory } from "@typechain/factories/WETH9__factory";
import { L3xIssuanceModule } from "@typechain/L3xIssuanceModule";
import { ZooToken } from "@typechain/ZooToken";
import { ZooTokenCreator } from "@typechain/ZooTokenCreator";
import { Controller } from "@typechain/Controller";

const expect = getWaffleExpect();

const initUniswapRouter = async(owner: Account, weth:  Contract, dai:  StandardTokenMock, btc: StandardTokenMock): Promise<UniswapV2Router02> => {
      let router: UniswapV2Router02;

         let uniswapFixture =  getUniswapFixture(owner.address);
        await uniswapFixture.initialize(
          owner,
          weth.address,
          btc.address,
          dai.address
        );
        router = uniswapFixture.router;
      await  weth.approve(router.address, MAX_UINT_256);
      await dai.approve(router.address, MAX_UINT_256);
      await router.addLiquidity(weth.address, dai.address, ether(5000), ether(5000000), ether(4990), ether(4900000), owner.address, MAX_UINT_256);
      return router;
}


interface Accounts {
  owner: Account;
  protocolFeeRecipient: Account;
  mockUser: Account;
  mockSubjectModule: Account;
  bob: Account;
  alice: Account;
  oscar: Account;
  others: Account[];
}

interface Tokens {
  weth: Contract;
  mockDai: StandardTokenMock;
  mockBtc: StandardTokenMock;
}

interface Contracts {
  controller: Controller;
  zooToken: ZooToken;
  creator: ZooTokenCreator;
}

class Context {
  public accounts= <Accounts>{};
  public tokens = <Tokens> {};
  public ct = <Contracts> {};
  public zoos: ZooToken[] = [];

  public aaveFixture: AaveV2Fixture;
  public subjectModule: L3xIssuanceModule;
  public router: UniswapV2Router02;

  public async createZooToken(): Promise<void> {
      const tx =  await this.ct.creator.create(
        [this.tokens.mockDai.address],
        [ether(1000)],
        [this.subjectModule.address], 
        this.accounts.owner.address, 
        "eth long", 
        "BULL"
      );
      const receipt = await tx.wait();
      const event = receipt.events?.find(p => p.event == "ZooTokenCreated");
      const tokensetAddress = event? event.args? event.args[0]:"":"";
      let deployedZooToken =  await ethers.getContractAt(ZooTokenABI, tokensetAddress);
      this.zoos.push(deployedZooToken as ZooToken);
      await this.subjectModule.initialize(deployedZooToken.address);
  }

  public async initialize() : Promise<void>  {
    [
      this.accounts.owner,
      this.accounts.protocolFeeRecipient,
      this.accounts.mockUser,
      this.accounts.mockSubjectModule,
      this.accounts.bob,
      this.accounts.alice,
      this.accounts.oscar,
      ...this.accounts.others
    ] = await getAccounts();
     
      /* ================================================== DeFi Fixtures ==================================================*/
      this.aaveFixture = getAaveV2Fixture(this.accounts.owner.address);
      this.tokens.mockDai =  await (await ethers.getContractFactory("StandardTokenMock")).deploy(this.accounts.owner.address, ether(100000000), "MockDai", "MDAI", 18);
      this.tokens.mockBtc = await (await ethers.getContractFactory("StandardTokenMock")).deploy(this.accounts.owner.address, bitcoin(1000000), "MockBtc", "MBTC", 8);
      this.tokens.weth = await new WETH9__factory(this.accounts.owner.wallet).deploy();

      await this.tokens.weth.connect(this.accounts.bob.wallet).deposit({value: ether(500)});
      await this.tokens.weth.deposit({value: ether(5000)});
      await this.tokens.weth.connect(this.accounts.mockSubjectModule.wallet).deposit({value: ether(500)});
      await this.tokens.mockDai.transfer(this.accounts.bob.address, ether(200000));
      
      this.router = await initUniswapRouter(this.accounts.owner, this.tokens.weth, this.tokens.mockDai, this.tokens.mockBtc);      
      await  this.aaveFixture.initialize(this.tokens.weth.address, this.tokens.mockDai.address);

      // provide liquidity
      await this.tokens.mockDai.connect(this.accounts.owner.wallet).approve(this.aaveFixture.lendingPool.address, MAX_UINT_256);
      await this.aaveFixture.lendingPool.connect(this.accounts.owner.wallet).deposit(this.tokens.mockDai.address, ether(1000000), this.accounts.owner.address, ZERO);

      /* ============================================= Zoo Ecosystem ==============================================================*/
      this.ct.controller =  await (await ethers.getContractFactory("Controller")).deploy(
        this.accounts.protocolFeeRecipient.address
      );
      this.ct.creator =  await (await ethers.getContractFactory("ZooTokenCreator")).deploy(
        this.ct.controller.address
      );
      this.subjectModule = await (await ethers.getContractFactory("L3xIssuanceModule")).deploy(
        this.ct.controller.address, 
        this.tokens.weth.address, 
        this.tokens.mockDai.address
      );
      await this.subjectModule.setLendingPool(this.aaveFixture.lendingPool.address);
      await this.subjectModule.setRouter(this.router.address);

      await this.ct.controller.initialize(
        [this.ct.creator.address],
        [this.subjectModule.address],
        [],[]
      )

      await this.createZooToken();
  }
}

describe("Controller", () => {
  let ctx: Context;
  beforeEach(async () => {

  });

  describe("Owner needs to deposit and withdraw collateral inside Aave", async function () {
    beforeEach(async () => {
      ctx = new Context();
      await ctx.initialize();
    });
    it("Verify ZooToken created via ZooTokenCreator", async () => {
      expect(await ctx.zoos[0].modules(0)).to.be.eq(ctx.subjectModule.address);
      expect(await ctx.zoos[0].isInitializedModule(ctx.subjectModule.address)).to.be.true;
      expect(await ctx.zoos[0].name()).to.be.eq("eth long");
      expect(await ctx.zoos[0].symbol()).to.be.eq("BULL");
    });
    it("Verify Interaction with Aave fixture directly - Borrow from aave and check debt", async ()=>{
        await ctx.tokens.weth.connect(ctx.accounts.bob.wallet).approve(ctx.aaveFixture.lendingPool.address, MAX_UINT_256);
        await ctx.tokens.weth.connect(ctx.accounts.mockSubjectModule.wallet).approve(ctx.aaveFixture.lendingPool.address, MAX_UINT_256);
        await ctx.tokens.mockDai.connect(ctx.accounts.owner.wallet).approve(ctx.aaveFixture.lendingPool.address, MAX_UINT_256);

        await ctx.aaveFixture.lendingPool.connect(ctx.accounts.mockSubjectModule.wallet).deposit(ctx.tokens.weth.address, ether(10), ctx.accounts.bob.address, ZERO);
        await ctx.aaveFixture.lendingPool.connect(ctx.accounts.mockSubjectModule.wallet).deposit(ctx.tokens.weth.address, ether(10), ctx.accounts.mockSubjectModule.address, ZERO);
        await ctx.aaveFixture.lendingPool.connect(ctx.accounts.owner.wallet).deposit(ctx.tokens.mockDai.address, ether(1000000), ctx.accounts.owner.address, ZERO);
        await ctx.aaveFixture.lendingPool.connect(ctx.accounts.mockSubjectModule.wallet).borrow(ctx.tokens.mockDai.address, ether(8000), BigNumber.from(1), ZERO, ctx.accounts.mockSubjectModule.address);
       
        let userData = (await ctx.aaveFixture.lendingPool.getUserAccountData(ctx.subjectModule.address));
        expect(userData.healthFactor).to.gt(ether(1));  // ~ 1.03 ETH 
    });
    it("SubjectModule deposits weth and borrows against it", async ()=>{
       await ctx.tokens.mockDai.approve(ctx.subjectModule.address, ether(10000));
       await ctx.subjectModule.issue(ether(10000), ether(800));

       let userData = (await ctx.aaveFixture.lendingPool.getUserAccountData(ctx.subjectModule.address));
       let leverage = userData.totalCollateralETH.add(userData.totalDebtETH).mul(1000).div(ether(10));

       expect(leverage).to.be.gt(2500);   // leverage = 2865 for minimum healthFactor/maximum risk
       expect(userData.currentLiquidationThreshold).to.gt(BigNumber.from(8000));
       expect(userData.healthFactor).to.gt(ether(1));  // ~ 1.03 ETH 
    });

  });
});