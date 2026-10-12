// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_nameSymbolDecimals() public view {
        assertEq(token.name(), "Snitch");
        assertEq(token.symbol(), "SNITCH");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), 10 ** 27);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        address to = address(0xCAFE);
        assertTrue(token.transfer(to, 1 ether));
        assertEq(token.balanceOf(to), 1 ether);
        assertEq(token.balanceOf(address(this)), 10 ** 27 - 1 ether);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferMoreThanBalanceReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_hasNoMintOrOwner() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        assertEq(token.totalSupply(), 10 ** 27);
    }
}
