// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {SnitchArt} from "../src/SnitchArt.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";
import {SnitchReports} from "../src/SnitchReports.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Shared fixture: the launch token, a mock IMD, a mock intake, the art, the desk, and a
/// signer key the tests sign attestations with.
abstract contract SnitchBase is Test {
    address constant OWNER = 0xc91633279Dd9Fa90D69F3c1b48c18A96FBd8aB67;
    address constant FACTORY = address(0xFAC);
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant PRICE = 0.5 ether;
    uint256 constant FEE = 200_000 ether;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address wallet = makeAddr("wallet");

    LaunchToken snitch;
    MockERC20 imd;
    MockERC20 pepe;
    MockIntake intake;
    SnitchArt art;
    SnitchDesk desk;
    SnitchReports reports;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(21_100_000);

        vm.prank(FACTORY);
        snitch = new LaunchToken();
        imd = new MockERC20("IdentityMD", "IMD");
        pepe = new MockERC20("Pepe", "PEPE");
        intake = new MockIntake();
        art = new SnitchArt();

        vm.prank(FACTORY);
        desk = new SnitchDesk(OWNER, address(snitch), address(imd), address(intake), SIGNER, address(art));
        reports = desk.reports();
        intake.setPrice(desk.DEFAULT_ACTION(), address(imd), PRICE);

        fund(alice);
        fund(bob);
    }

    function fund(address who) internal {
        vm.prank(FACTORY);
        snitch.transfer(who, 10 * FEE);
        imd.mint(who, 10 * PRICE);
        vm.startPrank(who);
        snitch.approve(address(desk), type(uint256).max);
        imd.approve(address(desk), type(uint256).max);
        vm.stopPrank();
    }

    function open(address who, uint8 kind) internal returns (uint256 caseId) {
        vm.prank(who);
        caseId = desk.openCase(kind, address(pepe), wallet, 21_004_118, 21_077_903);
    }

    function attestationFor(uint256 caseId, bool verdict, uint256 figure)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        SnitchTypes.Case memory c = desk.getCase(caseId);
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle", caseId)),
            chainId: block.chainid,
            questionHash: keccak256(abi.encode("question", caseId)),
            answerType: OracleAttestation.ANSWER_BOOL,
            answer: abi.encode(verdict),
            figure: figure,
            fromBlock: c.fromBlock,
            toBlock: c.toBlock,
            blockHash: blockhash(block.number - 1),
            panelJobId: keccak256(abi.encode("job", caseId)),
            panelSize: 12,
            quorum: 8,
            agreed: 11,
            issuedAt: uint64(block.timestamp) - 60,
            expiresAt: uint64(block.timestamp) + 1740
        });
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return signWith(SIGNER_KEY, a);
    }

    function signWith(uint256 key, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, desk.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Delivers an answer the way the writer would: through the intake, under 200,000 gas.
    function answer(uint256 caseId, bool verdict, uint256 figure) internal returns (bool ok) {
        return deliver(caseId, attestationFor(caseId, verdict, figure));
    }

    function deliver(uint256 caseId, OracleAttestation.Attestation memory a) internal returns (bool ok) {
        bytes memory sig = sign(a);
        bytes32 requestId = requestOf(caseId);
        (ok,) = intake.complete(requestId, a, sig);
    }

    /// @dev Signs first, then expects the delivery (unbounded gas, so the reason surfaces) to revert.
    function expectDeliveryRevert(uint256 caseId, OracleAttestation.Attestation memory a, bytes memory err) internal {
        expectDeliveryRevertWithSignature(caseId, a, sign(a), err);
    }

    function expectDeliveryRevertWithSignature(
        uint256 caseId,
        OracleAttestation.Attestation memory a,
        bytes memory sig,
        bytes memory err
    ) internal {
        bytes32 requestId = requestOf(caseId);
        vm.expectRevert(err);
        intake.completeUnbounded(requestId, a, sig);
    }

    function requestOf(uint256 caseId) internal view returns (bytes32) {
        // The mock hands out ids in order; cases are opened in order too.
        return keccak256(abi.encode("intake", caseId));
    }
}
