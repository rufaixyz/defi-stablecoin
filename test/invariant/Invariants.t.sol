// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStablecoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        
        // This is the magic line. It tells Foundry: 
        // "Throw random data at ALL functions inside this contract."
       handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    // Every invariant test MUST start with the word "invariant_"
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        
        uint256 totalSupply = dsc.totalSupply();

    uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
    uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

    uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
    uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

    console.log("WETH Value: ", wethValue);
    console.log("WBTC Value: ", wbtcValue);
    console.log("Total DSC Supply: ", totalSupply);

    assert(wethValue + wbtcValue >= totalSupply);

    }

    function invariant_gettersShouldNotRevert() public view {

        dsce.getCollateralToken(0);
        dsce.getTokenAmountFromUsd(weth, 1e18);
        dsce.getDsc();
        dsce.getCollateralBalanceOfUser(msg.sender, weth);
        dsce.getAccountInformation(msg.sender);
        dsce.getAccountCollateralValue(msg.sender);
        dsce.getUsdValue(weth, 1e18);
        dsce.getTotalSupply();
        dsce.getDsc();

    }
    }