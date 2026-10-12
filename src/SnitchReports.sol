// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SnitchArt} from "./SnitchArt.sol";
import {SnitchTypes} from "./SnitchTypes.sol";

/// @dev What the ERC-721 needs from the desk: the case behind a report.
interface ISnitchCaseSource {
    function getCase(uint256 caseId) external view returns (SnitchTypes.Case memory);
}

/// @title Snitch Reports (REPORT)
/// @notice One report per answered case, token id = case number. Only SnitchDesk mints, and it is
/// the desk that deploys this contract in its constructor, so the two are bound at birth. The
/// metadata and image are rendered by SnitchArt from the case the desk stores.
contract SnitchReports is ERC721 {
    error OnlyDesk();

    ISnitchCaseSource public immutable desk;
    SnitchArt public immutable art;

    constructor(address desk_, SnitchArt art_) ERC721("Snitch Reports", "REPORT") {
        desk = ISnitchCaseSource(desk_);
        art = art_;
    }

    /// @notice Mints report `caseId` to `to`. Only the desk calls it, once per case.
    /// @dev A plain mint, not a safe mint: the receiver is the case opener, who chose to open the
    /// case, and a receiver hook could block the filing or re-enter.
    function mint(address to, uint256 caseId) external {
        if (msg.sender != address(desk)) revert OnlyDesk();
        _mint(to, caseId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return art.tokenURI(tokenId, desk.getCase(tokenId));
    }
}
