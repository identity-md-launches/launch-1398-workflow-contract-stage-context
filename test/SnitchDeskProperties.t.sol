// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {SnitchBase} from "./SnitchBase.t.sol";

/// @notice Stateless properties of the desk at its boundaries: each validation accepts exactly the
/// inputs the brief names and refuses everything else, and what is stored or moved is exactly what
/// was presented, for any value in range.
/// forge-config: default.fuzz.runs = 512
contract SnitchDeskPropertiesTest is SnitchBase {
    // ---- openCase ----

    function testFuzz_blockRangeAcceptedIffFromBelowToAtOrBelowHead(uint64 fromBlock, uint64 toBlock) public {
        toBlock = uint64(bound(toBlock, 0, block.number + 5));
        fromBlock = uint64(bound(fromBlock, 0, block.number + 5));
        bool expected = fromBlock < toBlock && toBlock <= block.number;
        vm.prank(alice);
        (bool ok,) = address(desk)
            .call(abi.encodeWithSelector(desk.openCase.selector, uint8(0), address(pepe), wallet, fromBlock, toBlock));
        assertEq(ok, expected, "block range decision");
        if (ok) {
            SnitchTypes.Case memory c = desk.getCase(1);
            assertEq(c.fromBlock, fromBlock);
            assertEq(c.toBlock, toBlock);
        } else {
            assertEq(desk.caseCount(), 0, "a refused case was counted");
            assertEq(snitch.balanceOf(address(desk)), 0, "a refused case pulled a fee");
        }
    }

    function testFuzz_onlyKindsZeroAndOneOpen(uint8 kind) public {
        vm.prank(alice);
        (bool ok,) =
            address(desk).call(abi.encodeWithSelector(desk.openCase.selector, kind, address(pepe), wallet, 1, 2));
        assertEq(ok, kind <= 1);
        if (ok) assertEq(desk.getCase(1).kind, kind);
    }

    function testFuzz_feeIsHeldExactlyThenBurnedOrRefunded(uint128 fee, bool burn) public {
        fee = uint128(bound(fee, 0, snitch.balanceOf(alice)));
        vm.prank(OWNER);
        desk.setCaseFee(fee);
        uint256 before = snitch.balanceOf(alice);

        uint256 caseId = open(alice, 1);
        assertEq(desk.getCase(caseId).fee, fee);
        assertEq(snitch.balanceOf(address(desk)), fee);
        assertEq(snitch.balanceOf(alice), before - fee);

        if (burn) {
            assertTrue(answer(caseId, true, 0));
            assertEq(snitch.balanceOf(desk.BURN()), fee);
            assertEq(snitch.balanceOf(alice), before - fee, "an answer refunded something");
        } else {
            vm.warp(block.timestamp + 72 hours);
            vm.prank(alice);
            desk.dropCase(caseId);
            assertEq(snitch.balanceOf(alice), before, "the refund is not the fee");
            assertEq(snitch.balanceOf(desk.BURN()), 0);
        }
        assertEq(snitch.balanceOf(address(desk)), 0, "the desk kept something");
    }

    function testFuzz_oraclePriceIsForwardedWhole(uint256 price) public {
        price = bound(price, 1, imd.balanceOf(alice));
        intake.setPrice(desk.DEFAULT_ACTION(), address(imd), price);
        assertEq(desk.oraclePrice(), price);
        uint256 before = imd.balanceOf(alice);
        open(alice, 0);
        assertEq(imd.balanceOf(alice), before - price);
        assertEq(imd.balanceOf(address(intake)), price);
        assertEq(imd.balanceOf(address(desk)), 0);
        assertEq(imd.allowance(address(desk), address(intake)), 0);
    }

    /// @dev The symbol snapshot keeps 1 to 11 characters of A-Z a-z 0-9 and nothing else.
    function testFuzz_symbolSnapshotKeepsOnlyShortAlphanumerics(bytes memory raw) public {
        if (raw.length > 14) {
            bytes memory cut = new bytes(14);
            for (uint256 i = 0; i < 14; ++i) {
                cut[i] = raw[i];
            }
            raw = cut;
        }
        // bias towards characters near the accepted ranges so the boundaries are hit
        for (uint256 i = 0; i < raw.length; ++i) {
            if (uint8(raw[i]) % 2 == 0) raw[i] = bytes1(uint8(0x2f + uint8(raw[i]) % 0x4c));
        }
        pepe.setSymbol(string(raw));
        bool clean = raw.length >= 1 && raw.length <= 11;
        for (uint256 i = 0; clean && i < raw.length; ++i) {
            bytes1 ch = raw[i];
            clean = (ch >= "0" && ch <= "9") || (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z");
        }
        uint256 caseId = open(alice, 0);
        string memory stored = desk.getCase(caseId).symbol;
        if (clean) {
            assertEq(stored, string(raw));
        } else {
            assertEq(stored, art.shortAddress(address(pepe)));
        }
    }

    // ---- the answer ----

    function testFuzz_panelAcceptedIffAtLeastAskedAndAgreedReachesQuorum(uint16 panelSize, uint16 quorum, uint16 agreed)
        public
    {
        panelSize = uint16(bound(panelSize, 0, 30));
        quorum = uint16(bound(quorum, 0, 30));
        agreed = uint16(bound(agreed, 0, 30));
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        a.panelSize = panelSize;
        a.quorum = quorum;
        a.agreed = agreed;
        bool expected = panelSize >= 12 && quorum >= 8 && agreed >= quorum;
        assertEq(deliver(caseId, a), expected, "panel decision");
        assertEq(
            uint8(desk.getCase(caseId).status), uint8(expected ? SnitchTypes.Status.Answered : SnitchTypes.Status.Open)
        );
    }

    function testFuzz_windowAcceptedIffNotExpiredAndNotPreSigned(uint32 issuedAhead, uint32 expiredAgo, bool future)
        public
    {
        issuedAhead = uint32(bound(issuedAhead, 0, 10 minutes));
        expiredAgo = uint32(bound(expiredAgo, 0, 1 hours));
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, false, 7);
        a.issuedAt = uint64(block.timestamp) + issuedAhead;
        a.expiresAt = future ? uint64(block.timestamp) + expiredAgo : uint64(block.timestamp) - expiredAgo;
        bool expected = issuedAhead <= 5 minutes && (future || expiredAgo == 0);
        assertEq(deliver(caseId, a), expected, "window decision");
        if (expected) assertEq(desk.getCase(caseId).issuedAt, a.issuedAt);
    }

    function testFuzz_answerIsStoredVerbatim(bool verdict, uint256 figure, uint16 extra) public {
        uint256 caseId = open(alice, uint8(figure % 2));
        OracleAttestation.Attestation memory a = attestationFor(caseId, verdict, figure);
        a.panelSize = uint16(bound(extra, 12, 100));
        a.agreed = a.panelSize;
        assertTrue(deliver(caseId, a));
        SnitchTypes.Case memory c = desk.getCase(caseId);
        assertEq(c.verdict, verdict);
        assertEq(c.figure, figure);
        assertEq(c.panelSize, a.panelSize);
        assertEq(c.agreed, a.panelSize);
        assertEq(c.issuedAt, a.issuedAt);
        assertTrue(desk.consumed(a.requestId));
    }

    /// @dev Flip any single field after signing and the signature no longer verifies.
    function testFuzz_anyTamperedFieldBreaksTheSignature(uint8 field, uint256 delta) public {
        field = uint8(bound(field, 0, 12));
        delta = bound(delta, 1, type(uint16).max); // non-zero, and small enough that every field width changes
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        a.panelSize = 20;
        a.quorum = 10;
        a.agreed = 15;
        bytes memory sig = sign(a);
        if (field == 0) a.requestId = bytes32(uint256(a.requestId) ^ delta);
        else if (field == 1) a.questionHash = bytes32(uint256(a.questionHash) ^ delta);
        else if (field == 2) a.answer = abi.encode(false);
        else if (field == 3) a.figure ^= delta;
        else if (field == 4) a.fromBlock ^= uint64(delta);
        else if (field == 5) a.toBlock ^= uint64(delta);
        else if (field == 6) a.blockHash = bytes32(uint256(a.blockHash) ^ delta);
        else if (field == 7) a.panelJobId = bytes32(uint256(a.panelJobId) ^ delta);
        else if (field == 8) a.panelSize = uint16(bound(delta, 12, 100) == a.panelSize ? 21 : bound(delta, 12, 100));
        else if (field == 9) a.quorum = a.quorum == 8 ? 9 : 8;
        else if (field == 10) a.agreed = a.agreed == 20 ? 19 : 20;
        else if (field == 11) a.issuedAt -= uint64(bound(delta, 1, 50));
        else a.expiresAt += uint64(bound(delta, 1, 50));
        bytes32 requestId = requestOf(caseId);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.completeUnbounded(requestId, a, sig);
        assertEq(uint8(desk.getCase(caseId).status), uint8(SnitchTypes.Status.Open));
    }

    // ---- who may call ----

    function testFuzz_onlyTheIntakeAnswers(address who) public {
        vm.assume(who != address(intake));
        uint256 caseId = open(alice, 0);
        OracleAttestation.Attestation memory a = attestationFor(caseId, true, 0);
        bytes memory sig = sign(a);
        vm.prank(who);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleResult(requestOf(caseId), a, sig);
        vm.prank(who);
        vm.expectRevert(SnitchDesk.NotTheIntake.selector);
        desk.onOracleFailure(requestOf(caseId), 1, bytes32("x"), 0, 0, "");
    }

    function testFuzz_onlyTheOpenerDrops(address who) public {
        vm.assume(who != alice);
        uint256 caseId = open(alice, 0);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(SnitchDesk.NotTheOpener.selector, caseId));
        desk.dropCase(caseId);
    }

    function testFuzz_dropAcceptedIffDelayElapsed(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, 100 hours));
        uint256 caseId = open(alice, 0);
        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        (bool ok,) = address(desk).call(abi.encodeWithSelector(desk.dropCase.selector, caseId));
        assertEq(ok, elapsed >= 72 hours, "drop timing");
    }

    function testFuzz_onlyTheOwnerSets(address who) public {
        vm.assume(who != OWNER);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
        vm.startPrank(who);
        vm.expectRevert(err);
        desk.setCaseFee(1);
        vm.expectRevert(err);
        desk.setIntake(who);
        vm.expectRevert(err);
        desk.setAction(bytes32("y"));
        vm.expectRevert(err);
        desk.setOracleSigner(who);
        vm.expectRevert(err);
        desk.setPanel(3, 2);
        vm.expectRevert(err);
        desk.setFailureHook(true);
        vm.expectRevert(err);
        desk.renounceOwnership();
        vm.stopPrank();
    }

    function testFuzz_setPanelAcceptedIffWithinBounds(uint16 size, uint16 quorum) public {
        size = uint16(bound(size, 0, 110));
        quorum = uint16(bound(quorum, 0, 110));
        vm.prank(OWNER);
        (bool ok,) = address(desk).call(abi.encodeWithSelector(desk.setPanel.selector, size, quorum));
        bool expected = size >= 2 && size <= 100 && quorum >= 2 && quorum <= size;
        assertEq(ok, expected, "panel bounds");
        if (ok) {
            assertEq(desk.panelSize(), size);
            assertEq(desk.quorum(), quorum);
        } else {
            assertEq(desk.panelSize(), 12);
            assertEq(desk.quorum(), 8);
        }
    }

    function testFuzz_setCaseFeeAcceptedIffItFitsUint128(uint256 fee) public {
        vm.prank(OWNER);
        (bool ok,) = address(desk).call(abi.encodeWithSelector(desk.setCaseFee.selector, fee));
        assertEq(ok, fee <= type(uint128).max);
        assertEq(desk.caseFee(), ok ? fee : FEE);
    }
}
