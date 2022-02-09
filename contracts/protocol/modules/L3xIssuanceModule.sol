/*
    Copyright 2021 IndexZoo Ltd.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental "ABIEncoderV2";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IController } from "../../interfaces/IController.sol";
import { IUniswapV2Router } from "../../interfaces/external/IUniswapV2Router.sol";
import { ILendingPool } from "../../interfaces/external/aave-v2/ILendingPool.sol";
import { ILendingPoolAddressesProvider } from "../../interfaces/external/aave-v2/ILendingPoolAddressesProvider.sol";
import { IPriceOracleGetter } from "../../interfaces/external/aave-v2/IPriceOracleGetter.sol";
import { Invoke } from "../lib/Invoke.sol";
import { IZooToken } from "../../interfaces/IZooToken.sol";
import { IssuanceValidationUtils } from "../lib/IssuanceValidationUtils.sol";
import { Position } from "../lib/Position.sol";
import { ModuleBase } from "../lib/ZooModuleBase.sol";
import "hardhat/console.sol";

/**
 * @title L3xIssuanceModule
 * @author IndexZoo Ltd.
 *
 * The L3xIssuanceModule is a module that enables users to issue and redeem Leveraged Tokens that wrap a base token 
 * including debt positions. Module hooks are added to allow for syncing of debt, 
 * to ensure debts are replicated correctly. 
 * 
 * @dev Note that current state of the contract is for testing the feasibility of achieving ~ 3x Leverage
 * @dev Next stage most of that logic will be invoked from the SetToken (or ZooToken)
 * @dev SetToken will be changed as balance of (LevToken) (previously setToken) will be reflected by debt with AAVE 
 * 
 * NOTE: 
 */

 /**
  * @dev Notes
  * FIXME: Last withdrawal edge case, in which you need to do successive withdrawals and repay
  *  - might require multiple step external call instead
  * FIXME: Initialization of ecosystem: suppose 3 users issue tokes and price goes down on bull.
  *  - Users won't be able even to redeem their funds even with loss ! FIX this 
  *  - Depends on liquidation threshold discussion (risk assessment)
  * FIXME: Borrow only on behalf of users in order to determine the debt for each one properly
  * DONE: Redeem logic
  * TODO: Liquidation Threshold
  * TODO: add 0.8 factor to configs
  * TODO: Streaming fees 
  * TODO: Replace token component variable name by asset
  * DONE: Mint and set debt on zooToken
  * TODO: Rebalance price formula
  * DONE: Access control on setting lender and router (each token should have their own config)
  * TODO: Module viewer
  * TODO: Constructor: replace weth_ by underlying asset of LevToken (replacing SetToken)
  * TODO: put an argument for minimum quantity of token to receive from Issue (slippage)
  * TODO: TODO: Integration Registry should be the provider of the calldata
  * DONE: _borrowQuoteForBaseCollateral: at the end ensure borrow took place smh
  * DONE: _swapQuoteForBase: at the end ensure swap took place
  * DONE: _borrowAvailableAmount: consider parameterizing the 0.999 factor

  *
  */ 
contract L3xIssuanceModule is  ModuleBase, ReentrancyGuard {
    using Position for IZooToken;
    using SafeMath for uint256;

    uint256 private constant BORROW_PORTION_FACTOR = 0.999 ether;
    uint256 private constant AMOUNT_PER_COLLATERAL = 0.8 ether;

    struct ModuleConfig {
        ILendingPool lender;
        IUniswapV2Router router;
        ILendingPoolAddressesProvider addressesProvider;
    }

    enum Side {
        Bull,
        Bear
    }

    mapping(address => ModuleConfig) public configs;

    IERC20 public weth; // 
    IERC20 public dai;



    /* ============ Constructor ============ */
    /**
     * 
     * @param weth_   Address of WETH, represents baseToken (NOTE will be pointed at in SetToken)      
     * @param dai_    Address of DAI, Represents the quoteToken 
     */
    
    constructor(IController _controller, IERC20 weth_, IERC20 dai_) public ModuleBase (_controller) {
        weth = weth_;
        dai = dai_;
    }

    /* ============ External Functions ============ */

    /**
     * Initializes this module to the SetToken. Only callable by the SetToken's manager.
     *
     * @param zooToken_                 Instance of the SetToken to initialize
     */
    function initialize(
        IZooToken zooToken_
    )
        external
        onlyValidAndPendingSet(zooToken_)
        onlySetManager(zooToken_, msg.sender)
    {
        zooToken_.initializeModule();
    }

    function deposit(
    )
    external 
    payable
    {
        payable(address(weth)).call{value: msg.value}("");
    }
    /**
     * Mints Leverage token for investor
     * @dev If setToken is bullish
     * Deposits the base asset of that token on AAVE (i.e. WETH)
     * Borrows quoteToken (i.e. DAI)
     * Amount borrowed is derived from getUserAccountData() call provided by LendingPool
     * Module does not directly invoke methods as these calls are being invoked by the Zoo Token
     * Tokens minted for user (caller) are proportion to the amount deposited and borrowed
     *

     *
     * @param quantity_         Quantity of quote token input to go long 
     * @param basePriceInQuotes_ price of baseToken (i.e. ETH) in quoteToken (i.e. DAI)
     * @param swapFactorx1000_   The accepted portion of quantity_ to get through after deduction from fees. 
     * This is taking place during the processes of swapping & borrowing (i.e. about 985)
     */
    function issue (
        IZooToken zooToken_,
        uint256 quantity_,
        uint256 basePriceInQuotes_,
        uint256 swapFactorx1000_
    )
        external
        nonReentrant
        onlyValidAndInitializedSet(zooToken_)
    {
        dai.transferFrom(msg.sender, address(zooToken_), quantity_);
        // swap dai for baseToken
        uint256 amountOut = _swapQuoteForBase(zooToken_, quantity_, _multiplyByFactorSwap(quantity_, swapFactorx1000_, basePriceInQuotes_)); 
        uint256 borrowAmount;
        uint256 totalAmountOut = amountOut;
        uint256 totalBorrowAmount;
        for (uint8 i = 0; i < 2; i++) {
            borrowAmount = _borrowQuoteForBaseCollateral(zooToken_, amountOut );
            amountOut = _swapQuoteForBase(zooToken_, borrowAmount, _multiplyByFactorSwap(borrowAmount, swapFactorx1000_, basePriceInQuotes_));

            totalAmountOut = totalAmountOut.add(amountOut);
            totalBorrowAmount = totalBorrowAmount.add(borrowAmount);
        }

        // Borrow quoteToken from lending Protocol
        zooToken_.addDebt(msg.sender, totalBorrowAmount);
        zooToken_.mint(msg.sender, totalAmountOut);
        require(totalAmountOut != 0, "L3xIssueMod: Leveraging failed");
    }

    /**
     * Function aims at sending the investor amount of DAI corresponding to the state of his/her position.
     * 
     * @dev redemption steps:
     * * Get the rate of uniswap of quoteToken to baseToken.
     * * Swap the debt of investor from the amount of tokens he possess (inflated).
     * * Check if there is enough tokens to be redeemed from balance.
     * * If there are not enough tokens then withdraw needed amount from Aave.
     * * Convert amount to quoteToken(i.e. DAI)
     * * Repay corresponding amount of debt which corresponds to closing position.
     * * Relieve investor from debt
     * * Transfer remain (quantity_ - baseAmountRepaid) int baseToken and burn zoos
     * * Do a rebalance for leverage by borrowing Available eth from Aave
     *
     * DONE: Might need to do rebalance (investigate) ?
     * TODO: Check and liquidate all balance if debt is greater than balance of user      
     *
     * @param quantity_         Quantity of token to be redeemed 
     */
    function redeem(
        IZooToken zooToken_,
        uint256 quantity_
    )
        external
        nonReentrant
        onlyValidAndInitializedSet(zooToken_)
    {
        // TODO: TODO: Put debt Repay in private function
        IUniswapV2Router router_ = configs[address(zooToken_)].router;
        uint256 userZooBalance = zooToken_.balanceOf(msg.sender);
        if(quantity_  ==  uint256(-1)) {
              quantity_ = userZooBalance;
        }
        require(quantity_ <= userZooBalance, "L3xIssuance: Not enough NAV" );

        //@dev NB: Important to calculate currentBalancePortion before withdrawing collateralPortion and debtRepay
        uint256 currentBalancePortion = _getUserPortionOfBaseBalance(zooToken_, quantity_);
        uint256[] memory amountsRepaid = _payUserDebtPortion(zooToken_, quantity_);
        // Withdraw 
        uint256 collateralPortion = _withdrawUserPortionOfTotalCollateral(zooToken_, quantity_);
        
        zooToken_.burn(msg.sender, quantity_);
        zooToken_.transferAsset(weth, msg.sender, currentBalancePortion.add(collateralPortion).sub(amountsRepaid[0]));
    }

    /**
     * Function aims at rebalancing deposits with debt to achieve the aimed leverage
     * TODO: This function can be called by anyone if enabled by Manager
     * -> if not enabled by manager then only allowed callers (also set by manager) can call this
     * 
     * @dev Rebalancing steps:
     * * Show the amount available for borrow from lending protocol (Aave) 
     *
     *
     * @param zooToken_         Zoo Token chosen to be rebalanced 
     */
    // function rebalanceIndex(
    //     IZooToken zooToken_
    // )
    //     external
    //     nonReentrant
    //     onlyValidAndInitializedSet(zooToken_)
    // {
    //     _borrowAvailableAmount(zooToken_);
    // }

    function _finalizeRedeem (
        IZooToken zooToken_,
        uint256 quantity_,
        uint256 debtRepaid_
    ) 
    private 
    {
        zooToken_.burn(msg.sender, quantity_);
        zooToken_.transferAsset(weth, msg.sender, quantity_.sub(debtRepaid_));
    }


    /**
     * Administrative calls: to be called by Manager only
     */
     function setConfigForToken(
         address zooToken_,
         ModuleConfig calldata config_
    )
    external
    onlySetManager(IZooToken(zooToken_), msg.sender)
    {
        configs[zooToken_].addressesProvider = config_.addressesProvider;
        configs[zooToken_].lender = config_.lender;
        configs[zooToken_].router = config_.router;
    }

    function removeModule() external override {}


   /**  -------------------------------- Private functions --------------------------------------------------
    */
    function _withdrawUserPortionOfTotalCollateral(
        IZooToken zooToken_,
        uint256 quantity_
    )
    private
    returns(uint256 amountToWithdraw) 
    {
        uint256 zooSupply = zooToken_.totalSupply();
        (uint256 totalCollateralETH,,,,,) = configs[address(zooToken_)].lender.getUserAccountData(address(zooToken_));
        uint256 collateralPortion =  quantity_.mul(totalCollateralETH).div(zooSupply);
        amountToWithdraw = _invokeWithdraw(zooToken_, address(weth), collateralPortion);
    }

    function _payUserDebtPortion(
        IZooToken zooToken_,
        uint256 quantity_
    )
    private
    returns (uint256[] memory amountsRepaid)
    {
        uint256 userZooBalance = zooToken_.balanceOf(msg.sender);
        uint256 userDebtInQuote = zooToken_.getDebt(msg.sender);
        
        address[] memory path = new address[](2);
        path[0] = address(dai); 
        path[1] = address(weth);
        uint256 userDebtInBase = configs[address(zooToken_)].router.getAmountsOut(userDebtInQuote, path)[1];
        
        uint256 debtToRepayInBaseCeil = quantity_.mul(userDebtInBase).div(userZooBalance); 
        debtToRepayInBaseCeil = debtToRepayInBaseCeil.mul(100).div(90);
        // console.logUint(quantity_);
        // console.logUint(userZooBalance);
        // console.logUint(userDebtInQuote);
        // console.logUint(debtToRepayInBaseCeil);
        // console.logUint(weth.balanceOf(address(zooToken_)));

        require(debtToRepayInBaseCeil <= weth.balanceOf(address(zooToken_)) , "L3xIssuance: Not enough liquid");
        uint debtToRepayInQuote = quantity_.mul(userDebtInQuote).div(userZooBalance);

        amountsRepaid = _repayDebtForUser(zooToken_, debtToRepayInBaseCeil, debtToRepayInQuote);
        zooToken_.payDebt(msg.sender, amountsRepaid[1]);  // quoteAmountRepaid
    }

    function _getUserPortionOfBaseBalance(
        IZooToken zooToken_,
        uint256 quantity_
    )
    private
    view
    returns(uint256 currentBalancePortion) 
    {
        uint256 zooSupply = zooToken_.totalSupply();
        // currentBalancePortion = floor(quantity_ * wethBalanceOfZoo / zooTotalSupply)
        currentBalancePortion = quantity_.mul(weth.balanceOf(address(zooToken_))).div(zooSupply);
    }

    function _multiplyByFactorSwap(
        uint256 amount_,
        uint256 factorx1000_,
        uint256 price_
    )
    private
    pure
    returns (uint256)
    {
        return amount_.mul(factorx1000_).div(1000).mul(1 ether).div(price_);
    }
    function _borrowQuoteForBaseCollateral(
        IZooToken zooToken_,
        uint256 depositAmount_
    )
    private
    returns (uint256 notionalBorrowAmount)
    {
        ILendingPool lender_ = configs[address(zooToken_)].lender;
        _invokeApprove(zooToken_, address(weth), address(lender_) , depositAmount_);
        _invokeDeposit(zooToken_, address(weth), depositAmount_);
        // approve lender to receive swapped baseToken
        (notionalBorrowAmount, ) = _borrowAvailableAmount(zooToken_, depositAmount_, AMOUNT_PER_COLLATERAL);
        require(notionalBorrowAmount > 0, "L3xIssuanceModule: Borrowing unsuccessful");
    }
    function _swapQuoteForBase(
        IZooToken zooToken_,
        uint256 amountIn_, 
        uint256 minAmountOut_
      ) 
      private 
      returns (uint256 amountOut) 
    {
        IUniswapV2Router router_ = configs[address(zooToken_)].router;
        _invokeApprove(zooToken_, address(dai), address(router_), amountIn_);
        amountOut = _invokeSwap(zooToken_, amountIn_, minAmountOut_, Side.Bull)[1];
        require(amountOut != 0, "L3xIssueMod: Leveraging swapping failed");
    }
    /**
     * Repay debt on Aave by swapping baseToken to quoteToken in order to repay
     */
    function _repayDebtForUser(
        IZooToken zooToken_,
        uint256 debtToRepayInBaseCeil,
        uint256 debtToRepayInQuote
    ) 
    private 
    returns (uint256 [] memory amounts)
    {

        IUniswapV2Router router_ = configs[address(zooToken_)].router;
        ILendingPool lender_ = configs[address(zooToken_)].lender;

        _invokeApprove(zooToken_, address(weth), address(router_), debtToRepayInBaseCeil);
        // Swap max amount of debtToRepayInBase of baseToken for  exact debtToRepayInQuote amount for quoteToken

        amounts = _invokeSwap(zooToken_, debtToRepayInQuote, debtToRepayInBaseCeil, Side.Bear);
        _invokeApprove(zooToken_, address(dai), address(lender_), amounts[1]);
        _invokeRepay(zooToken_, address(dai), amounts[1]);
    }

    function _borrowAvailableAmount(
        IZooToken zooToken_,
        uint256 collateral,
        uint256 amountPerUnitCollateral
    )
    private
    returns (
        uint256 quoteAmountToBorrow,
        uint256 baseAmountToBorrow
    )
    {

        address oracle = configs[address(zooToken_)].addressesProvider.getPriceOracle();
        uint256 quotePriceInETH = IPriceOracleGetter(oracle).getAssetPrice(address(dai));

        uint256 availableBorrowsETH = collateral.mul(amountPerUnitCollateral).div(1 ether);

        // borrow 99.9% of what available (otherwise reverts)
        quoteAmountToBorrow = availableBorrowsETH.mul(BORROW_PORTION_FACTOR).div(quotePriceInETH);
        _invokeBorrow(zooToken_, address(dai), quoteAmountToBorrow);
        baseAmountToBorrow = availableBorrowsETH.mul(BORROW_PORTION_FACTOR).div(1 ether);
    }

    /**
     * Instructs the ZooToken to call swap tokens of the ERC20 token on target Uniswap like dex 
     *
     * @param zooToken_        SetToken instance to invoke
     * @param amountExact_          Exact Amount of token to exchange
     * Considered amountIn if Side.Bull and amountOut if Side.Bear
     * @param amountEdge_          Amount of token to exchange in return for amountExact_
     * Considered amountMax to be in if Side.Bull and amountMin to be out if Side.Bear
     */
    function _invokeSwap(
        IZooToken zooToken_,
        uint256 amountExact_,
        uint256 amountEdge_,
        Side side
    )
    private 
    returns (uint256[] memory amounts)
    {
        IUniswapV2Router router_ = configs[address(zooToken_)].router;
        address[] memory path = new address[](2);
        path[0] = side == Side.Bull?  address(dai): address(weth); 
        path[1] = side == Side.Bull?  address(weth): address(dai);
        string memory callString = side == Side.Bull? 
          "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)":
          "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)";
        // TODO: Investigate might Change all to swapTokensForExactTokens
        bytes memory callData = abi.encodeWithSignature(
            callString,
            amountExact_,
            amountEdge_,
            path,
            address(zooToken_),
            block.timestamp     
        );
        bytes memory data = zooToken_.invoke(address(router_), 0, callData);
        amounts = abi.decode(data, (uint256[]));
    }
    /**
     * Instructs the SetToken to set approvals of the ERC20 token to a spender.
     *
     * @param _setToken        SetToken instance to invoke
     * @param _token           ERC20 token to approve
     * @param _spender         The account allowed to spend the SetToken's balance
     * @param _quantity        The quantity of allowance to allow
     */
    function _invokeApprove(
        IZooToken _setToken,
        address _token,
        address _spender,
        uint256 _quantity
    )
       private 
    {
        bytes memory callData = abi.encodeWithSignature("approve(address,uint256)", _spender, _quantity);
        _setToken.invoke(_token, 0, callData);
    }

    function _invokeDeposit(
        IZooToken zooToken_,
        address asset,
        uint256 amount 
    )
       private 
    {

        ILendingPool lender_ = configs[address(zooToken_)].lender;
        bytes memory callData = abi.encodeWithSignature(
            "deposit(address,uint256,address,uint16)", 
            address(asset),  // asset to deposit
            amount,  // amount
            address(zooToken_), // onBehalfOf
            0    // referralCode
        );
        zooToken_.invoke(address(lender_), 0, callData);
    }

    function _invokeBorrow(
        IZooToken zooToken_,
        address asset,
        uint256 amount 
    )
       private 
    {

        ILendingPool lender_ = configs[address(zooToken_)].lender;
        bytes memory callData = abi.encodeWithSignature(
            "borrow(address,uint256,uint256,uint16,address)", 
            address(asset),  // asset to deposit
            amount,  // amount
            1, // StableInterestMode
            0,    // referralCode
            address(zooToken_) // onBehalfOf
        );
        zooToken_.invoke(address(lender_), 0, callData);
    }

    function _invokeWithdraw(
        IZooToken zooToken_,
        address asset,
        uint256 amount 
    )
       private 
       returns (uint256 amountToWithdraw)
    {

        ILendingPool lender_ = configs[address(zooToken_)].lender;
        bytes memory callData = abi.encodeWithSignature(
            "withdraw(address,uint256,address)", 
            address(asset),  // asset to deposit
            amount,  // amount
            address(zooToken_) // onBehalfOf
        );
        bytes memory data = zooToken_.invoke(address(lender_), 0, callData);
        amountToWithdraw = abi.decode(data, (uint256));

    }

    function _invokeRepay(
        IZooToken zooToken_,
        address asset,
        uint256 amount 
    )
       private 
    {

        ILendingPool lender_ = configs[address(zooToken_)].lender;
        bytes memory callData = abi.encodeWithSignature(
            "repay(address,uint256,uint256,address)", 
            address(asset),  // asset to deposit
            amount,  // amount
            1, // StableInterestMode
            address(zooToken_) // onBehalfOf
        );
        zooToken_.invoke(address(lender_), 0, callData);
    }
}