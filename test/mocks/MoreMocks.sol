// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IIntake} from "../../src/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {SnitchDesk} from "../../src/SnitchDesk.sol";

/// @dev An ERC-1271 signer registry, the shape the README says the owner may point the desk at:
/// a signature is valid when it recovers to a listed key.
contract RegistrySigner is IERC1271 {
    mapping(address => bool) public listed;

    function list(address key, bool on) external {
        listed[key] = on;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && listed[recovered]) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @dev A contract signer that reverts on every query.
contract RevertingSigner {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        revert("no");
    }
}

/// @dev An intake that answers synchronously inside `request`, or re-enters another desk function,
/// instead of calling back in a later transaction. The desk must refuse both.
contract ReentrantIntake is IIntake {
    enum Mode {
        CallbackInsideRequest,
        OpenCaseInsideRequest,
        DropCaseInsideRequest
    }

    Mode public mode;
    uint256 public price = 0.5 ether;

    function setMode(Mode m) external {
        mode = m;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        requestId = keccak256("reentrant");
        if (mode == Mode.CallbackInsideRequest) {
            OracleAttestation.Attestation memory a;
            SnitchDesk(callback.target).onOracleResult(requestId, a, "");
        } else if (mode == Mode.OpenCaseInsideRequest) {
            SnitchDesk(callback.target).openCase(0, address(this), address(this), 1, 2);
        } else {
            SnitchDesk(callback.target).dropCase(1);
        }
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address, uint256)
        external
        payable
        returns (bytes32)
    {
        revert("ActionNotSold");
    }
}
