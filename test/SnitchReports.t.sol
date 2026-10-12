// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SnitchReports} from "../src/SnitchReports.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {SnitchBase} from "./SnitchBase.t.sol";

contract SnitchReportsTest is SnitchBase {
    function test_onlyTheDeskMints() public {
        vm.prank(alice);
        vm.expectRevert(SnitchReports.OnlyDesk.selector);
        reports.mint(alice, 1);
        vm.prank(OWNER);
        vm.expectRevert(SnitchReports.OnlyDesk.selector);
        reports.mint(OWNER, 1);
        vm.prank(FACTORY);
        vm.expectRevert(SnitchReports.OnlyDesk.selector);
        reports.mint(FACTORY, 1);
        assertEq(reports.balanceOf(alice), 0);
    }

    function test_tokenIdIsTheCaseNumber() public {
        open(bob, 1); // case 1, left open
        uint256 caseId = open(alice, 0); // case 2
        assertTrue(answer(caseId, false, 99));
        desk.fileReport(caseId);
        assertEq(reports.ownerOf(2), alice);
        assertEq(reports.balanceOf(alice), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        reports.ownerOf(1);
    }

    function test_tokenURIRendersTheStoredCase() public {
        uint256 caseId = open(alice, 0);
        assertTrue(answer(caseId, true, 0));
        desk.fileReport(caseId);
        SnitchTypes.Case memory c = desk.getCase(caseId);
        assertEq(reports.tokenURI(caseId), art.tokenURI(caseId, c));
        assertEq(uint8(c.status), uint8(SnitchTypes.Status.Filed));
    }

    function test_tokenURIOfUnmintedReportReverts() public {
        uint256 caseId = open(alice, 0);
        assertTrue(answer(caseId, true, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, caseId));
        reports.tokenURI(caseId);
    }

    function test_reportsTransferLikeAnyERC721() public {
        uint256 caseId = open(alice, 0);
        assertTrue(answer(caseId, true, 0));
        desk.fileReport(caseId);
        vm.prank(alice);
        reports.transferFrom(alice, bob, caseId);
        assertEq(reports.ownerOf(caseId), bob);
    }

    function test_contractOpenerStillGetsItsReport() public {
        // A contract without onERC721Received: a plain mint still lands.
        NoReceiver opener = new NoReceiver();
        fund(address(opener));
        vm.prank(address(opener));
        uint256 caseId = desk.openCase(0, address(pepe), wallet, 1, 2);
        assertTrue(answer(caseId, true, 0));
        desk.fileReport(caseId);
        assertEq(reports.ownerOf(caseId), address(opener));
    }
}

contract NoReceiver {}
