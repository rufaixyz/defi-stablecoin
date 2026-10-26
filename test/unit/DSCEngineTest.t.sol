// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "../../test/mocks/MockFailedMintDSC.sol";

contract DSCEngineTest is Test {
    DSCEngine private dscEngine;
    DecentralizedStablecoin private dsc;
    HelperConfig private helperConfig;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    address public USER = makeAddr("user");
    address public liquidator = makeAddr("liquidator");


    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    function setUp() external {
        helperConfig = new HelperConfig();
        (dsc, dscEngine, helperConfig) = new DeployDSC().run();

        // 2. Extract the active network addresses from the config
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
    }

    /////////////////////////
    // Constructor Tests   //
    /////////////////////////

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        // 1. We put 1 token in the token array
        tokenAddresses.push(weth);

        // 2. We put 2 price feeds in the price feed array (creating an intentional mismatch)
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        // 3. We tell Foundry to expect a specific custom error to be thrown on the very next line
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);

        // 4. We try to deploy a new Engine with the mismatched arrays
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testIfTokenaddressesAndPriceFeedAddressesSaves() public {
        // 1. We put 2 tokens in the token array
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);

        // 2. We put 2 price feeds in the price feed array
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        // 3. We deploy a new Engine with the matching arrays
        dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // 4. We check if the saved price feed addresses match the expected ones
        assertEq(dscEngine.getCollateralTokenPriceFeed(weth), wethUsdPriceFeed);
        assertEq(dscEngine.getCollateralTokenPriceFeed(wbtc), wbtcUsdPriceFeed);

        assertEq(dscEngine.getCollateralToken(0), weth);
        assertEq(dscEngine.getCollateralToken(1), wbtc);
    }

    function testIfDSCAddressIsSetCorrectly() public {
        // 1. We put 2 tokens in the token array
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);

        // 2. We put 2 price feeds in the price feed array
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        // 3. We deploy a new Engine with the matching arrays
        dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // 4. We check if the DSC address is set correctly
        assertEq(address(dscEngine.getDsc()), address(dsc));
    }

    /////////////////////////
    //  Depoosit Tests     //
    /////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ranToken.approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector, address(ranToken)));
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public {
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function testEmitsCollateralDepositedEvent() public {
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, false, true, address(dscEngine));
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    /////////////////////////
    //  mintDsc Tests     //
    /////////////////////////

    function testRevertsIfMintAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);

        vm.stopPrank();
    }

    function testMintDscUpdatesUserBalanceAndState() public {
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 amountToMint = 10 ether;
        dscEngine.mintDsc(amountToMint);

        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);

        // 4. Assert: Check the user's actual token wallet
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, amountToMint);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 amountToMint = 100000 ether;

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 100000000000000000));

        dscEngine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    function testRevertsIfHealthFactorIsBroken() public {
        vm.startPrank(USER);

        uint256 amountToMint = 10 ether;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dscEngine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    function testRevertsIfMintFails() public {
        // 1. Deploy the broken token
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();

        // 2. Setup arrays with NEW names to fix the shadowing warnings
        address[] memory mockTokenAddresses = new address[](1);
        mockTokenAddresses[0] = weth;

        address[] memory mockPriceFeedAddresses = new address[](1);
        mockPriceFeedAddresses[0] = wethUsdPriceFeed;

        // 3. Deploy a temporary mock engine attached to the broken token
        DSCEngine mockEngine = new DSCEngine(mockTokenAddresses, mockPriceFeedAddresses, address(mockDsc));

        // 4. Transfer ownership so the engine has permission to call mint()
        mockDsc.transferOwnership(address(mockEngine));

        // 5. GIVE THE USER FAKE WETH FIRST! (This was missing)
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        // 6. Start Prank and Deposit
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockEngine), AMOUNT_COLLATERAL);
        mockEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        // 7. Expect the revert and try to mint
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockEngine.mintDsc(AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    ///////////////////////////////////////////
    //  DepositCollateralAndMintDs Tests    //
    //////////////////////////////////////////

    function testCanDepositCollateralAndMintDsc() public {
        // 1. Give the user fake WETH
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);

        // 2. Approve the engine to take the WETH
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // 3. Call the combined function
        uint256 amountToMint = 10 ether;
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);

        vm.stopPrank();

        // 4. Check that the user actually received the DSC tokens
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, amountToMint);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        // 1. Give the user fake WETH
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // 2. Define an absurdly large amount to guarantee a health factor failure
        uint256 massiveAmountToMint = 100000 ether;

        // 3. Catch the revert (Leave empty first to find the exact number!)
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 100000000000000000));

        // 4. Call the combined wrapper function
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, massiveAmountToMint);

        vm.stopPrank();
    }

    //////////////////////////////////
    //  redeemCollateral Tests     //
    /////////////////////////////////

    function testRedeemCollateralForDscRevertsIfCollateralIsZero() public {
        vm.prank(USER);

        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralRevertsIfHealthFactorIsBroken() public {
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 safeAmountToMint = 100 ether;
        dscEngine.mintDsc(safeAmountToMint);

        vm.expectRevert();
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfRedeemingMoreThanDeposited() public {
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.expectRevert();

        uint256 amountToRedeem = 1000 ether;
        dscEngine.redeemCollateral(weth, amountToRedeem);

        vm.stopPrank();
    }

    function testCanRedeemCollateral() public {
        // 1. Arrange: Mint WETH, approve, and deposit
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        // 2. Act: The user withdraws all of their deposited collateral
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // 3. Assert: Check the user's actual WETH wallet balance
        // They started with AMOUNT_COLLATERAL, deposited it (balance hit 0),
        // and redeemed it, so their wallet should be exactly AMOUNT_COLLATERAL again.
        uint256 userWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userWethBalance, AMOUNT_COLLATERAL);

        // 4. Assert: Check the Engine's internal ledger
        // The engine should now register that the user has $0 of collateral left
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        assertEq(collateralValueInUsd, 0);
    }

    //////////////////////
    //  burnDsc Test   =//
    //////////////////////

    function testBurnDscRevertsIfAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public {
        // 1. Arrange: Give WETH, deposit it, and mint DSC (Create the loan)
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 amountToMint = 100 ether;
        dscEngine.mintDsc(amountToMint);

        // 2. Arrange: Approve the engine to take the DSC back from the user's wallet
        dsc.approve(address(dscEngine), amountToMint);

        // 3. Act: Burn the DSC (Pay back the loan)
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();

        // 4. Assert: The user's DSC wallet balance should be back to 0
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);

        // 5. Assert: The engine's internal memory should show the user has 0 debt
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
    }

    function testCanRedeemCollateralForDsc() public {
    // 1. Arrange: Give the user WETH, deposit it, and borrow DSC
    ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
    
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    
    uint256 amountToMint = 100 ether;
    dscEngine.mintDsc(amountToMint);

    // 2. Arrange: The user MUST approve the engine to burn their DSC tokens
    dsc.approve(address(dscEngine), amountToMint);

    // 3. Act: Pay back all DSC and withdraw all WETH in one single call
    dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    vm.stopPrank();

    // 4. Assert: The user has 0 debt left
    uint256 userDscBalance = dsc.balanceOf(USER);
    assertEq(userDscBalance, 0);

    // 5. Assert: The user successfully got all their WETH back in their wallet
    uint256 userWethBalance = ERC20Mock(weth).balanceOf(USER);
    assertEq(userWethBalance, AMOUNT_COLLATERAL);
}

function testGetUsdValue() public {
    // 1. Arrange: We want to check the value of 15 WETH
    uint256 ethAmount = 15 ether;
    
    // 2. Act: Our WETH price feed is mocked at $2000. 15 * 2000 = 30,000.
    // (We add ether/1e18 because the protocol uses 18 decimals of precision)
    uint256 expectedUsd = 30000 ether; 
    
    // 3. Assert: Check that the engine calculates this correctly
    uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
    assertEq(actualUsd, expectedUsd);
}

      function testLiquidateWorksAndImprovesHealthFactor() public {

        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        // 1. THE VICTIM SETUP 
        // Victim deposits 10 WETH (at $2,000/ETH = $20,000)
        vm.startPrank(USER); 
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        
        // Victim borrows 100 DSC ($100). Completely safe right now!
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();

        // 2. THE MARKET CRASH
        // Ethereum price plummets from $2,000 down to $18
        // 10 WETH is now only worth $180. The 50% threshold means they can only safely borrow $90.
        // Because they borrowed $100, their health factor is officially broken.
        int256 ethCrashPrice = 18e8; 
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethCrashPrice);

        // 3. THE LIQUIDATOR SETUP
        // We give a random liquidator 20 WETH so they can mint the 100 DSC needed for the liquidation
        uint256 collateralToCover = 20 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover); 

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, 100 ether); 
        
        // 4. THE EXECUTION
        // Liquidator approves the engine to take their 100 DSC and liquidates the victim
        dsc.approve(address(dscEngine), 100 ether);
        dscEngine.liquidate(weth, USER, 100 ether); 
        vm.stopPrank();

        // 5. THE ASSERTION
        // Check that the victim's DSC balance is now exactly 0 (debt wiped)
        uint256 expectedVictimDebt = 0;
        (uint256 actualVictimDebt, ) = dscEngine.getAccountInformation(USER);
        assertEq(actualVictimDebt, expectedVictimDebt);
    }

    function testLiquidateRevertsIfHealthFactorIsOk() public {
        // 1. THE SETUP (Safe Loan)
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();

        // 2. THE LIQUIDATOR ATTEMPT
        uint256 debtToCover = 10 ether;
        
        // Give liquidator some WETH just to pay gas/make the transaction realistic
        ERC20Mock(weth).mint(liquidator, debtToCover);
        
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), debtToCover);
        
        // 3. THE ASSERTION
        // Tell Foundry to expect the exact custom error from your engine
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testLiquidatorGetsCollateralAndBonus() public {

        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        // Setup Victim
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();

        // Crash Price to $18/ETH
        int256 ethCrashPrice = 18e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethCrashPrice);

        // Setup Liquidator
        uint256 debtToCover = 100 ether;
        ERC20Mock(weth).mint(liquidator, 20 ether);
        
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), 20 ether);
        dscEngine.depositCollateralAndMintDsc(weth, 20 ether, debtToCover);
        dsc.approve(address(dscEngine), debtToCover);

        // Execute Liquidation
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        // Assert Liquidator gained WETH
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        
        // They started with 20, deposited 20 (balance 0). 
        // After liquidating, their balance should be greater than 0 from the seized collateral.
        assert(liquidatorWethBalance > 0);
    }

    function testLiquidateRevertsIfHealthFactorNotImproved() public {
        // 1. THE SETUP

        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();

        // 2. THE CRASH 
        // Ethereum crashes to $18. Victim is severely undercollateralized.
        int256 ethCrashPrice = 18e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethCrashPrice);

        // 3. THE LIQUIDATOR SETUP
        // The liquidator only attempts to pay off a tiny amount of debt (1 DSC)
        uint256 tinyDebtToCover = 1 ether; 
        
        ERC20Mock(weth).mint(liquidator, 100 ether);
        
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), 100 ether);
        dscEngine.depositCollateralAndMintDsc(weth, 100 ether, tinyDebtToCover);
        dsc.approve(address(dscEngine), tinyDebtToCover);
        
        // 4. THE EXECUTION & ASSERTION
        // Because 1 DSC is paid, but 1.10 worth of WETH is taken, the health factor drops.
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dscEngine.liquidate(weth, USER, tinyDebtToCover);
        vm.stopPrank();
    }
}
