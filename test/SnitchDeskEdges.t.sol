// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {SnitchBase} from "./SnitchBase.t.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {RegistrySigner, ReentrantIntake, RevertingSigner} from "./mocks/MoreMocks.sol";

/// @notice The inputs the implementation did not necessarily plan for: a contract signer, a rotated
/// key or intake with cases in flight, malformed answer bytes and signatures, an intake that calls
/// back synchronously, a failure notice racing a real answer, and the zero request id.
contract SnitchDeskEdgesTest is SnitchBase {
    // ---- the signer ----

    function test_registrySignerVerifiesUnderTheStipend() public {
        RegistrySigner registry = new RegistrySigner();
        registry.list(SIGNER, true);
        vm.prank(OWNER);
        desk.setOracleSigner(address(registry));

        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, false, type(uint256).max);
        bytes memory sig = sign(a);
        bytes memory data = abi.encodeWithSelector(desk.onOracleResult.selector, requestOf(caseId), a, sig);
        vm.prank(address(intake));
        uint256 before = gasleft();
        (bool ok,) = address(desk).call{gas: 200_000}(data);
        uint256 used = before - gasleft();
        assertTrue(ok, "ERC-1271 verification does not fit the 200,000 gas stipend");
        assertLt(used, 190_000, "ERC-1271 path too close to the stipend");
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Answered));
    }

    function test_registrySignerRefusesAnUnlistedKey() public {
        RegistrySigner registry = new RegistrySigner();
        vm.prank(OWNER);
        desk.setOracleSigner(address(registry));
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));

        // a registry that reverts is a bad signature, not a stuck callback
        RevertingSigner reverting = new RevertingSigner();
        vm.prank(OWNER);
        desk.setOracleSigner(address(reverting));
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        // and a contract that is not a signer at all
        vm.prank(OWNER);
        desk.setOracleSigner(address(pepe));
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open));
    }

    function test_rotatingTheSignerInvalidatesTheOldKey() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory oldSig = sign(a);
        uint256 newKey = 0xB0B;
        vm.prank(OWNER);
        desk.setOracleSigner(vm.addr(newKey));
        expectDeliveryRevertWithSignature(
            caseId, a, oldSig, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        (bool ok,) = intake.complete(requestOf(caseId), a, signWith(newKey, a));
        assertTrue(ok, "the new key is refused");
    }

    // ---- the intake ----

    /// @dev Moving the desk to another intake does not strand a case in flight: the case stays
    /// bound to the intake it was asked at, which is the only one that can answer or fail it, and
    /// the new intake can neither answer the old case nor be answered by the old intake.
    function test_movingTheIntakeKeepsOpenCasesWithTheIntakeTheyWereAskedAt() public {
        uint256 caseId = open(alice, 0);
        MockIntake other = new MockIntake();
        other.setCount(1_000); // ids that do not collide with the first intake's
        vm.prank(OWNER);
        desk.setIntake(address(other));
        assertEq(desk.intakeOfRequest(requestOf(caseId)), address(intake), "the binding moved with the setting");

        // the new intake cannot answer or fail the case it did not sell
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory sig = sign(a);
        vm.prank(address(other));
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(requestOf(caseId), a, sig);
        vm.prank(address(other));
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleFailure(requestOf(caseId), 2, bytes32("disagreed"), 3, 12, "");
        assertFalse(desk.failed(caseId));

        // the case is still waiting, not stranded: the opener cannot drop it early
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SnitchDesk.TooEarly.selector, caseId, uint64(block.timestamp) + 72 hours)
        );
        desk.dropCase(caseId);

        // the old intake's writer lands the answer under the stipend and the fee burns
        (bool ok,) = intake.complete(requestOf(caseId), a, sig);
        assertTrue(ok, "the intake the case was asked at could not answer it");
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Answered));
        assertEq(snitch.balanceOf(address(desk)), 0);
        assertEq(snitch.balanceOf(desk.BURN()), FEE);
        assertEq(imd.balanceOf(address(intake)), PRICE);

        // new cases need the new intake to sell the action
        vm.prank(alice);
        vm.expectRevert("ActionNotSold");
        desk.openCase(0, address(pepe), wallet, 1, 2);
        other.setPrice(desk.DEFAULT_ACTION(), address(imd), 1 ether);
        assertEq(desk.oraclePrice(), 1 ether);
        uint256 later = open(alice, 0);
        bytes32 laterId = keccak256(abi.encode("intake", 1_001));
        assertEq(desk.caseOfRequest(laterId), later);
        assertEq(desk.intakeOfRequest(laterId), address(other));
        assertEq(imd.balanceOf(address(other)), 1 ether);

        // and the old intake cannot answer the case the new one sold
        OracleAttestation.Attestation memory b = attestationFor(later, false, 9);
        bytes memory sigB = sign(b);
        vm.prank(address(intake));
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(laterId, b, sigB);
        (ok,) = other.complete(laterId, b, sigB);
        assertTrue(ok);
        assertEq(snitch.balanceOf(desk.BURN()), 2 * FEE);
    }

    /// @dev An intake move never touches the refund path: an old case the old intake never
    /// answers is still dropped after the delay, and the IMD stays with the intake that was paid.
    function test_movingTheIntakeDoesNotBlockDroppingAnUnansweredCase() public {
        uint256 caseId = open(alice, 0);
        MockIntake other = new MockIntake();
        other.setCount(1_000);
        other.setPrice(desk.DEFAULT_ACTION(), address(imd), PRICE);
        vm.prank(OWNER);
        desk.setIntake(address(other));
        uint256 later = open(bob, 1);

        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        desk.dropCase(caseId);
        vm.prank(bob);
        desk.dropCase(later);
        assertEq(snitch.balanceOf(address(desk)), 0);
        assertEq(snitch.balanceOf(alice), 10 * FEE);
        assertEq(snitch.balanceOf(bob), 10 * FEE);
        assertEq(imd.balanceOf(address(intake)), PRICE, "the IMD is never refunded");
        assertEq(imd.balanceOf(address(other)), PRICE);

        // neither intake can revive a dropped case
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        OracleAttestation.Attestation memory b = attestationFor(later, true, 0);
        bytes memory sigB = sign(b);
        bytes32 laterId = keccak256(abi.encode("intake", 1_001));
        vm.prank(address(other));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotOpen.selector, later));
        desk.onOracleResult(laterId, b, sigB);
    }

    /// @dev The duplicate-id guard reverts the whole opening: no case number is spent, no fee or
    /// price leaves the opener, and the first case keeps its binding.
    function test_duplicateRequestIdRevertsTheWholeOpening() public {
        uint256 first = open(alice, 0);
        intake.setCount(0);
        uint256 cases = desk.caseCount();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.DuplicateRequestId.selector, requestOf(first)));
        desk.openCase(1, address(pepe), wallet, 1, 2);
        assertEq(desk.caseCount(), cases, "a refused opening spent a case number");
        assertEq(snitch.balanceOf(bob), 10 * FEE);
        assertEq(imd.balanceOf(bob), 10 * PRICE);
        assertEq(desk.caseOfRequest(requestOf(first)), first);
        assertEq(desk.getCase(first).opener, alice);
        // the id after the collision is fresh again and the opening goes through
        intake.setCount(1);
        uint256 second = open(bob, 1);
        assertEq(second, first + 1);
        assertEq(desk.caseOfRequest(requestOf(second)), second);
    }

    function test_intakeWithoutCodeCannotOpenCases() public {
        vm.prank(OWNER);
        desk.setIntake(address(0xdead1));
        vm.prank(alice);
        vm.expectRevert();
        desk.openCase(0, address(pepe), wallet, 1, 2);
        vm.expectRevert();
        desk.oraclePrice();
    }

    function test_synchronousCallbackInsideRequestIsRefused() public {
        ReentrantIntake evil = new ReentrantIntake();
        vm.prank(OWNER);
        desk.setIntake(address(evil));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        desk.openCase(0, address(pepe), wallet, 1, 2);

        evil.setMode(ReentrantIntake.Mode.OpenCaseInsideRequest);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        desk.openCase(0, address(pepe), wallet, 1, 2);

        evil.setMode(ReentrantIntake.Mode.DropCaseInsideRequest);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        desk.openCase(0, address(pepe), wallet, 1, 2);

        assertEq(desk.caseCount(), 0);
        assertEq(snitch.balanceOf(address(desk)), 0);
        assertEq(snitch.balanceOf(alice), 10 * FEE, "a reverted opening kept a fee");
        assertEq(imd.balanceOf(alice), 10 * PRICE, "a reverted opening kept the price");
    }

    // ---- malformed answers ----

    function test_malformedAnswerBytesRevertAndStoreNothing() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes32 requestId = requestOf(caseId);
        a.answer = "";
        bytes memory sig = sign(a);
        vm.expectRevert();
        intake.completeUnbounded(requestId, a, sig);

        a.answer = abi.encode(uint256(2)); // not a canonical bool
        sig = sign(a);
        vm.expectRevert();
        intake.completeUnbounded(requestId, a, sig);

        a.answer = hex"01"; // too short
        sig = sign(a);
        vm.expectRevert();
        intake.completeUnbounded(requestId, a, sig);

        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open));
        assertEq(snitch.balanceOf(address(desk)), FEE);
        assertFalse(desk.consumed(a.requestId));
    }

    function test_malformedSignaturesAreBadSignatures() public {
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory bad = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
        bytes memory good = sign(a);

        expectDeliveryRevertWithSignature(caseId, a, "", bad);
        expectDeliveryRevertWithSignature(caseId, a, new bytes(64), bad);
        expectDeliveryRevertWithSignature(caseId, a, new bytes(65), bad);
        expectDeliveryRevertWithSignature(caseId, a, abi.encodePacked(good, bytes1(0)), bad);

        // the same (r, s) with the other recovery id recovers to someone else
        bytes memory flipped = good;
        flipped[64] = flipped[64] == bytes1(uint8(27)) ? bytes1(uint8(28)) : bytes1(uint8(27));
        expectDeliveryRevertWithSignature(caseId, a, flipped, bad);

        // a malleable high-s copy of a valid signature is refused too
        (bytes32 r, bytes32 s, uint8 v) = split(good);
        bytes32 highS =
            bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        expectDeliveryRevertWithSignature(caseId, a, abi.encodePacked(r, highS, flippedV), bad);

        assertTrue(deliver(caseId, a), "the genuine signature still lands");
    }

    function test_zeroRequestIdIsUnknown() public {
        OracleAttestation.Attestation memory a;
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.UnknownRequest.selector, bytes32(0)));
        desk.onOracleResult(bytes32(0), a, "");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.UnknownRequest.selector, bytes32(0)));
        desk.onOracleFailure(bytes32(0), 1, bytes32(0), 0, 0, "");
        assertEq(uint8(desk.getCase(0).status), uint8(SnitchTypes.Status.None));
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotOpen.selector, 0));
        desk.dropCase(0);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotAnswered.selector, 0));
        desk.fileReport(0);
    }

    // ---- failure notices racing answers ----

    function test_failureThenValidAnswerStillLandsAndBurns() public {
        vm.prank(OWNER);
        desk.setFailureHook(true);
        uint256 caseId = open(alice, 0);
        assertTrue(intake.fail(requestOf(caseId), 1, bytes32("body_invalid"), 0, 0));
        assertTrue(desk.failed(caseId));
        // a failure twice is harmless
        assertTrue(intake.fail(requestOf(caseId), 2, bytes32("disagreed"), 4, 12));

        assertTrue(answer(caseId, false, 3));
        assertEq(snitch.balanceOf(desk.BURN()), FEE);
        // the recorded failure does not reopen the drop path
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        desk.dropCase(caseId);
    }

    function test_droppedAfterFailureCannotBeAnsweredOrFailedAgain() public {
        vm.prank(OWNER);
        desk.setFailureHook(true);
        uint256 caseId = open(alice, 0);
        assertTrue(intake.fail(requestOf(caseId), 2, bytes32("disagreed"), 4, 12));
        vm.prank(alice);
        desk.dropCase(caseId);
        assertFalse(intake.fail(requestOf(caseId), 2, bytes32("disagreed"), 4, 12));
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        expectDeliveryRevert(caseId, a, abi.encodeWithSelector(SnitchDesk.NotOpen.selector, caseId));
        assertEq(snitch.balanceOf(desk.BURN()), 0);
        assertEq(snitch.balanceOf(alice), 10 * FEE);
    }

    function test_failureNoticeWithoutTheHookIsStillRecordedIfTheIntakeSendsOne() public {
        // Hook off: the request has no failure selector, but the desk's function is reachable by
        // the intake regardless. It only marks the case, which is the documented behaviour.
        uint256 caseId = open(alice, 0);
        vm.prank(address(intake));
        desk.onOracleFailure(requestOf(caseId), 2, bytes32("disagreed"), 1, 12, "");
        assertTrue(desk.failed(caseId));
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open));
    }

    // ---- fees across owner changes ----

    function test_eachCaseKeepsTheFeeItPaid() public {
        uint256 first = open(alice, 0);
        vm.prank(OWNER);
        desk.setCaseFee(1 ether);
        uint256 second = open(bob, 1);
        vm.prank(OWNER);
        desk.setCaseFee(0);
        uint256 third = open(alice, 0);
        assertEq(snitch.balanceOf(address(desk)), FEE + 1 ether);

        assertTrue(answer(second, true, 0));
        assertEq(snitch.balanceOf(desk.BURN()), 1 ether);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        desk.dropCase(first);
        assertEq(snitch.balanceOf(alice), 10 * FEE);
        vm.prank(alice);
        desk.dropCase(third);
        assertEq(snitch.balanceOf(alice), 10 * FEE, "a zero-fee case refunded something");
        assertEq(snitch.balanceOf(address(desk)), 0);
    }

    function test_feeAboveTheSupplyBlocksOpening() public {
        uint256 aboveSupply = snitch.totalSupply() + 1;
        vm.prank(OWNER);
        desk.setCaseFee(aboveSupply);
        vm.prank(alice);
        vm.expectRevert();
        desk.openCase(0, address(pepe), wallet, 1, 2);
        vm.prank(OWNER);
        desk.setCaseFee(FEE);
        open(alice, 0);
    }

    // ---- ownership ----

    function test_pendingOwnerHasNoPowerUntilAccepting() public {
        vm.prank(OWNER);
        desk.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        desk.setCaseFee(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        desk.acceptOwnership();
        // the current owner can still act and re-point the transfer
        vm.prank(OWNER);
        desk.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        desk.acceptOwnership();
        vm.prank(alice);
        desk.acceptOwnership();
        assertEq(desk.owner(), alice);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        desk.setCaseFee(1);
    }

    // ---- the desk never takes ETH ----

    function test_deskRefusesEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(desk).call{value: 1}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(desk).call{value: 1}(abi.encodeWithSelector(desk.fileReport.selector, 1));
        assertFalse(ok);
        assertEq(address(desk).balance, 0);
    }

    // ---- helpers ----

    function split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }
}
