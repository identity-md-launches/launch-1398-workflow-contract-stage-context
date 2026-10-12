// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {SnitchBase} from "./SnitchBase.t.sol";
import {
    Bytes32SymbolToken,
    BombSymbolToken,
    GasBurningSymbolToken,
    MockERC20,
    RevertingSymbolToken
} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

contract SnitchDeskTest is SnitchBase {
    // ---- construction ----

    function test_constructorWiresEverything() public view {
        assertEq(desk.owner(), OWNER);
        assertEq(address(desk.snitch()), address(snitch));
        assertEq(address(desk.imd()), address(imd));
        assertEq(address(desk.intake()), address(intake));
        assertEq(desk.oracleSigner(), SIGNER);
        assertEq(desk.action(), bytes32("oracle.request@oracle-1"));
        assertEq(desk.caseFee(), FEE);
        assertEq(desk.panelSize(), 12);
        assertEq(desk.quorum(), 8);
        assertFalse(desk.failureHook());
        assertEq(address(reports.desk()), address(desk));
        assertEq(address(reports.art()), address(art));
        assertEq(reports.name(), "Snitch Reports");
        assertEq(reports.symbol(), "REPORT");
        assertEq(desk.oraclePrice(), PRICE);
        // The constructor touched no SNITCH: the factory still holds the whole supply minus funding.
        assertEq(snitch.balanceOf(address(desk)), 0);
    }

    function test_constructorRefusesZeroAddresses() public {
        vm.expectRevert(SnitchDesk.ZeroAddress.selector);
        new SnitchDesk(OWNER, address(0), address(imd), address(intake), SIGNER, address(art));
        vm.expectRevert(SnitchDesk.ZeroAddress.selector);
        new SnitchDesk(OWNER, address(snitch), address(imd), address(0), SIGNER, address(art));
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new SnitchDesk(OWNER, address(snitch), address(imd), address(intake), address(0), address(art));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SnitchDesk(address(0), address(snitch), address(imd), address(intake), SIGNER, address(art));
    }

    // ---- openCase ----

    function test_openCasePullsBothFeesAndAsksTheIntake() public {
        uint256 aliceSnitch = snitch.balanceOf(alice);
        uint256 aliceImd = imd.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.CaseOpened(
            1, alice, 0, address(pepe), wallet, 21_004_118, 21_077_903, "PEPE", FEE, PRICE, requestOf(1)
        );
        uint256 caseId = open(alice, 0);

        assertEq(caseId, 1);
        assertEq(desk.caseCount(), 1);
        assertEq(snitch.balanceOf(alice), aliceSnitch - FEE);
        assertEq(snitch.balanceOf(address(desk)), FEE);
        assertEq(imd.balanceOf(alice), aliceImd - PRICE);
        assertEq(imd.balanceOf(address(desk)), 0, "IMD forwarded, not held");
        assertEq(imd.balanceOf(address(intake)), PRICE);
        assertEq(imd.allowance(address(desk), address(intake)), 0, "allowance fully used");
        assertEq(desk.caseOfRequest(requestOf(1)), 1);

        SnitchTypes.Case memory c = desk.getCase(1);
        assertEq(c.opener, alice);
        assertEq(c.openedAt, block.timestamp);
        assertEq(c.kind, 0);
        assertEq(uint8(c.status), uint8(SnitchTypes.Status.Open));
        assertEq(c.token, address(pepe));
        assertEq(c.wallet, wallet);
        assertEq(c.fromBlock, 21_004_118);
        assertEq(c.toBlock, 21_077_903);
        assertEq(c.askedPanelSize, 12);
        assertEq(c.askedQuorum, 8);
        assertEq(c.fee, FEE);
        assertEq(c.symbol, "PEPE");
        assertEq(c.figure, 0);

        (, bytes memory body,,, address asset, uint256 amount, bool withFailure) = intake.stored(requestOf(1));
        assertEq(asset, address(imd));
        assertEq(amount, PRICE);
        assertFalse(withFailure);
        assertEq(body, desk.body(0, address(pepe), wallet, 21_004_118, 21_077_903));
    }

    function test_bodyIsTheDocumentedJson() public view {
        string memory body = string(desk.body(0, address(pepe), wallet, 21_004_118, 21_077_903));
        assertTrue(contains(body, '{"v":1,"question":"Did the address '));
        assertTrue(contains(body, " send zero units of the ERC-20 token at "));
        assertTrue(contains(body, '"chainId":1,"window":{"fromBlock":21004118,"toBlock":21077903},"answerType":"bool"'));
        assertTrue(
            contains(body, '"evidence":"chain","panelSize":12,"quorum":8,"validForSeconds":1800,"definitions":{')
        );
        assertTrue(contains(body, "Report the sum as the figure."));
        assertLt(bytes(body).length, 2000);

        string memory early = string(desk.body(1, address(pepe), wallet, 1, 2));
        assertTrue(contains(early, " receive any units of the ERC-20 token at "));
        assertTrue(contains(early, "Answer true if that sum is greater than zero"));
    }

    function test_openCaseRejectsBadInput() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadKind.selector, 2));
        desk.openCase(2, address(pepe), wallet, 1, 2);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.TokenHasNoCode.selector, address(0x1234)));
        desk.openCase(0, address(0x1234), wallet, 1, 2);
        vm.expectRevert(SnitchDesk.ZeroWallet.selector);
        desk.openCase(0, address(pepe), address(0), 1, 2);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadBlockRange.selector, 5, 5));
        desk.openCase(0, address(pepe), wallet, 5, 5);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadBlockRange.selector, 6, 5));
        desk.openCase(0, address(pepe), wallet, 6, 5);
        uint64 future = uint64(block.number) + 1;
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadBlockRange.selector, 1, future));
        desk.openCase(0, address(pepe), wallet, 1, future);
        // toBlock == block.number is allowed
        desk.openCase(0, address(pepe), wallet, 1, uint64(block.number));
        vm.stopPrank();
    }

    function test_openCaseNeedsBothApprovalsAndBalances() public {
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        snitch.approve(address(desk), type(uint256).max);
        imd.approve(address(desk), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, FEE));
        desk.openCase(0, address(pepe), wallet, 1, 2);
        vm.stopPrank();

        vm.prank(FACTORY);
        snitch.transfer(poor, FEE);
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, PRICE));
        desk.openCase(0, address(pepe), wallet, 1, 2);

        imd.mint(poor, PRICE);
        vm.prank(poor);
        imd.approve(address(desk), 0);
        vm.prank(poor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(desk), 0, PRICE)
        );
        desk.openCase(0, address(pepe), wallet, 1, 2);
    }

    function test_openCaseFollowsTheLivePriceAndFee() public {
        intake.setPrice(desk.DEFAULT_ACTION(), address(imd), 0.75 ether);
        vm.prank(OWNER);
        desk.setCaseFee(1 ether);
        uint256 before = imd.balanceOf(alice);
        open(alice, 1);
        assertEq(imd.balanceOf(alice), before - 0.75 ether);
        assertEq(desk.getCase(1).fee, 1 ether);
        assertEq(snitch.balanceOf(address(desk)), 1 ether);
    }

    function test_openCaseWithZeroFeeHoldsNothing() public {
        vm.prank(OWNER);
        desk.setCaseFee(0);
        uint256 before = snitch.balanceOf(alice);
        open(alice, 0);
        assertEq(snitch.balanceOf(alice), before);
        assertTrue(answer(1, true, 0));
        assertEq(snitch.balanceOf(desk.BURN()), 0);
    }

    function test_openCaseRevertsWhenTheActionIsNotSold() public {
        vm.prank(OWNER);
        desk.setAction(bytes32("oracle.request@oracle-2"));
        vm.prank(alice);
        vm.expectRevert("ActionNotSold");
        desk.openCase(0, address(pepe), wallet, 1, 2);
    }

    function test_openCaseWithLimitsRefusesAFeeOrPriceAboveTheLimit() public {
        // the opener was quoted 200,000 SNITCH + 0.5 IMD and holds an unlimited approval
        vm.prank(OWNER);
        desk.setCaseFee(2_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.FeeAboveLimit.selector, 2_000_000 ether, FEE));
        desk.openCaseWithLimits(0, address(pepe), wallet, 21_004_118, 21_077_903, FEE, PRICE);

        vm.prank(OWNER);
        desk.setCaseFee(FEE);
        intake.setPrice(desk.DEFAULT_ACTION(), address(imd), 5 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.PriceAboveLimit.selector, 5 ether, PRICE));
        desk.openCaseWithLimits(0, address(pepe), wallet, 21_004_118, 21_077_903, FEE, PRICE);
        assertEq(desk.caseCount(), 0, "nothing opened, nothing pulled");
        assertEq(snitch.balanceOf(alice), 10 * FEE);
        assertEq(imd.balanceOf(alice), 10 * PRICE);

        // exactly the quoted amounts are accepted, and the case is the same as openCase's
        intake.setPrice(desk.DEFAULT_ACTION(), address(imd), PRICE);
        vm.prank(alice);
        uint256 caseId = desk.openCaseWithLimits(0, address(pepe), wallet, 21_004_118, 21_077_903, FEE, PRICE);
        assertEq(caseId, 1);
        assertEq(desk.getCase(1).fee, FEE);
        assertEq(snitch.balanceOf(alice), 10 * FEE - FEE);
        assertEq(imd.balanceOf(alice), 10 * PRICE - PRICE);
        assertEq(desk.caseOfRequest(requestOf(1)), 1);
        assertEq(desk.intakeOfRequest(requestOf(1)), address(intake));
        assertTrue(answer(1, true, 0));
    }

    function test_openCaseRefusesARequestIdAlreadyBound() public {
        open(alice, 0);
        // the intake hands out an id it already gave this desk
        intake.setCount(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.DuplicateRequestId.selector, requestOf(1)));
        desk.openCase(0, address(pepe), wallet, 1, 2);
        assertEq(desk.caseOfRequest(requestOf(1)), 1, "the first case keeps its binding");
    }

    function test_caseNumbersStartAtOneAndCount() public {
        assertEq(open(alice, 0), 1);
        assertEq(open(bob, 1), 2);
        assertEq(open(alice, 1), 3);
        assertEq(desk.caseCount(), 3);
        assertEq(desk.getCase(2).opener, bob);
        assertEq(desk.getCase(2).kind, 1);
    }

    // ---- symbol snapshot ----

    function test_symbolSnapshotAcceptsCleanSymbols() public {
        pepe.setSymbol("abcDEF12345");
        open(alice, 0);
        assertEq(desk.getCase(1).symbol, "abcDEF12345");
    }

    function test_symbolSnapshotFallsBackToShortAddress() public {
        string memory short_ = art.shortAddress(address(pepe));

        pepe.setSymbol("TOO-LONG-SYM");
        assertEq(desk.getCase(open(alice, 0)).symbol, short_, "12 characters");
        pepe.setSymbol("PE PE");
        assertEq(desk.getCase(open(alice, 0)).symbol, short_, "space");
        pepe.setSymbol("");
        assertEq(desk.getCase(open(alice, 0)).symbol, short_, "empty");
        pepe.setSymbol(unicode"PÉPE");
        assertEq(desk.getCase(open(alice, 0)).symbol, short_, "non-ascii");
        pepe.setSymbol("<svg>");
        assertEq(desk.getCase(open(alice, 0)).symbol, short_, "markup");

        address[4] memory odd = [
            address(new RevertingSymbolToken()),
            address(new Bytes32SymbolToken()),
            address(new GasBurningSymbolToken()),
            address(new BombSymbolToken())
        ];
        for (uint256 i = 0; i < odd.length; ++i) {
            vm.prank(alice);
            uint256 id = desk.openCase(0, odd[i], wallet, 1, 2);
            assertEq(desk.getCase(id).symbol, art.shortAddress(odd[i]));
        }
    }

    // ---- the answer ----

    function test_validAnswerStoresVerdictAndBurnsTheFee() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory sig = sign(a);

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.CaseAnswered(caseId, true, 0, 12, 11, a.requestId, a.questionHash);
        (bool ok,) = intake.complete(requestOf(caseId), a, sig);
        assertTrue(ok, "did not fit in 200,000 gas");

        SnitchTypes.Case memory c = desk.getCase(caseId);
        assertEq(uint8(c.status), uint8(SnitchTypes.Status.Answered));
        assertTrue(c.verdict);
        assertEq(c.figure, 0);
        assertEq(c.panelSize, 12);
        assertEq(c.agreed, 11);
        assertEq(c.issuedAt, a.issuedAt);
        assertTrue(desk.consumed(a.requestId));
        assertEq(snitch.balanceOf(address(desk)), 0);
        assertEq(snitch.balanceOf(desk.BURN()), FEE);
    }

    function test_noAnswerIsStoredNotRefused() public {
        uint256 caseId = open(alice, 1);
        assertTrue(answer(caseId, false, 1234));
        SnitchTypes.Case memory c = desk.getCase(caseId);
        assertEq(uint8(c.status), uint8(SnitchTypes.Status.Answered));
        assertFalse(c.verdict);
        assertEq(c.figure, 1234);
        assertEq(snitch.balanceOf(desk.BURN()), FEE);
    }

    function test_callbackGasStaysUnderTheStipend() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, false, type(uint256).max);
        bytes memory sig = sign(a);
        bytes memory data = abi.encodeWithSelector(desk.onOracleResult.selector, requestOf(caseId), a, sig);
        vm.prank(address(intake));
        uint256 before = gasleft();
        (bool ok,) = address(desk).call(data);
        uint256 used = before - gasleft();
        assertTrue(ok);
        assertLt(used, 160_000, "callback too close to the 200,000 stipend");
    }

    function test_callbackIsAcceptedUnderExactlyTheStipend() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, false, type(uint256).max);
        bytes memory sig = sign(a);
        bytes memory data = abi.encodeWithSelector(desk.onOracleResult.selector, requestOf(caseId), a, sig);
        vm.prank(address(intake));
        (bool ok,) = address(desk).call{gas: 200_000}(data);
        assertTrue(ok);
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Answered));
    }

    function test_feeAboveUint128Refused() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.FeeTooLarge.selector, uint256(type(uint128).max) + 1));
        desk.setCaseFee(uint256(type(uint128).max) + 1);
        vm.prank(OWNER);
        desk.setCaseFee(type(uint128).max);
        assertEq(desk.caseFee(), type(uint128).max);
    }

    function test_callbackFromAnyoneButTheIntakeReverts() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory sig = sign(a);
        vm.prank(alice);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(requestOf(caseId), a, sig);
        vm.prank(OWNER);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(requestOf(caseId), a, sig);
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open));
    }

    function test_callbackForUnknownRequestReverts() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory sig = sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.UnknownRequest.selector, bytes32(uint256(99))));
        desk.onOracleResult(bytes32(uint256(99)), a, sig);
    }

    // ---- the intake a case was asked at ----

    function test_openCaseBindsTheIntakeItAskedAt() public {
        uint256 caseId = open(alice, 0);
        assertEq(desk.intakeOfRequest(requestOf(caseId)), address(intake));
        assertEq(desk.intakeOfRequest(bytes32(uint256(99))), address(0));
    }

    function test_answerFromTheAskedIntakeLandsAfterSetIntake() public {
        MockIntake other = new MockIntake();
        other.setCount(100); // ids that do not collide with the first intake's
        other.setPrice(desk.DEFAULT_ACTION(), address(imd), PRICE);

        uint256 caseId = open(alice, 0);
        vm.prank(OWNER);
        desk.setIntake(address(other));

        // the new intake is not the one the case was asked at
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory sig = sign(a);
        vm.prank(address(other));
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(requestOf(caseId), a, sig);

        // the old intake's writer lands the answer under the stipend
        (bool ok,) = intake.complete(requestOf(caseId), a, sig);
        assertTrue(ok, "the intake the case was asked at must be able to answer it");
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Answered));
        assertEq(snitch.balanceOf(desk.BURN()), FEE);

        // a case opened after the move is asked at, and answered by, the new intake only
        uint256 later = open(bob, 1);
        bytes32 laterId = keccak256(abi.encode("intake", 101));
        assertEq(desk.caseOfRequest(laterId), later);
        assertEq(desk.intakeOfRequest(laterId), address(other));
        assertEq(imd.balanceOf(address(other)), PRICE);
        OracleAttestation.Attestation memory b = attestationFor(later, false, 1);
        bytes memory sigB = sign(b);
        vm.prank(address(intake));
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(laterId, b, sigB);
        (ok,) = other.complete(laterId, b, sigB);
        assertTrue(ok);
        assertFalse(desk.getCase(later).verdict);
    }

    function test_failureFromTheAskedIntakeLandsAfterSetIntake() public {
        vm.prank(OWNER);
        desk.setFailureHook(true);
        MockIntake other = new MockIntake();
        other.setCount(100);
        other.setPrice(desk.DEFAULT_ACTION(), address(imd), PRICE);

        uint256 caseId = open(alice, 0);
        vm.prank(OWNER);
        desk.setIntake(address(other));

        vm.prank(address(other));
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleFailure(requestOf(caseId), 2, bytes32("disagreed"), 3, 12, "");
        assertFalse(desk.failed(caseId));

        assertTrue(intake.fail(requestOf(caseId), 2, bytes32("disagreed"), 3, 12));
        assertTrue(desk.failed(caseId));
        uint256 before = snitch.balanceOf(alice);
        vm.prank(alice);
        desk.dropCase(caseId);
        assertEq(snitch.balanceOf(alice), before + FEE);
    }

    function test_ownerCannotStampAnOpenCaseThroughTheSetters() public {
        uint256 caseId = open(alice, 0);
        uint256 ownerKey = 0xA11CE;
        vm.startPrank(OWNER);
        desk.setOracleSigner(vm.addr(ownerKey));
        desk.setIntake(OWNER);
        OracleAttestation.Attestation memory a = attestationFor(caseId, false, 123);
        bytes memory sig = signWith(ownerKey, a);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(requestOf(caseId), a, sig);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleFailure(requestOf(caseId), 1, bytes32("body_invalid"), 0, 0, "");
        vm.stopPrank();
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open));
        assertFalse(desk.failed(caseId));
        assertEq(snitch.balanceOf(address(desk)), FEE);
    }

    function test_answerForAnotherWindowReverts() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        a.fromBlock = 1;
        a.toBlock = 2;
        a.questionHash = keccak256("something else");
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.WrongWindow.selector, 1, 2));

        a = attestationFor(caseId, true, 0);
        a.toBlock = a.toBlock + 1;
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.WrongWindow.selector, a.fromBlock, a.toBlock));

        a = attestationFor(caseId, true, 0);
        a.fromBlock = a.fromBlock - 1;
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.WrongWindow.selector, a.fromBlock, a.toBlock));

        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open), "nothing stored");
        assertEq(snitch.balanceOf(address(desk)), FEE, "nothing burned");
        assertTrue(answer(caseId, true, 0), "the case's own window lands");
    }

    function test_callbackForSettledCaseReverts() public {
        uint256 caseId = open(alice, 0);
        assertTrue(answer(caseId, true, 0));
        OracleAttestation.Attestation memory a = attestationFor(caseId, false, 5);
        a.requestId = keccak256("second answer");
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        assertTrue(desk.getCase(caseId).verdict, "first answer stands");

        // dropped cases cannot be answered either
        uint256 second = open(alice, 0);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        desk.dropCase(second);
        OracleAttestation.Attestation memory b = attestationFor(second, true, 0);
        expectDeliveryRevert(second, b, abi.encodeWithSelector(SnitchDesk.NotOpen.selector, second));
    }

    function test_oracleRequestIdIsConsumedOnce() public {
        uint256 one = open(alice, 0);
        uint256 two = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(one, true, 0);
        assertTrue(answer(one, true, 0));
        // the same oracle request id presented for another case
        OracleAttestation.Attestation memory b = attestationFor(two, true, 0);
        b.requestId = a.requestId;
        expectDeliveryRevert(
            two, b, abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId)
        );
    }

    function test_badSignatureReverts() public {
        uint256 caseId = open(alice, 0);
        bytes memory bad = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        expectDeliveryRevertWithSignature(caseId, a, signWith(0xA11CE, a), bad);

        // tampered after signing: the verdict flipped
        bytes memory sig = sign(a);
        a.answer = abi.encode(false);
        expectDeliveryRevertWithSignature(caseId, a, sig, bad);

        // tampered figure
        a = attestationFor(caseId, true, 0);
        sig = sign(a);
        a.figure = 1;
        expectDeliveryRevertWithSignature(caseId, a, sig, bad);

        // tampered panel
        a = attestationFor(caseId, true, 0);
        sig = sign(a);
        a.agreed = 12;
        expectDeliveryRevertWithSignature(caseId, a, sig, bad);

        // signed for another consumer (another chain in the domain)
        a = attestationFor(caseId, true, 0);
        vm.chainId(4663);
        sig = sign(a);
        vm.chainId(1);
        expectDeliveryRevertWithSignature(caseId, a, sig, bad);

        // the same attestation with the right signature then lands, proving only the signature failed
        a = attestationFor(caseId, true, 0);
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open), "nothing stored");
        assertEq(snitch.balanceOf(address(desk)), FEE, "nothing burned");
    }

    function test_expiredOrFutureAttestationReverts() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        a.expiresAt = uint64(block.timestamp) - 1;
        expectDeliveryRevert(
            caseId, a, abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt)
        );

        a = attestationFor(caseId, true, 0);
        a.issuedAt = uint64(block.timestamp) + 6 minutes;
        expectDeliveryRevert(
            caseId, a, abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );

        // issued within the tolerance, expiring right now: accepted
        a = attestationFor(caseId, true, 0);
        a.issuedAt = uint64(block.timestamp) + 5 minutes;
        a.expiresAt = uint64(block.timestamp);
        assertTrue(deliver(caseId, a));
    }

    function test_wrongChainOrAnswerTypeReverts() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        a.chainId = 4663;
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.WrongChain.selector, 4663));

        a = attestationFor(caseId, true, 0);
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(uint256(1));
        expectDeliveryRevert(
            caseId,
            a,
            abi.encodeWithSelector(
                OracleAttestationConsumer.WrongAnswerType.selector,
                OracleAttestation.ANSWER_BOOL,
                OracleAttestation.ANSWER_UINT256
            )
        );
    }

    function test_weakPanelReverts() public {
        uint256 caseId = open(alice, 0);

        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        a.panelSize = 11;
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.PanelTooWeak.selector, 11, 8, 11));

        a = attestationFor(caseId, true, 0);
        a.quorum = 7;
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.PanelTooWeak.selector, 12, 7, 11));

        a = attestationFor(caseId, true, 0);
        a.agreed = 7;
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.PanelTooWeak.selector, 12, 8, 7));

        // exactly the asked panel, agreed == quorum, is accepted
        a = attestationFor(caseId, true, 0);
        a.agreed = 8;
        assertTrue(deliver(caseId, a));
        assertEq(desk.getCase(caseId).agreed, 8);
    }

    function test_panelMinimumsAreSnapshottedPerCase() public {
        uint256 small = open(alice, 0);
        vm.prank(OWNER);
        desk.setPanel(30, 20);
        uint256 large = open(alice, 0);
        assertEq(desk.getCase(large).askedPanelSize, 30);
        assertEq(desk.getCase(large).askedQuorum, 20);
        // the old case still accepts the panel it asked for
        assertTrue(answer(small, true, 0));
        // the new case refuses it
        OracleAttestation.Attestation memory a = attestationFor(large, true, 0);
        expectDeliveryRevert(large, a, abi.encodeWithSelector(SnitchDesk.PanelTooWeak.selector, 12, 8, 11));
    }

    // ---- dropCase ----

    function test_dropCaseRefundsAfter72Hours() public {
        uint256 caseId = open(alice, 0);
        uint256 before = snitch.balanceOf(alice);
        uint64 droppableAt = uint64(block.timestamp) + 72 hours;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.TooEarly.selector, caseId, droppableAt));
        desk.dropCase(caseId);

        vm.warp(droppableAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.TooEarly.selector, caseId, droppableAt));
        desk.dropCase(caseId);

        vm.warp(droppableAt);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.CaseDropped(caseId, FEE);
        desk.dropCase(caseId);

        assertEq(snitch.balanceOf(alice), before + FEE);
        assertEq(snitch.balanceOf(address(desk)), 0);
        assertEq(imd.balanceOf(alice), 10 * PRICE - PRICE, "IMD never refunded");
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Dropped));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        desk.dropCase(caseId);
    }

    function test_dropCaseOnlyByTheOpener() public {
        uint256 caseId = open(alice, 0);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotTheOpener.selector, caseId));
        desk.dropCase(caseId);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotTheOpener.selector, caseId));
        desk.dropCase(caseId);
    }

    function test_dropCaseRefusesAnsweredCase() public {
        uint256 caseId = open(alice, 0);
        assertTrue(answer(caseId, true, 0));
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        desk.dropCase(caseId);
    }

    function test_heldFundsAreConserved() public {
        uint256 a1 = open(alice, 0);
        uint256 b1 = open(bob, 1);
        uint256 a2 = open(alice, 1);
        assertEq(snitch.balanceOf(address(desk)), 3 * FEE);
        assertTrue(answer(b1, false, 7));
        assertEq(snitch.balanceOf(address(desk)), 2 * FEE);
        assertEq(snitch.balanceOf(desk.BURN()), FEE);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        desk.dropCase(a1);
        assertEq(snitch.balanceOf(address(desk)), FEE);
        assertTrue(answer(a2, true, 0));
        assertEq(snitch.balanceOf(address(desk)), 0);
        assertEq(snitch.balanceOf(desk.BURN()), 2 * FEE);
        assertEq(snitch.totalSupply(), 10 ** 27);
    }

    // ---- failure hook ----

    function test_failureHookLetsTheOpenerDropAtOnce() public {
        vm.prank(OWNER);
        desk.setFailureHook(true);
        uint256 caseId = open(alice, 0);
        (,,,,,, bool withFailure) = intake.stored(requestOf(caseId));
        assertTrue(withFailure);

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.CaseFailed(caseId, 2, bytes32("disagreed"), 5, 12);
        assertTrue(intake.fail(requestOf(caseId), 2, bytes32("disagreed"), 5, 12));
        assertTrue(desk.failed(caseId));
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open), "a failure moves nothing");
        assertEq(snitch.balanceOf(address(desk)), FEE);

        uint256 before = snitch.balanceOf(alice);
        vm.prank(alice);
        desk.dropCase(caseId);
        assertEq(snitch.balanceOf(alice), before + FEE);
    }

    function test_failureHookChecksSenderAndCase() public {
        vm.prank(OWNER);
        desk.setFailureHook(true);
        uint256 caseId = open(alice, 0);
        vm.prank(alice);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleFailure(requestOf(caseId), 1, bytes32("body_invalid"), 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.UnknownRequest.selector, bytes32(uint256(5))));
        desk.onOracleFailure(bytes32(uint256(5)), 1, bytes32("body_invalid"), 0, 0, "");

        assertTrue(answer(caseId, true, 0));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        desk.onOracleFailure(requestOf(caseId), 1, bytes32("body_invalid"), 0, 0, "");
    }

    function test_failureHookOffAgainstVersion1() public {
        intake.setVersion1(true);
        open(alice, 0);
        vm.prank(OWNER);
        desk.setFailureHook(true);
        vm.prank(alice);
        vm.expectRevert("ActionNotSold");
        desk.openCase(0, address(pepe), wallet, 1, 2);
        vm.prank(OWNER);
        desk.setFailureHook(false);
        open(alice, 0);
    }

    // ---- fileReport ----

    function test_fileReportMintsToTheOpenerOnce() public {
        uint256 caseId = open(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotAnswered.selector, caseId));
        desk.fileReport(caseId);

        assertTrue(answer(caseId, true, 0));
        vm.prank(bob); // anyone
        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.ReportFiled(caseId, alice);
        desk.fileReport(caseId);
        assertEq(reports.ownerOf(caseId), alice);
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Filed));

        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotAnswered.selector, caseId));
        desk.fileReport(caseId);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotAnswered.selector, 99));
        desk.fileReport(99);
    }

    // ---- owner ----

    function test_ownerSettersEmitAndTakeEffect() public {
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.CaseFeeSet(1 ether);
        desk.setCaseFee(1 ether);
        assertEq(desk.caseFee(), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.IntakeSet(address(0x1234));
        desk.setIntake(address(0x1234));
        assertEq(address(desk.intake()), address(0x1234));
        vm.expectRevert(SnitchDesk.ZeroAddress.selector);
        desk.setIntake(address(0));
        desk.setIntake(address(intake));

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.ActionSet(bytes32("x"));
        desk.setAction(bytes32("x"));
        assertEq(desk.action(), bytes32("x"));

        vm.expectEmit(true, true, true, true);
        emit OracleAttestationConsumer.OracleSignerSet(address(0x5678));
        desk.setOracleSigner(address(0x5678));
        assertEq(desk.oracleSigner(), address(0x5678));
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        desk.setOracleSigner(address(0));

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.PanelSet(30, 20);
        desk.setPanel(30, 20);
        assertEq(desk.panelSize(), 30);
        assertEq(desk.quorum(), 20);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadPanel.selector, 1, 1));
        desk.setPanel(1, 1);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadPanel.selector, 101, 50));
        desk.setPanel(101, 50);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.BadPanel.selector, 10, 11));
        desk.setPanel(10, 11);

        vm.expectEmit(true, true, true, true);
        emit SnitchDesk.FailureHookSet(true);
        desk.setFailureHook(true);
        assertTrue(desk.failureHook());
        vm.stopPrank();
    }

    function test_nonOwnerCannotSetAnything() public {
        vm.startPrank(alice);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(err);
        desk.setCaseFee(0);
        vm.expectRevert(err);
        desk.setIntake(alice);
        vm.expectRevert(err);
        desk.setAction(bytes32(0));
        vm.expectRevert(err);
        desk.setOracleSigner(alice);
        vm.expectRevert(err);
        desk.setPanel(2, 2);
        vm.expectRevert(err);
        desk.setFailureHook(true);
        vm.expectRevert(err);
        desk.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_ownershipIsTwoStepAndCannotBeRenounced() public {
        vm.prank(OWNER);
        desk.transferOwnership(bob);
        assertEq(desk.owner(), OWNER);
        assertEq(desk.pendingOwner(), bob);
        vm.prank(bob);
        desk.acceptOwnership();
        assertEq(desk.owner(), bob);

        vm.prank(bob);
        vm.expectRevert(SnitchDesk.RenounceDisabled.selector);
        desk.renounceOwnership();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        desk.renounceOwnership();
    }

    function test_ownerCannotMoveHeldSnitch() public {
        open(alice, 0);
        // No function on the desk moves SNITCH to the owner: the only outflows are the burn and
        // the refund, both tested above. Probe the usual shapes.
        string[4] memory sigs = [
            "withdraw(address,address,uint256)",
            "withdraw(address,uint256)",
            "rescue(address,uint256)",
            "sweep(address)"
        ];
        for (uint256 i = 0; i < sigs.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(desk).call(abi.encodeWithSignature(sigs[i], address(snitch), OWNER, FEE));
            assertFalse(ok, sigs[i]);
        }
        assertEq(snitch.balanceOf(address(desk)), FEE);
    }

    // ---- helpers ----

    function contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
