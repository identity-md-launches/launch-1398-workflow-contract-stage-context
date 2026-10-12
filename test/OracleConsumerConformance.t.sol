// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {SnitchArt} from "../src/SnitchArt.sol";
import {SnitchDesk} from "../src/SnitchDesk.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @title The conformance test a consumer copies
/// @notice The protocol's vector values, its digest and a signature made by `oracle-eip712.ts`. A
/// consumer whose struct, type string or domain differs from the protocol's fails this. SnitchDesk
/// only takes bool answers, so the vector's bytes32[] answer is not delivered through the callback;
/// as the skill says, a fresh bool answer is signed with the vector key instead, and
/// `test_digestMatchesTheProtocol` is what ties the desk to the protocol.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    address constant OWNER = 0xc91633279Dd9Fa90D69F3c1b48c18A96FBd8aB67;

    MockIntake intake;
    MockERC20 imd;
    MockERC20 pepe;
    LaunchToken snitch;
    SnitchDesk consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        vm.roll(1000);
        intake = new MockIntake();
        imd = new MockERC20("IdentityMD", "IMD");
        pepe = new MockERC20("Pepe", "PEPE");
        snitch = new LaunchToken();
        deployConsumer();
    }

    /// @dev The desk, at the vector's address, trusting `caller()`.
    function deployConsumer() internal {
        SnitchArt art = new SnitchArt();
        deployCodeTo(
            "SnitchDesk.sol:SnitchDesk",
            abi.encode(OWNER, address(snitch), address(imd), caller(), SIGNER, address(art)),
            VECTOR_CONSUMER
        );
        consumer = SnitchDesk(VECTOR_CONSUMER);
        intake.setPrice(consumer.DEFAULT_ACTION(), address(imd), 0.5 ether);
    }

    /// @dev Who calls the callback: the intake (a mock of it) for an answer on the same chain.
    function caller() internal view returns (address) {
        return address(intake);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    /// @notice The digest the desk verifies is the one the oracle signs.
    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    /// @notice The protocol's own signature over the vector verifies against the desk's signer.
    function test_protocolSignatureRecoversToTheSigner() public view {
        bytes32 digest = consumer.attestationDigest(vector());
        bytes memory sig = VECTOR_SIGNATURE;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        assertEq(ecrecover(digest, v, r, s), SIGNER);
        assertEq(consumer.oracleSigner(), SIGNER);
    }

    /// @notice The callback's selector is the one the intake calls.
    function test_callbackSelectorIsCanonical() public view {
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(keccak256(bytes(CALLBACK))),
            "callback parameters differ from the protocol's"
        );
    }

    /// @notice A fresh bool answer signed by the vector key, delivered by the intake under the
    /// writer's 200,000 gas stipend, is accepted and consumed.
    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        address opener = makeAddr("opener");
        snitch.transfer(opener, 200_000 ether);
        imd.mint(opener, 0.5 ether);
        vm.startPrank(opener);
        snitch.approve(address(consumer), type(uint256).max);
        imd.approve(address(consumer), type(uint256).max);
        uint256 caseId = consumer.openCase(0, address(pepe), makeAddr("wallet"), 100, 200);
        vm.stopPrank();

        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        a.panelSize = 12;
        a.quorum = 8;
        a.agreed = 9;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        (bool ok,) = intake.complete(intake.lastRequestId(), a, abi.encodePacked(r, s, v));
        assertTrue(ok, "the callback did not run to the end under the 200,000 gas stipend");
        assertTrue(consumer.consumed(a.requestId));
        SnitchTypes.Case memory c = consumer.getCase(caseId);
        assertEq(uint8(c.status), uint8(SnitchTypes.Status.Answered));
        assertTrue(c.verdict);
        assertEq(c.figure, 12345);
    }
}
