// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev A stand-in for the IMD Intake: records each request, pulls the price, and can call the
/// stored callback (or failure hook) from its own address under the writer's 200,000 gas stipend.
contract MockIntake is IIntake {
    uint256 public constant STIPEND = 200_000;

    struct Stored {
        bytes32 action;
        bytes body;
        Callback callback;
        bytes4 onFailure;
        address asset;
        uint256 amount;
        bool withFailure;
    }

    mapping(bytes32 => mapping(address => uint256)) public prices;
    mapping(bytes32 => Stored) public stored;
    uint256 public count;
    bytes32 public lastRequestId;
    bool public version1;

    function setPrice(bytes32 action, address asset, uint256 price) external {
        prices[action][asset] = price;
    }

    function setVersion1(bool on) external {
        version1 = on;
    }

    /// @dev Moves the id counter, so a second mock hands out ids that do not collide with the
    /// first (or, set backwards, ids that do).
    function setCount(uint256 to) external {
        count = to;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        return prices[action][asset];
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        return _store(action, body, callback, bytes4(0), asset, amount, false);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        require(!version1, "ActionNotSold");
        return _store(action, body, callback, onFailure, asset, amount, true);
    }

    function _store(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount,
        bool withFailure
    ) internal returns (bytes32 requestId) {
        require(prices[action][asset] > 0, "ActionNotSold");
        require(amount == prices[action][asset], "WrongAmount");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        requestId = keccak256(abi.encode("intake", ++count));
        stored[requestId] = Stored(action, body, callback, onFailure, asset, amount, withFailure);
        lastRequestId = requestId;
    }

    function bodyOf(bytes32 requestId) external view returns (bytes memory) {
        return stored[requestId].body;
    }

    /// @dev What the writer does: calls the stored callback with the attestation, inside a try.
    function complete(bytes32 requestId, OracleAttestation.Attestation memory a, bytes memory signature)
        external
        returns (bool ok, bytes memory ret)
    {
        Stored storage s = stored[requestId];
        (ok, ret) =
            s.callback.target.call{gas: STIPEND}(abi.encodeWithSelector(s.callback.selector, requestId, a, signature));
    }

    /// @dev Calls the stored callback with unlimited gas, to surface the revert reason in tests.
    function completeUnbounded(bytes32 requestId, OracleAttestation.Attestation memory a, bytes memory signature)
        external
    {
        Stored storage s = stored[requestId];
        (bool ok, bytes memory ret) =
            s.callback.target.call(abi.encodeWithSelector(s.callback.selector, requestId, a, signature));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function fail(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)
        external
        returns (bool ok)
    {
        Stored storage s = stored[requestId];
        require(s.withFailure, "no failure hook");
        (ok,) = s.callback.target.call{gas: STIPEND}(
            abi.encodeWithSelector(s.onFailure, requestId, status, reason, agreed, answered, bytes(""))
        );
    }
}
