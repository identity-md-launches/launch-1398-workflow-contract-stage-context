// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SNITCH, the launch token
/// @notice A fixed-supply ERC-20: 1,000,000,000 SNITCH at 18 decimals, minted once to the deployer
/// (the launch factory, which splits it between the pool, the swarm and the requester). Plain
/// transfers only: no mint, owner, pause, blocklist, fee or upgrade path.
contract LaunchToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Snitch", "SNITCH") {
        _mint(msg.sender, SUPPLY);
    }
}
