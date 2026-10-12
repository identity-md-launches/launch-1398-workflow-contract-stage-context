// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SnitchArt} from "../src/SnitchArt.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";

/// @notice What the launch's project floor checks, rehearsed locally: constructors run on an empty
/// chain with the factory as msg.sender, the supply stays with the factory, every runtime fits
/// EIP-170 and carries no DELEGATECALL, CALLCODE or SELFDESTRUCT.
contract DeploymentTest is Test {
    address constant FACTORY = address(0xFAC70);
    address constant OWNER = 0xc91633279Dd9Fa90D69F3c1b48c18A96FBd8aB67;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant INTAKE_V2 = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    LaunchToken token;
    SnitchArt art;
    SnitchDesk desk;

    function setUp() public {
        vm.chainId(1);
        vm.startPrank(FACTORY);
        token = new LaunchToken();
        art = new SnitchArt();
        // The intake, IMD and signer have no code on the empty chain: the constructor must not care.
        desk = new SnitchDesk(OWNER, address(token), IMD, INTAKE_V2, SIGNER, address(art));
        vm.stopPrank();
    }

    function test_constructorsPreserveTheSupply() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(FACTORY), 10 ** 27);
        assertEq(token.balanceOf(address(desk)), 0);
    }

    function test_theFactoryOwnsNothing() public view {
        assertEq(desk.owner(), OWNER);
        assertEq(address(desk.reports().desk()), address(desk));
    }

    function test_runtimesAreBoundedAndHaveNoEscapeOpcodes() public view {
        address[4] memory deployed = [address(token), address(art), address(desk), address(desk.reports())];
        for (uint256 i = 0; i < deployed.length; ++i) {
            bytes memory code = deployed[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            for (uint256 j = 0; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}
