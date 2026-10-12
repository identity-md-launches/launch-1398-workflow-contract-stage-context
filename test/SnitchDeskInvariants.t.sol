// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {SnitchArt} from "../src/SnitchArt.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";
import {SnitchReports} from "../src/SnitchReports.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Drives the desk through its whole life with several actors and bounded inputs: cases are
/// opened, answered (validly and invalidly), failed, dropped and filed in random order while the
/// owner moves the fee, the panel and the failure hook, and the clock advances. Every expected
/// failure is caught and asserted here; an unexpected revert fails the run (fail-on-revert).
contract SnitchDeskHandler is CommonBase, StdUtils {
    uint256 constant SUPPLY = 10 ** 27;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant OTHER_KEY = 0xA11CE;
    address public constant OWNER = 0xc91633279Dd9Fa90D69F3c1b48c18A96FBd8aB67;

    LaunchToken public snitch;
    MockERC20 public imd;
    MockERC20 public pepe;
    MockIntake public intake;
    SnitchDesk public desk;
    SnitchReports public reports;

    address[] public actors;
    uint256 public price = 0.5 ether;

    // ---- ghost state ----
    uint256 public ghostOpened;
    uint256 public ghostHeld; // SNITCH the desk should hold: fees of open cases
    uint256 public ghostBurned;
    uint256 public ghostImdPaid;
    uint256 public ghostFiled;
    uint256 public ghostValidAnswers;
    uint256 public ghostRejectedAnswers;
    uint256 public ghostDrops;
    uint256 public ghostFailures;
    mapping(address => uint256) public ghostPaid; // SNITCH each actor paid in fees
    mapping(address => uint256) public ghostRefunded; // SNITCH each actor got back
    mapping(address => uint256) public ghostTopUps; // SNITCH the handler gave each actor
    mapping(address => uint256) public ghostImdMinted;
    mapping(uint256 => SnitchTypes.Status) public recorded; // the status this handler last saw
    mapping(uint256 => bytes32) public oracleIdOf; // the oracle request id a case was answered with
    uint256[] public openIds;
    uint256[] public answeredIds;
    uint256[] public filedIds;
    uint256[] public droppedIds;

    constructor() {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(21_100_000);
        snitch = new LaunchToken();
        imd = new MockERC20("IdentityMD", "IMD");
        pepe = new MockERC20("Pepe", "PEPE");
        intake = new MockIntake();
        SnitchArt art = new SnitchArt();
        desk = new SnitchDesk(OWNER, address(snitch), address(imd), address(intake), vm.addr(SIGNER_KEY), address(art));
        reports = desk.reports();
        intake.setPrice(desk.DEFAULT_ACTION(), address(imd), price);
        actors.push(makeActor("alice"));
        actors.push(makeActor("bob"));
        actors.push(makeActor("carol"));
    }

    function makeActor(string memory name) internal returns (address who) {
        who = address(uint160(uint256(keccak256(bytes(name)))));
        vm.startPrank(who);
        snitch.approve(address(desk), type(uint256).max);
        imd.approve(address(desk), type(uint256).max);
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function openCount() external view returns (uint256) {
        return openIds.length;
    }

    function answeredCount() external view returns (uint256) {
        return answeredIds.length;
    }

    function filedCount() external view returns (uint256) {
        return filedIds.length;
    }

    function droppedCount() external view returns (uint256) {
        return droppedIds.length;
    }

    // ---- actions: anyone ----

    function openCase(uint256 actorSeed, uint8 kind, uint64 fromBlock, uint64 toBlock) external {
        address who = actors[bound(actorSeed, 0, actors.length - 1)];
        kind = uint8(bound(kind, 0, 1));
        toBlock = uint64(bound(toBlock, 2, block.number));
        fromBlock = uint64(bound(fromBlock, 1, toBlock - 1));
        uint256 fee = desk.caseFee();
        topUp(who, fee);

        uint256 heldBefore = snitch.balanceOf(address(desk));
        vm.prank(who);
        uint256 caseId = desk.openCase(kind, address(pepe), who, fromBlock, toBlock);

        require(caseId == ++ghostOpened, "case numbers are not sequential");
        require(snitch.balanceOf(address(desk)) == heldBefore + fee, "the fee was not pulled exactly");
        require(imd.balanceOf(address(desk)) == 0, "IMD left in the desk");
        ghostHeld += fee;
        ghostImdPaid += price;
        ghostPaid[who] += fee;
        track(caseId, SnitchTypes.Status.Open);
        openIds.push(caseId);
    }

    function answer(uint256 caseSeed, bool verdict, uint256 figure, uint16 extraPanel, uint16 extraAgreed) external {
        if (openIds.length == 0) return;
        uint256 i = bound(caseSeed, 0, openIds.length - 1);
        uint256 caseId = openIds[i];
        SnitchTypes.Case memory c = desk.getCase(caseId);
        OracleAttestation.Attestation memory a = attestationFor(caseId, c, verdict, figure);
        // at least what the case asked for, never more than the 100-seat cap
        a.panelSize = uint16(bound(extraPanel, c.askedPanelSize, 100));
        a.quorum = c.askedQuorum;
        a.agreed = uint16(bound(extraAgreed, a.quorum, a.panelSize));

        uint256 burnedBefore = snitch.balanceOf(desk.BURN());
        (bool ok,) = intake.complete(requestId(caseId), a, sign(SIGNER_KEY, a));
        require(ok, "a valid answer did not land under the stipend");

        SnitchTypes.Case memory after_ = desk.getCase(caseId);
        require(after_.verdict == verdict && after_.figure == figure, "answer stored wrong");
        require(after_.panelSize == a.panelSize && after_.agreed == a.agreed, "panel stored wrong");
        require(snitch.balanceOf(desk.BURN()) == burnedBefore + c.fee, "burn is not the case fee");
        ghostHeld -= c.fee;
        ghostBurned += c.fee;
        ++ghostValidAnswers;
        oracleIdOf[caseId] = a.requestId;
        track(caseId, SnitchTypes.Status.Answered);
        removeAt(openIds, i);
        answeredIds.push(caseId);
    }

    /// @dev An answer that must be refused: wrong key, weak panel, expired, wrong chain, wrong type,
    /// a replayed oracle id, a tampered field, or the right answer from the wrong caller.
    function badAnswer(uint256 caseSeed, uint8 mode) external {
        if (openIds.length == 0) return;
        uint256 caseId = openIds[bound(caseSeed, 0, openIds.length - 1)];
        SnitchTypes.Case memory c = desk.getCase(caseId);
        OracleAttestation.Attestation memory a = attestationFor(caseId, c, true, 1);
        a.panelSize = c.askedPanelSize;
        a.quorum = c.askedQuorum;
        a.agreed = c.askedPanelSize;
        mode = uint8(bound(mode, 0, 7));
        uint256 key = SIGNER_KEY;
        if (mode == 0) {
            key = OTHER_KEY;
        } else if (mode == 1) {
            a.panelSize = c.askedPanelSize - 1;
        } else if (mode == 2) {
            a.agreed = c.askedQuorum - 1;
        } else if (mode == 3) {
            a.expiresAt = uint64(block.timestamp) - 1;
        } else if (mode == 4) {
            a.chainId = 4663;
        } else if (mode == 5) {
            a.answerType = OracleAttestation.ANSWER_UINT256;
            a.answer = abi.encode(uint256(1));
        } else if (mode == 6) {
            if (answeredIds.length == 0) return;
            a.requestId = oracleIdOf[answeredIds[0]];
        }
        bytes memory sig = sign(key, a);
        if (mode == 7) a.figure = 2; // tampered after signing

        uint256 heldBefore = snitch.balanceOf(address(desk));
        uint256 burnedBefore = snitch.balanceOf(desk.BURN());
        (bool ok,) = intake.complete(requestId(caseId), a, sig);
        require(!ok, "an invalid answer was accepted");

        // and the genuine answer from anyone but the intake
        OracleAttestation.Attestation memory good = attestationFor(caseId, c, true, 1);
        good.panelSize = c.askedPanelSize;
        good.quorum = c.askedQuorum;
        good.agreed = c.askedPanelSize;
        bytes memory goodSig = sign(SIGNER_KEY, good);
        vm.prank(c.opener);
        (bool okStranger,) =
            address(desk).call(abi.encodeWithSelector(desk.onOracleResult.selector, requestId(caseId), good, goodSig));
        require(!okStranger, "an answer from a non-intake caller was accepted");

        require(uint8(desk.getCase(caseId).status) == uint8(SnitchTypes.Status.Open), "a refused answer changed status");
        require(snitch.balanceOf(address(desk)) == heldBefore, "a refused answer moved held SNITCH");
        require(snitch.balanceOf(desk.BURN()) == burnedBefore, "a refused answer burned");
        ++ghostRejectedAnswers;
    }

    function fail(uint256 caseSeed) external {
        if (openIds.length == 0) return;
        uint256 caseId = openIds[bound(caseSeed, 0, openIds.length - 1)];
        (,,,,,, bool withFailure) = intake.stored(requestId(caseId));
        if (!withFailure) return;
        uint256 heldBefore = snitch.balanceOf(address(desk));
        bool ok = intake.fail(requestId(caseId), 2, bytes32("disagreed"), 3, 12);
        require(ok, "failure notice refused for an open case");
        require(desk.failed(caseId), "failure not recorded");
        require(snitch.balanceOf(address(desk)) == heldBefore, "a failure moved SNITCH");
        require(uint8(desk.getCase(caseId).status) == uint8(SnitchTypes.Status.Open), "a failure closed the case");
        ++ghostFailures;
    }

    function dropCase(uint256 caseSeed, uint256 warpSeed) external {
        if (openIds.length == 0) return;
        uint256 i = bound(caseSeed, 0, openIds.length - 1);
        uint256 caseId = openIds[i];
        SnitchTypes.Case memory c = desk.getCase(caseId);
        // a stranger never drops
        address stranger = actors[(indexOf(c.opener) + 1) % actors.length];
        vm.prank(stranger);
        (bool okStranger,) = address(desk).call(abi.encodeWithSelector(desk.dropCase.selector, caseId));
        require(!okStranger, "a stranger dropped a case");

        uint256 now_ = block.timestamp + bound(warpSeed, 0, 80 hours);
        vm.warp(now_);
        bool allowed = desk.failed(caseId) || now_ >= c.openedAt + desk.DROP_DELAY();
        uint256 openerBefore = snitch.balanceOf(c.opener);
        vm.prank(c.opener);
        (bool ok,) = address(desk).call(abi.encodeWithSelector(desk.dropCase.selector, caseId));
        require(ok == allowed, allowed ? "drop refused after the delay" : "drop accepted too early");
        if (!ok) return;

        require(snitch.balanceOf(c.opener) == openerBefore + c.fee, "refund is not the case fee");
        ghostHeld -= c.fee;
        ghostRefunded[c.opener] += c.fee;
        ++ghostDrops;
        track(caseId, SnitchTypes.Status.Dropped);
        removeAt(openIds, i);
        droppedIds.push(caseId);
    }

    function fileReport(uint256 caseSeed, uint256 fillerSeed) external {
        if (answeredIds.length == 0) return;
        uint256 i = bound(caseSeed, 0, answeredIds.length - 1);
        uint256 caseId = answeredIds[i];
        address opener = desk.getCase(caseId).opener;
        uint256 heldBefore = snitch.balanceOf(address(desk));
        vm.prank(actors[bound(fillerSeed, 0, actors.length - 1)]); // anyone
        desk.fileReport(caseId);
        require(reports.ownerOf(caseId) == opener, "report minted to the wrong wallet");
        require(snitch.balanceOf(address(desk)) == heldBefore, "filing moved SNITCH");
        ++ghostFiled;
        track(caseId, SnitchTypes.Status.Filed);
        removeAt(answeredIds, i);
        filedIds.push(caseId);
        // a second filing is refused
        (bool again,) = address(desk).call(abi.encodeWithSelector(desk.fileReport.selector, caseId));
        require(!again, "a report was filed twice");
    }

    function fileUnanswered(uint256 caseSeed) external {
        uint256 caseId = bound(caseSeed, 0, ghostOpened + 1);
        if (uint8(desk.getCase(caseId).status) == uint8(SnitchTypes.Status.Answered)) return;
        (bool ok,) = address(desk).call(abi.encodeWithSelector(desk.fileReport.selector, caseId));
        require(!ok, "an unanswered case was filed");
    }

    // ---- actions: the owner, the intake's price, and the clock ----

    /// @dev One entry point for the settings so the runner spends most of its calls on cases.
    function tweak(uint8 mode, uint256 a, uint256 b) external {
        mode = uint8(bound(mode, 0, 4));
        if (mode == 0) {
            vm.prank(OWNER);
            desk.setCaseFee(bound(a, 0, 5 * 200_000 ether));
        } else if (mode == 1) {
            uint16 size = uint16(bound(a, 2, 100));
            vm.prank(OWNER);
            desk.setPanel(size, uint16(bound(b, 2, size)));
        } else if (mode == 2) {
            vm.prank(OWNER);
            desk.setFailureHook(a % 2 == 0);
        } else if (mode == 3) {
            price = bound(a, 1, 2 ether);
            intake.setPrice(desk.DEFAULT_ACTION(), address(imd), price);
        } else {
            vm.warp(block.timestamp + bound(a, 0, 24 hours));
        }
    }

    // ---- helpers ----

    function topUp(address who, uint256 fee) internal {
        if (snitch.balanceOf(who) < fee) {
            uint256 give = fee - snitch.balanceOf(who);
            snitch.transfer(who, give);
            ghostTopUps[who] += give;
        }
        if (imd.balanceOf(who) < price) {
            uint256 give = price - imd.balanceOf(who);
            imd.mint(who, give);
            ghostImdMinted[who] += give;
        }
    }

    /// @dev The only legal moves: None -> Open, Open -> Answered | Dropped, Answered -> Filed.
    function track(uint256 caseId, SnitchTypes.Status next) internal {
        SnitchTypes.Status prev = recorded[caseId];
        bool legal = (prev == SnitchTypes.Status.None && next == SnitchTypes.Status.Open)
            || (prev == SnitchTypes.Status.Open
                && (next == SnitchTypes.Status.Answered || next == SnitchTypes.Status.Dropped))
            || (prev == SnitchTypes.Status.Answered && next == SnitchTypes.Status.Filed);
        require(legal, "illegal status transition");
        require(desk.getCase(caseId).status == next, "desk status differs from the handler's");
        recorded[caseId] = next;
    }

    function attestationFor(uint256 caseId, SnitchTypes.Case memory c, bool verdict, uint256 figure)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle", caseId, block.timestamp)),
            chainId: block.chainid,
            questionHash: keccak256(abi.encode("question", caseId)),
            answerType: OracleAttestation.ANSWER_BOOL,
            answer: abi.encode(verdict),
            figure: figure,
            fromBlock: c.fromBlock,
            toBlock: c.toBlock,
            blockHash: bytes32(uint256(1)),
            panelJobId: keccak256(abi.encode("job", caseId)),
            panelSize: 12,
            quorum: 8,
            agreed: 11,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 1800
        });
    }

    function sign(uint256 key, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, desk.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function requestId(uint256 caseId) public pure returns (bytes32) {
        return keccak256(abi.encode("intake", caseId));
    }

    function indexOf(address who) internal view returns (uint256) {
        for (uint256 i = 0; i < actors.length; ++i) {
            if (actors[i] == who) return i;
        }
        revert("unknown actor");
    }

    function removeAt(uint256[] storage list, uint256 i) internal {
        list[i] = list[list.length - 1];
        list.pop();
    }
}

/// @notice What must hold after every sequence: the desk holds exactly the fees of its open cases,
/// the dead address holds exactly the fees of answered ones, nobody is refunded more than they paid,
/// the IMD is all with the intake, the supply never changes, finished cases never reopen, and a
/// report exists exactly for the filed cases, owned by the opener.
/// forge-config: default.invariant.runs = 160
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SnitchDeskInvariantTest is Test {
    SnitchDeskHandler handler;
    SnitchDesk desk;
    LaunchToken snitch;
    MockERC20 imd;
    SnitchReports reports;

    function setUp() public {
        handler = new SnitchDeskHandler();
        desk = handler.desk();
        snitch = handler.snitch();
        imd = handler.imd();
        reports = handler.reports();
        targetContract(address(handler));
    }

    function invariant_deskHoldsExactlyTheOpenFees() public view {
        assertEq(snitch.balanceOf(address(desk)), handler.ghostHeld(), "desk balance != ghost held");
        uint256 sumOpen;
        uint256 sumSettled;
        for (uint256 id = 1; id <= desk.caseCount(); ++id) {
            SnitchTypes.Case memory c = desk.getCase(id);
            if (c.status == SnitchTypes.Status.Open) sumOpen += c.fee;
            if (c.status == SnitchTypes.Status.Answered || c.status == SnitchTypes.Status.Filed) sumSettled += c.fee;
        }
        assertEq(snitch.balanceOf(address(desk)), sumOpen, "desk balance != sum of open fees");
        assertEq(snitch.balanceOf(desk.BURN()), sumSettled, "burned != sum of answered fees");
        assertEq(snitch.balanceOf(desk.BURN()), handler.ghostBurned(), "burned != ghost burned");
    }

    function invariant_noImdEverRestsInTheDesk() public view {
        assertEq(imd.balanceOf(address(desk)), 0);
        assertEq(imd.balanceOf(address(handler.intake())), handler.ghostImdPaid(), "intake holds a different IMD sum");
        assertEq(imd.allowance(address(desk), address(handler.intake())), 0, "a dangling IMD allowance");
    }

    function invariant_supplyIsFixedAndConserved() public view {
        assertEq(snitch.totalSupply(), 10 ** 27);
        uint256 actorsHold;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            actorsHold += snitch.balanceOf(handler.actors(i));
        }
        assertEq(
            actorsHold + snitch.balanceOf(address(desk)) + snitch.balanceOf(desk.BURN())
                + snitch.balanceOf(address(handler)),
            10 ** 27,
            "SNITCH leaked somewhere else"
        );
    }

    function invariant_nobodyIsRefundedMoreThanTheyPaid() public view {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address who = handler.actors(i);
            uint256 paid = handler.ghostPaid(who);
            uint256 refunded = handler.ghostRefunded(who);
            assertLe(refunded, paid, "refunded more than paid");
            assertEq(snitch.balanceOf(who) + paid, handler.ghostTopUps(who) + refunded, "actor balance drifted");
            assertEq(imd.balanceOf(who), 0, "an actor kept IMD it should have paid");
        }
    }

    function invariant_caseLifeIsOneWay() public view {
        assertEq(desk.caseCount(), handler.ghostOpened());
        for (uint256 id = 1; id <= desk.caseCount(); ++id) {
            SnitchTypes.Status now_ = desk.getCase(id).status;
            assertEq(uint8(now_), uint8(handler.recorded(id)), "a case changed status outside a handler action");
            assertTrue(now_ != SnitchTypes.Status.None, "an opened case has no status");
            assertEq(desk.caseOfRequest(handler.requestId(id)), id, "request id unbound");
            if (now_ == SnitchTypes.Status.Answered || now_ == SnitchTypes.Status.Filed) {
                assertTrue(desk.consumed(handler.oracleIdOf(id)), "answered without consuming the oracle id");
            }
        }
        assertEq(
            handler.openCount() + handler.answeredCount() + handler.filedCount() + handler.droppedCount(),
            desk.caseCount(),
            "a case fell out of every bucket"
        );
        assertEq(handler.ghostValidAnswers(), handler.answeredCount() + handler.filedCount());
        assertEq(handler.ghostDrops(), handler.droppedCount());
    }

    function invariant_reportsExistExactlyForFiledCases() public {
        uint256 filed;
        for (uint256 id = 1; id <= desk.caseCount(); ++id) {
            SnitchTypes.Case memory c = desk.getCase(id);
            if (c.status == SnitchTypes.Status.Filed) {
                ++filed;
                assertEq(reports.ownerOf(id), c.opener, "report not owned by the opener");
            } else {
                vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
                reports.ownerOf(id);
            }
        }
        assertEq(filed, handler.ghostFiled(), "filed count drifted");
        uint256 owned;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            owned += reports.balanceOf(handler.actors(i));
        }
        assertEq(owned, filed, "reports owned != cases filed");
    }

    function invariant_ownerSettingsStayInBounds() public view {
        assertLe(desk.caseFee(), type(uint128).max);
        assertGe(desk.panelSize(), 2);
        assertLe(desk.panelSize(), 100);
        assertGe(desk.quorum(), 2);
        assertLe(desk.quorum(), desk.panelSize());
        assertEq(desk.owner(), handler.OWNER());
    }
}
