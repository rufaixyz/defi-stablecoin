// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
    

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStablecoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;
    address[] public usersWithCollateralDeposited;
    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max; 



    constructor(DSCEngine _dscEngine, DecentralizedStablecoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        weth = ERC20Mock(dsce.getCollateralToken(0));
        wbtc = ERC20Mock(dsce.getCollateralToken(1));
    }

    // Foundry will pass in a random seed and a random amount
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // 1. Pick a valid token based on the random seed
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        
        // 2. bound() forces the random amount to be between 1 and MAX_DEPOSIT_SIZE
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        // 3. Give the random fuzzer address money, approve, and deposit
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    // Helper function: if seed is even, return WETH. If odd, return WBTC.
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // 1. Pick a valid token
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        // 2. Find out how much collateral this specific random address ACTUALLY has deposited
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));

        // 3. If they have 0 collateral, skip this fuzz run completely so we don't crash
        if (maxCollateralToRedeem == 0) {
            return; 
        }

        // 4. Bound the random amount so they don't try to withdraw more than they own
        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);

        // 5. Execute the valid redeem
        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 amountDsc, uint256 addressSeed) public {
        // 1. If nobody has deposited collateral yet, we can't mint. Skip this run.
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        // 2. Pick a random user from our list of people who actually have collateral
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        // 3. Find out exactly how much they are allowed to borrow safely
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        
        // Because of the 200% overcollateralization rule, they can only borrow up to half their collateral value
        uint256 maxDscToMint = (collateralValueInUsd / 2);

        // If they have already borrowed their maximum limit, skip this run
        if (maxDscToMint <= totalDscMinted) {
            return;
        }

        // Calculate the remaining amount they are allowed to mint
        uint256 maxMintAmount = maxDscToMint - totalDscMinted;

        // 4. Bound the fuzzer's random amount so they don't break their health factor
        amountDsc = bound(amountDsc, 1, maxMintAmount);

        // 5. Finally, execute a valid mint!
        vm.startPrank(sender);
        dsce.mintDsc(amountDsc);
        vm.stopPrank();
    }

    function burnDsc(uint256 amountDsc, uint256 addressSeed) public {
        // 1. Skip if no one has interacted with the protocol yet
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        // 2. Pick a random active user
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        // 3. Check how much debt they actually have
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(sender);
        
        // If they have 0 debt, they can't burn anything. Skip this run.
        if (totalDscMinted == 0) {
            return;
        }

        // 4. Bound the random amount so they don't try to burn more than they owe
        amountDsc = bound(amountDsc, 1, totalDscMinted);

        // 5. Execute the burn (Remember they must approve the engine to take the tokens first!)
        vm.startPrank(sender);
        dsc.approve(address(dsce), amountDsc);
        dsce.burnDsc(amountDsc);
        vm.stopPrank();
    }


  
}