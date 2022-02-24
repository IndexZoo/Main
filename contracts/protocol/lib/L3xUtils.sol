/*
    Copyright 2020 Set Labs Inc.

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
pragma experimental ABIEncoderV2;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { IZooToken } from "../../interfaces/IZooToken.sol";
import { ILendingAdapter } from "../../interfaces/ILendingAdapter.sol";
import { IUniswapV2Router } from "../../interfaces/external/IUniswapV2Router.sol";
import { IExchangeAdapterV3 } from "../../interfaces/IExchangeAdapterV3.sol";
import { IPriceOracleGetter } from "../../interfaces/external/aave-v2/IPriceOracleGetter.sol";
import { Position } from "../lib/Position.sol";

/**
 * @title PreciseUnitMath
 * @author Set Protocol
 *
 * Arithmetic for fixed-point numbers with 18 decimals of precision. Some functions taken from
 * dYdX's BaseMath library.
 *
 * CHANGELOG:
 * - 9/21/20: Added safePower function
 * - 4/21/21: Added approximatelyEquals function
 */
library L3xUtils {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using Position for IZooToken;

    /* =================== Enums ==============================*/
 
    enum PPath {
        Ether,
        BorrowAsset,
        DepositAsset
    } 


    enum Side {
        Bull,
        Bear
    }

    /* ==================== Structs ============================= */

    struct LendingCallInfo {
        IZooToken zooToken;                             // Instance of ZooToken
        ILendingAdapter lendingAdapter;                 // Instance of exchange adapter contract
        address asset;                                  // Address of token being borrowed 
        uint256 amount;                                 // Amount of token to be borrowed
    }

    // The number One in precise units.
    uint256 constant internal PRECISE_UNIT = 10 ** 18;
    int256 constant internal PRECISE_UNIT_INT = 10 ** 18;

    // Max unsigned integer value
    uint256 constant internal MAX_UINT_256 = type(uint256).max;
    // Max and min signed integer value
    int256 constant internal MAX_INT_256 = type(int256).max;
    int256 constant internal MIN_INT_256 = type(int256).min;

    /**
     * Swap base token and quote token according to trade direction and  user call (i.e. issue or redeem)
     * @param zooToken_             Instance of the ZooToken to trade
     * @param adapter_              Exchange adapter 
     * @param router_               Dex Router (uniswap-like)
     * @param amountIn_            Amount to be traded
     * @param minAmountOut_         Minimum amount demanded to be the output of the swap given exact amountIn_
     */
    function swapQuoteAndBase(
        IZooToken zooToken_,
        IExchangeAdapterV3 adapter_,
        IUniswapV2Router router_,
        uint256 amountIn_, 
        uint256 minAmountOut_
      ) 
      internal 
      returns (uint256 amountOut) 
    {
        address borrowAsset = zooIsBull(zooToken_) ? zooToken_.pair().quote:zooToken_.pair().base;

        invokeApprove(zooToken_, borrowAsset, address(router_), amountIn_);
        amountOut = invokeSwap(zooToken_, adapter_, amountIn_, minAmountOut_, true)[1]; 
        require(amountOut != 0, "L3xIssueMod: Leveraging swapping failed");
    }

    /**
     * Instructs the ZooToken to call swap tokens of the ERC20 token on target Uniswap like dex 
     *
     * @param zooToken_        ZooToken instance to invoke
     * @param amountExact_          Exact Amount of token to exchange
     * Considered amountIn if shouldSwapExactTokensForTokens is true and amountOut otherwise
     * @param amountEdge_          Amount of token to exchange in return for amountExact_
     * Considered amountMax if shouldSwapExactTokensForTokens is true and amountMin otherwise
     */
    function invokeSwap(
        IZooToken zooToken_,
        IExchangeAdapterV3 adapter,
        uint256 amountExact_,
        uint256 amountEdge_,
        bool shouldSwapExactTokensForTokens_ 
    )
    internal 
    returns (uint256[] memory amounts)
    {
        address bAsset = _xnor(shouldSwapExactTokensForTokens_, zooIsBull(zooToken_))? 
             zooToken_.pair().quote:zooToken_.pair().base;
        address dAsset = _xnor(shouldSwapExactTokensForTokens_, zooIsBull(zooToken_))? 
             zooToken_.pair().base:zooToken_.pair().quote;

        (
            address target,
            uint256 callValue,
            bytes memory methodData
        ) = adapter.getTradeCalldata(
            bAsset, 
            dAsset, 
            address(zooToken_), 
            amountExact_, 
            amountEdge_, 
            shouldSwapExactTokensForTokens_,
            ""
        );
        bytes memory data = zooToken_.invoke(target, callValue, methodData);
        amounts = abi.decode(data, (uint256[]));
    }

    /**
     * Get equivalent amount in value of token w.r.t the other token based on oracle price provided by Aave.
     */
    function getEquivalentAmountViaOraclePrice(
        IZooToken zooToken_,
        address oracle,
        uint256 amount,
        PPath[2] memory path
    )
    internal 
    view
    returns (uint256 equivalentAmount)
    {
        address bAsset = zooIsBull(zooToken_) ? zooToken_.pair().quote : zooToken_.pair().base;   // borrow Token
        address dAsset = zooIsBull(zooToken_) ? zooToken_.pair().base : zooToken_.pair().quote;   // Deposit Token

        // getting price of borrowToken against depositToken
        uint256 bAssetPriceInETH = IPriceOracleGetter(oracle).getAssetPrice(bAsset); 
        uint256 dAssetPriceInETH = IPriceOracleGetter(oracle).getAssetPrice(dAsset);
        uint256[3] memory options = [1 ether, dAssetPriceInETH, bAssetPriceInETH];

        // borrow 99.9% of what available (otherwise reverts)
        equivalentAmount = amount.mul(_choices(path[0], options)).div(_choices(path[1], options));       
    }



   /**
     *  Instigates the ZooToken to deposit asset in Lender
     */
    function invokeDeposit(
        LendingCallInfo memory depositInfo_
    )
       internal 
    {
        (
            address targetLendingPool,
            uint256 callValue,
            bytes memory methodData
        ) = depositInfo_.lendingAdapter.getDepositCalldata(
            depositInfo_.asset, 
            depositInfo_.amount, 
            address(depositInfo_.zooToken)
        );
        depositInfo_.zooToken.invoke(targetLendingPool, callValue, methodData);
    }

    /**
     * Instigates ZooToken to borrow amound of asset against deposited collateral in lender
     */
    function invokeBorrow(
        LendingCallInfo memory borrowInfo_
    )
       internal 
    {
        (
            address targetLendingPool,
            uint256 callValue,
            bytes memory methodData
        ) = borrowInfo_.lendingAdapter.getBorrowCalldata(
            borrowInfo_.asset, 
            borrowInfo_.amount, 
            address(borrowInfo_.zooToken)
        );
        borrowInfo_.zooToken.invoke(targetLendingPool, callValue, methodData);
    }

    /**
     * Instigates ZooToken to repay amount of debt to Lender
     */
    function invokeRepay(
        LendingCallInfo memory repayCallInfo_
    )
       internal 
    {
        (
            address targetLendingPool,
            uint256 callValue,
            bytes memory methodData
        ) = repayCallInfo_.lendingAdapter.getRepayCalldata(
            repayCallInfo_.asset, 
            repayCallInfo_.amount, 
            address(repayCallInfo_.zooToken)
        );

        repayCallInfo_.zooToken.invoke(targetLendingPool, callValue, methodData);
    }


    /**
     * Instructs the ZooToken to set approvals of the ERC20 token to a spender.
     *
     * @param _zooToken        ZooToken instance to invoke
     * @param _token           ERC20 token to approve
     * @param _spender         The account allowed to spend the ZooToken's balance
     * @param _quantity        The quantity of allowance to allow
     */
    function invokeApprove(
        IZooToken _zooToken,
        address _token,
        address _spender,
        uint256 _quantity
    )
       internal 
    {
        bytes memory callData = abi.encodeWithSignature("approve(address,uint256)", _spender, _quantity);
        _zooToken.invoke(_token, 0, callData);
    }

    function zooIsBull(IZooToken zooToken_) internal view returns (bool)
    {
       return (zooToken_.side() == IZooToken.Side.Bull);
    }

    /**
     * Options are ordered : [Ether, DepositToken, BorrowToken]
     */
    function _choices (
        PPath pricePath, 
        uint256[3] memory options
    )
    private
    pure
    returns (uint256 )
    {
        if (pricePath == PPath.Ether)  return options[0];
        if (pricePath == PPath.DepositAsset)  return options[1];
        if (pricePath == PPath.BorrowAsset)  return options[2];
    }


    function _xnor (bool x, bool y) private pure returns (bool z) {
        z = (x || !y ) && (!x || y);
    }

}


