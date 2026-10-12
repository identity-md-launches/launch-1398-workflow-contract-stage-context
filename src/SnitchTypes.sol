// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The shapes SnitchDesk, SnitchReports and SnitchArt share
library SnitchTypes {
    /// @dev `kind` values. Fixed wording, no free text.
    uint8 internal constant KIND_NEVER_SOLD = 0;
    uint8 internal constant KIND_GOT_IN_EARLY = 1;

    /// @dev A case's life: opened, then answered by the oracle (and later filed as a report), or
    /// dropped by its opener after the deadline or a recorded oracle failure.
    enum Status {
        None,
        Open,
        Answered,
        Filed,
        Dropped
    }

    /// @dev Laid out so the oracle callback, which runs under the writer's 200,000 gas stipend,
    /// touches as few storage slots as possible: it modifies slot 0 (status, verdict) and slot 3
    /// (panelSize, agreed, issuedAt, next to the fee it reads) and writes only `figure` fresh.
    struct Case {
        // slot 0
        address opener;
        uint64 openedAt;
        uint8 kind;
        Status status;
        bool verdict;
        // slot 1: written once at opening
        address token;
        uint64 fromBlock;
        uint16 askedPanelSize;
        uint16 askedQuorum;
        // slot 2: written once at opening
        address wallet;
        uint64 toBlock;
        // slot 3: SNITCH held for this case (uint128 holds the whole supply), then the answer's panel and date
        uint128 fee;
        uint64 issuedAt;
        uint16 panelSize;
        uint16 agreed;
        // slot 4: the sum behind the answer, in the token's smallest unit
        uint256 figure;
        // slot 5+: the token's symbol as snapshotted at opening, or the short token address
        string symbol;
    }
}
