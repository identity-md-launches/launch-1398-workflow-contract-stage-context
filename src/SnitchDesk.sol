// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IIntake} from "./IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {SnitchArt} from "./SnitchArt.sol";
import {SnitchReports} from "./SnitchReports.sol";
import {SnitchTypes} from "./SnitchTypes.sol";

/// @title The desk where cases are opened
/// @notice Anyone opens a case on a wallet: "never sold" (kind 0) or "got in early" (kind 1) for a
/// token over a block range. The desk holds the case fee in SNITCH, buys the answer from the IMD
/// oracle through the Intake in the same transaction, verifies the signed attestation when it comes
/// back, burns the fee to 0x…dEaD, and lets anyone file the answered case as a report NFT minted to
/// the opener. A case with no answer after 72 hours (or with a recorded oracle failure) can be
/// dropped by its opener for a refund of the SNITCH; the IMD paid to the oracle is never refunded.
///
/// The owner (the launch owner, two-step, cannot renounce) sets the case fee for future cases and
/// the protocol-facing values the oracle skill wants movable without a redeploy: intake, action id,
/// signer, panel size and quorum, and the failure hook. Each setting binds cases opened after it:
/// an open case is answered only by the intake it was asked at, with the panel it asked for. No
/// pause, no upgrade, and no way to move held SNITCH except the burn and the refund.
contract SnitchDesk is OracleAttestationConsumer, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for address;

    // ---- errors ----
    error BadKind(uint8 kind);
    error TokenHasNoCode(address token);
    error ZeroWallet();
    error BadBlockRange(uint64 fromBlock, uint64 toBlock);
    error NotTheIntake();
    error UnknownRequest(bytes32 requestId);
    error DuplicateRequestId(bytes32 requestId);
    error WrongWindow(uint64 fromBlock, uint64 toBlock);
    error FeeAboveLimit(uint256 fee, uint256 maxFee);
    error PriceAboveLimit(uint256 price, uint256 maxOraclePrice);
    error NotOpen(uint256 caseId);
    error NotAnswered(uint256 caseId);
    error NotTheOpener(uint256 caseId);
    error TooEarly(uint256 caseId, uint64 droppableAt);
    error PanelTooWeak(uint16 panelSize, uint16 quorum, uint16 agreed);
    error WrongChain(uint256 chainId);
    error BadPanel(uint16 panelSize, uint16 quorum);
    error FeeTooLarge(uint256 fee);
    error ZeroAddress();
    error RenounceDisabled();

    // ---- events ----
    event CaseOpened(
        uint256 indexed caseId,
        address indexed opener,
        uint8 kind,
        address indexed token,
        address wallet,
        uint64 fromBlock,
        uint64 toBlock,
        string symbol,
        uint256 fee,
        uint256 oraclePrice,
        bytes32 requestId
    );
    event CaseAnswered(
        uint256 indexed caseId,
        bool verdict,
        uint256 figure,
        uint16 panelSize,
        uint16 agreed,
        bytes32 oracleRequestId,
        bytes32 questionHash
    );
    event CaseFailed(uint256 indexed caseId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event CaseDropped(uint256 indexed caseId, uint256 refund);
    event ReportFiled(uint256 indexed caseId, address indexed to);
    event CaseFeeSet(uint256 fee);
    event IntakeSet(address indexed intake);
    event ActionSet(bytes32 action);
    event PanelSet(uint16 panelSize, uint16 quorum);
    event FailureHookSet(bool on);

    // ---- constants ----
    /// @notice The fee burns here: SNITCH has no burn function, so it goes to the dead address.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    /// @notice How long a case waits for an answer before its opener can drop it.
    uint64 public constant DROP_DELAY = 72 hours;
    /// @notice The gas the token's `symbol()` is given at opening.
    uint256 public constant SYMBOL_GAS = 50_000;
    /// @notice How long an attestation is asked to stay valid, so a slow writer still lands it.
    uint32 public constant VALID_FOR_SECONDS = 1800;
    /// @notice The oracle action the desk ships pointing at: `bytes32("oracle.request@oracle-1")`.
    bytes32 public constant DEFAULT_ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    /// @notice The case fee at launch: 200,000 SNITCH.
    uint256 public constant DEFAULT_CASE_FEE = 200_000 ether;
    uint16 public constant DEFAULT_PANEL_SIZE = 12;
    uint16 public constant DEFAULT_QUORUM = 8;

    // ---- immutables ----
    /// @notice SNITCH, the launch token: what the case fee is paid in.
    IERC20 public immutable snitch;
    /// @notice IMD, what the oracle is paid in.
    IERC20 public immutable imd;
    /// @notice The report NFT, deployed by this desk so only this desk can mint.
    SnitchReports public immutable reports;

    // ---- owner settings ----
    /// @notice The IMD Intake the desk buys answers from.
    IIntake public intake;
    /// @notice The oracle action id.
    bytes32 public action;
    /// @notice The SNITCH fee for cases opened from now on.
    uint256 public caseFee;
    /// @notice How many agents each case asks for, and how many must agree.
    uint16 public panelSize;
    uint16 public quorum;
    /// @notice Whether openCase names `onOracleFailure`. Only a version 2 intake takes it.
    bool public failureHook;

    // ---- cases ----
    uint256 public caseCount;
    mapping(uint256 caseId => SnitchTypes.Case) internal cases;
    /// @notice The intake's request id to the case it belongs to.
    mapping(bytes32 requestId => uint256 caseId) public caseOfRequest;
    /// @notice The intake each request was asked at. Only that intake may answer or fail it, so
    /// moving the desk with `setIntake` never strands a case that is already open.
    mapping(bytes32 requestId => address intake) public intakeOfRequest;
    /// @notice Set when the intake reported that the oracle refused or could not answer the case.
    mapping(uint256 caseId => bool) public failed;

    /// @param owner_ the launch owner
    /// @param snitch_ the launch token, SNITCH
    /// @param imd_ the IMD ERC-20 on this chain
    /// @param intake_ the IMD Intake on this chain
    /// @param oracleSigner_ the oracle's attester address from api.imd.fun
    /// @param art_ the SnitchArt renderer, deployed before the desk
    constructor(address owner_, address snitch_, address imd_, address intake_, address oracleSigner_, address art_)
        OracleAttestationConsumer(oracleSigner_)
        Ownable(owner_)
    {
        if (snitch_ == address(0) || imd_ == address(0) || intake_ == address(0) || art_ == address(0)) {
            revert ZeroAddress();
        }
        snitch = IERC20(snitch_);
        imd = IERC20(imd_);
        intake = IIntake(intake_);
        action = DEFAULT_ACTION;
        caseFee = DEFAULT_CASE_FEE;
        panelSize = DEFAULT_PANEL_SIZE;
        quorum = DEFAULT_QUORUM;
        reports = new SnitchReports(address(this), SnitchArt(art_));
        emit IntakeSet(intake_);
        emit ActionSet(DEFAULT_ACTION);
        emit CaseFeeSet(DEFAULT_CASE_FEE);
        emit PanelSet(DEFAULT_PANEL_SIZE, DEFAULT_QUORUM);
    }

    // ---- anyone ----

    /// @notice Opens a case. Pulls the case fee in SNITCH and the oracle price in IMD from the
    /// caller (both must be approved), forwards the IMD to the intake and asks the question.
    /// Pays whatever the fee and the intake's price are when the transaction lands: approve
    /// exactly `caseFee()` and `oraclePrice()`, or use `openCaseWithLimits` to cap both.
    /// @param kind 0 "never sold", 1 "got in early"
    /// @param token the ERC-20 the claim is about; must have code
    /// @param wallet the wallet the claim is about
    /// @param fromBlock the first block of the window
    /// @param toBlock the last block of the window; fromBlock < toBlock <= block.number
    function openCase(uint8 kind, address token, address wallet, uint64 fromBlock, uint64 toBlock)
        external
        nonReentrant
        returns (uint256 caseId)
    {
        return _open(kind, token, wallet, fromBlock, toBlock);
    }

    /// @notice `openCase` with the amounts the opener agreed to: reverts instead of paying more
    /// than `maxFee` SNITCH or `maxOraclePrice` IMD, for wallets that hold a standing approval.
    /// Both are read here and pulled in the same transaction, so neither can move in between.
    function openCaseWithLimits(
        uint8 kind,
        address token,
        address wallet,
        uint64 fromBlock,
        uint64 toBlock,
        uint256 maxFee,
        uint256 maxOraclePrice
    ) external nonReentrant returns (uint256 caseId) {
        if (caseFee > maxFee) revert FeeAboveLimit(caseFee, maxFee);
        uint256 price = intake.priceOf(action, address(imd));
        if (price > maxOraclePrice) revert PriceAboveLimit(price, maxOraclePrice);
        return _open(kind, token, wallet, fromBlock, toBlock);
    }

    function _open(uint8 kind, address token, address wallet, uint64 fromBlock, uint64 toBlock)
        internal
        returns (uint256 caseId)
    {
        if (kind > SnitchTypes.KIND_GOT_IN_EARLY) revert BadKind(kind);
        if (token.code.length == 0) revert TokenHasNoCode(token);
        if (wallet == address(0)) revert ZeroWallet();
        if (fromBlock >= toBlock || toBlock > block.number) revert BadBlockRange(fromBlock, toBlock);

        caseId = ++caseCount;
        SnitchTypes.Case storage c = cases[caseId];
        c.opener = msg.sender;
        c.openedAt = uint64(block.timestamp);
        c.kind = kind;
        c.status = SnitchTypes.Status.Open;
        c.token = token;
        c.fromBlock = fromBlock;
        c.askedPanelSize = panelSize;
        c.askedQuorum = quorum;
        c.wallet = wallet;
        c.toBlock = toBlock;
        uint256 fee = caseFee;
        c.fee = uint128(fee);
        string memory symbol = _snapshotSymbol(token);
        c.symbol = symbol;

        if (fee > 0) snitch.safeTransferFrom(msg.sender, address(this), fee);
        uint256 price = intake.priceOf(action, address(imd));
        if (price > 0) {
            imd.safeTransferFrom(msg.sender, address(this), price);
            imd.forceApprove(address(intake), price);
        }
        // The intake's request id is only known after the call. Everything else about the case is
        // already stored, the function is guarded, and the id is bound here and in the event. The
        // id must be new: the binding below is what lets only the asked intake answer the case.
        bytes32 requestId = _ask(body(kind, token, wallet, fromBlock, toBlock), price);
        if (caseOfRequest[requestId] != 0) revert DuplicateRequestId(requestId);
        // slither-disable-next-line reentrancy-benign
        caseOfRequest[requestId] = caseId;
        // slither-disable-next-line reentrancy-benign
        intakeOfRequest[requestId] = address(intake);

        emit CaseOpened(caseId, msg.sender, kind, token, wallet, fromBlock, toBlock, symbol, fee, price, requestId);
    }

    /// @notice Files an answered case as a report NFT, minted to the opener. Once per case.
    function fileReport(uint256 caseId) external nonReentrant {
        SnitchTypes.Case storage c = cases[caseId];
        if (c.status != SnitchTypes.Status.Answered) revert NotAnswered(caseId);
        c.status = SnitchTypes.Status.Filed;
        address opener = c.opener;
        emit ReportFiled(caseId, opener);
        reports.mint(opener, caseId);
    }

    // ---- the opener ----

    /// @notice Drops an unanswered case after 72 hours, or as soon as the intake has recorded an
    /// oracle failure for it, and refunds the held SNITCH. The IMD is never refunded.
    function dropCase(uint256 caseId) external nonReentrant {
        SnitchTypes.Case storage c = cases[caseId];
        if (c.status != SnitchTypes.Status.Open) revert NotOpen(caseId);
        if (msg.sender != c.opener) revert NotTheOpener(caseId);
        uint64 droppableAt = c.openedAt + DROP_DELAY;
        // slither-disable-next-line timestamp
        if (!failed[caseId] && block.timestamp < droppableAt) revert TooEarly(caseId, droppableAt);
        c.status = SnitchTypes.Status.Dropped;
        uint256 refund = c.fee;
        emit CaseDropped(caseId, refund);
        if (refund > 0) snitch.safeTransfer(msg.sender, refund);
    }

    // ---- the intake ----

    /// @notice The oracle's answer. Only the intake the case was asked at calls it, only for an
    /// open case of this desk, only with an attestation over the case's own block window that the
    /// oracle signer signed for this desk. A failed check reverts and stores nothing. A valid
    /// answer stores verdict, figure, panel and date, and burns the fee.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 caseId = caseOfRequest[requestId];
        if (caseId == 0) revert UnknownRequest(requestId);
        if (msg.sender != intakeOfRequest[requestId]) revert NotTheIntake();
        SnitchTypes.Case storage c = cases[caseId];
        if (c.status != SnitchTypes.Status.Open) revert NotOpen(caseId);
        if (a.chainId != block.chainid) revert WrongChain(a.chainId);
        // The window is absolute and confirmed when asked, so the signed one must be the case's.
        if (a.fromBlock != c.fromBlock || a.toBlock != c.toBlock) revert WrongWindow(a.fromBlock, a.toBlock);
        if (a.panelSize < c.askedPanelSize || a.quorum < c.askedQuorum || a.agreed < a.quorum) {
            revert PanelTooWeak(a.panelSize, a.quorum, a.agreed);
        }
        bool verdict = decodeBool(a);
        _verifyAttestation(a, signature);
        _consume(a.requestId);

        c.status = SnitchTypes.Status.Answered;
        c.verdict = verdict;
        c.panelSize = a.panelSize;
        c.agreed = a.agreed;
        c.issuedAt = a.issuedAt;
        c.figure = a.figure;
        emit CaseAnswered(caseId, verdict, a.figure, a.panelSize, a.agreed, a.requestId, a.questionHash);

        uint256 fee = c.fee;
        if (fee > 0) snitch.safeTransfer(BURN, fee);
    }

    /// @notice The intake's failure notice (version 2, with the failure hook on): the body was
    /// refused or the panel did not agree. Nothing in it is signed, so it only marks the case as
    /// failed, which lets the opener drop it without waiting 72 hours. It never moves value.
    function onOracleFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes calldata
    ) external {
        uint256 caseId = caseOfRequest[requestId];
        if (caseId == 0) revert UnknownRequest(requestId);
        if (msg.sender != intakeOfRequest[requestId]) revert NotTheIntake();
        // slither-disable-next-line timestamp
        if (cases[caseId].status != SnitchTypes.Status.Open) revert NotOpen(caseId);
        failed[caseId] = true;
        emit CaseFailed(caseId, status, reason, agreed, answered);
    }

    // ---- the owner ----

    /// @notice The SNITCH fee for cases opened from now on, at most 2^128 - 1 (far above the
    /// supply). Open cases keep the fee they paid.
    function setCaseFee(uint256 fee) external onlyOwner {
        if (fee > type(uint128).max) revert FeeTooLarge(fee);
        caseFee = fee;
        emit CaseFeeSet(fee);
    }

    /// @notice Moves the desk to another intake (a new version, or a moved deployment) for cases
    /// opened from now on. Open cases stay bound to the intake they were asked at.
    function setIntake(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        intake = IIntake(to);
        emit IntakeSet(to);
    }

    /// @notice Points the desk at a new oracle action id, for when the plane publishes one.
    function setAction(bytes32 to) external onlyOwner {
        action = to;
        emit ActionSet(to);
    }

    /// @notice Rotates the oracle signer, or points it at a signer registry. Open cases are
    /// checked against the signer in force when the answer lands, so during a handover point this
    /// at an ERC-1271 registry that accepts both keys, or rotate while no case is open.
    function setOracleSigner(address to) external onlyOwner {
        _setOracleSigner(to);
    }

    /// @notice How many agents future cases ask for, and how many must agree: 2 <= quorum <= size <= 100.
    function setPanel(uint16 size, uint16 quorum_) external onlyOwner {
        if (size < 2 || size > 100 || quorum_ < 2 || quorum_ > size) revert BadPanel(size, quorum_);
        panelSize = size;
        quorum = quorum_;
        emit PanelSet(size, quorum_);
    }

    /// @notice On only against a version 2 intake: a version 1 intake has no `requestWithFailure`.
    function setFailureHook(bool on) external onlyOwner {
        failureHook = on;
        emit FailureHookSet(on);
    }

    /// @dev The launch owner stays the owner: a desk nobody owns could never move the oracle.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---- views ----

    function getCase(uint256 caseId) external view returns (SnitchTypes.Case memory) {
        return cases[caseId];
    }

    /// @notice The oracle price the next case pays in IMD, as the intake quotes it now.
    function oraclePrice() external view returns (uint256) {
        return intake.priceOf(action, address(imd));
    }

    /// @notice The exact request body the desk sends for a case, so anyone can check it against
    /// the plane's `POST /requests/check` before opening one.
    function body(uint8 kind, address token, address wallet, uint64 fromBlock, uint64 toBlock)
        public
        view
        returns (bytes memory)
    {
        string memory w = wallet.toHexString();
        string memory t = token.toHexString();
        string memory a = uint256(fromBlock).toString();
        string memory b = uint256(toBlock).toString();
        string memory question;
        if (kind == SnitchTypes.KIND_NEVER_SOLD) {
            question = string.concat(
                "Did the address ",
                w,
                " send zero units of the ERC-20 token at ",
                t,
                " between block ",
                a,
                " and block ",
                b,
                " inclusive? Sum the value of every Transfer event emitted by the token contract ",
                t,
                " whose from field equals ",
                w,
                " in that block range. Answer true if that sum is zero and false otherwise. Report the sum as the figure."
            );
        } else {
            question = string.concat(
                "Did the address ",
                w,
                " receive any units of the ERC-20 token at ",
                t,
                " between block ",
                a,
                " and block ",
                b,
                " inclusive? Sum the value of every Transfer event emitted by the token contract ",
                t,
                " whose to field equals ",
                w,
                " in that block range. Answer true if that sum is greater than zero and false otherwise. Report the sum as the figure."
            );
        }
        return bytes(
            string.concat(
                '{"v":1,"question":"',
                question,
                '","chainId":',
                block.chainid.toString(),
                ',"window":{"fromBlock":',
                a,
                ',"toBlock":',
                b,
                '},"answerType":"bool","evidence":"chain","panelSize":',
                uint256(panelSize).toString(),
                ',"quorum":',
                uint256(quorum).toString(),
                ',"validForSeconds":',
                uint256(VALID_FOR_SECONDS).toString(),
                ',"definitions":{"Transfer event":"The standard ERC-20 event Transfer(address indexed from, address indexed to, uint256 value), topic 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef, emitted by the token contract itself.","units":"The raw integer value field of the event, in the token smallest unit, with no decimals adjustment."}}'
            )
        );
    }

    // ---- internals ----

    function _ask(bytes memory requestBody, uint256 price) internal returns (bytes32 requestId) {
        IIntake.Callback memory callback = IIntake.Callback(address(this), this.onOracleResult.selector);
        if (failureHook) {
            requestId = intake.requestWithFailure(
                action, requestBody, callback, this.onOracleFailure.selector, address(imd), price
            );
        } else {
            requestId = intake.request(action, requestBody, callback, address(imd), price);
        }
    }

    /// @dev `symbol()` with a gas cap and manual decoding, so a token that reverts, returns
    /// bytes32, returns garbage or burns gas cannot block a case: those get the short address.
    /// Accepted: 1 to 11 characters, A-Z a-z 0-9 only.
    function _snapshotSymbol(address token) internal view returns (string memory) {
        bytes memory data = new bytes(128);
        bool ok;
        uint256 size;
        bytes memory payload = abi.encodeWithSignature("symbol()");
        uint256 gasCap = SYMBOL_GAS;
        // A bounded copy: at most 128 bytes of whatever the token returns, so a return bomb only
        // costs its own gas cap and never the opener's whole transaction.
        assembly ("memory-safe") {
            ok := staticcall(gasCap, token, add(payload, 32), mload(payload), add(data, 32), 128)
            size := returndatasize()
        }
        if (ok && size >= 64) {
            uint256 offset = uint256(bytes32(_word(data, 0)));
            if (offset == 32) {
                uint256 length = uint256(bytes32(_word(data, 32)));
                if (length >= 1 && length <= 11 && size >= 64 + length) {
                    bytes memory out = new bytes(length);
                    bool clean = true;
                    for (uint256 i = 0; i < length; ++i) {
                        bytes1 ch = data[64 + i];
                        bool digit = ch >= "0" && ch <= "9";
                        bool upper = ch >= "A" && ch <= "Z";
                        bool lower = ch >= "a" && ch <= "z";
                        if (!(digit || upper || lower)) {
                            clean = false;
                            break;
                        }
                        out[i] = ch;
                    }
                    if (clean) return string(out);
                }
            }
        }
        return SnitchArt(address(reports.art())).shortAddress(token);
    }

    function _word(bytes memory data, uint256 at) private pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), at))
        }
    }
}
