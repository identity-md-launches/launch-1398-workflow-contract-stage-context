# SNITCH

*The swarm snitches on every wallet.*

Anyone opens a case on a wallet: "never sold" or "got in early" for a token over a block range.
The IMD oracle panel reads the chain and answers on chain, and the case ends as a report NFT
stamped CLEAN if the claim holds or SNITCHED if it does not.

This repository is the contract stage of the launch: the launch token, the three application
contracts, their tests and ABI exports. The manifest (`launch.json`) is written by the manifest
step after this work is accepted, so it is deliberately absent here.

## Contracts

| Contract | File | Role |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | SNITCH, the launch token. Fixed-supply ERC-20, "Snitch" / "SNITCH", 18 decimals, 1,000,000,000 minted to the deployer (the factory). No mint, owner, pause, blocklist, fee or upgrade. |
| `SnitchArt` | `src/SnitchArt.sol` | Stateless renderer: ERC-721 JSON metadata and the on-chain SVG report card. No constructor arguments. |
| `SnitchDesk` | `src/SnitchDesk.sol` | Opens cases, buys each answer from the IMD oracle through the Intake, verifies and stores it, holds then burns the case fee, files reports. Deploys `SnitchReports` in its constructor. |
| `SnitchReports` | `src/SnitchReports.sol` | ERC-721 "Snitch Reports" (REPORT). Only `SnitchDesk` mints; `tokenURI` comes from `SnitchArt`. Created by the desk, so it is not a manifest entry: read its address from `SnitchDesk.reports()`. |
| `OracleAttestation` | `src/OracleAttestation.sol` | The protocol's attestation library and consumer base, copied verbatim from the oracle-consumer reference. |
| `IIntake` | `src/IIntake.sol` | The Intake interface the desk calls. |
| `SnitchTypes` | `src/SnitchTypes.sol` | The shared `Case` struct and kind constants. |

### Why the desk deploys the reports contract

`SnitchReports` must know the desk (its only minter) and the desk must know the reports contract
(to mint). The factory makes no initialization calls and every contract must be fully configured
in its constructor, so the desk creates the ERC-721 itself with `new SnitchReports(address(this), art)`.
Nothing in that constructor calls an existing contract, so it runs on the empty launch chain. The
desk's runtime embeds the reports creation code and still fits EIP-170 (see `test/Deployment.t.sol`).

## Deployment parameters

Dependency order for the manifest: `SnitchArt`, then `SnitchDesk`.

| Contract | Argument | Value | Source |
| --- | --- | --- | --- |
| `SnitchArt` | none | | |
| `SnitchDesk` | `owner_` | `$owner` (0xc91633279dd9fa90d69f3c1b48c18a96fbd8ab67) | the launch owner |
| `SnitchDesk` | `snitch_` | `$token` | the launch token |
| `SnitchDesk` | `imd_` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | IMD on Ethereum, from the launch's chain references |
| `SnitchDesk` | `intake_` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` | IMD Intake version 2 on Ethereum (see note) |
| `SnitchDesk` | `oracleSigner_` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` | the oracle signer published by api.imd.fun |
| `SnitchDesk` | `art_` | `$contract:SnitchArt` | the renderer deployed just before |

Note on the intake: the approved workflow names the version 1 Intake
(`0x1397434cd35e8a9c8ac312a61d3a285eb31dea56`). The oracle-consumer reference, which wins on
protocol matters, says version 2 (`0xa43e6f75ee006411f79ac1c84120606c2330de82`) has everything
version 1 has plus `requestWithFailure`, and to use it for anything new. The desk works against
either: it calls `request` unless the owner turns the failure hook on. The intake, action id,
signer and panel are owner-settable, so a wrong choice at launch is fixable without a redeploy.

Values fixed in the desk at construction, changeable by the owner afterwards:

| Setting | Launch value | Setter |
| --- | --- | --- |
| Case fee | 200,000 SNITCH | `setCaseFee(uint256)` (at most 2^128 - 1) |
| Oracle action | `bytes32("oracle.request@oracle-1")` | `setAction(bytes32)` |
| Intake | constructor argument | `setIntake(address)` |
| Oracle signer | constructor argument | `setOracleSigner(address)` |
| Panel size / quorum asked per case | 12 / 8 | `setPanel(uint16,uint16)`, 2 ≤ quorum ≤ size ≤ 100 |
| Failure hook (`requestWithFailure`) | off | `setFailureHook(bool)`, version 2 intake only |

Constants: 72-hour drop delay, 50,000 gas for the token's `symbol()` at opening, 1800 seconds
asked as the attestation's validity, burn address `0x000000000000000000000000000000000000dEaD`.

## After launch

Nothing has to be set for the desk to work: every value is in the constructor or has a launch
default. The owner should still do these, in order:

1. **Check the body with the plane before the first real case.** `SnitchDesk.body(kind, token, wallet, fromBlock, toBlock)`
   returns the exact JSON the desk sends. Submit it to `POST /requests/check` on api.imd.fun for
   both kinds. If the wording screen refuses it, the fix is on the plane's side or in a new
   action version: the question wording is fixed in the contract by design (no free text), and the
   owner can only move the action id, the intake, the signer and the panel.
2. **Turn the failure hook on** with `setFailureHook(true)` once the desk points at a version 2
   intake. Then a refused body or a panel that does not agree calls `onOracleFailure`, which marks
   the case failed so its opener can drop it at once instead of waiting 72 hours.
3. **Pick the panel** with `setPanel(size, quorum)`. 12 agents with a quorum of 8 is the launch
   value; each case snapshots the values in force when it is opened and refuses a smaller panel.
4. **Rotate the signer** with `setOracleSigner(address)` whenever api.imd.fun publishes a new
   attester, or point it at the signer registry (ERC-1271 is supported by `SignatureChecker`).
5. **Move the intake or the action** with `setIntake` / `setAction` when the plane publishes a new
   version or price. The price is never stored: the desk reads `priceOf(action, IMD)` live at each
   opening, so a price move needs no action.

## How a case runs

1. `openCase(kind, token, wallet, fromBlock, toBlock)`. Checks: kind is 0 or 1, the token has
   code, the wallet is not zero, `fromBlock < toBlock <= block.number`. Pulls the case fee in
   SNITCH (held by the desk) and the oracle price in IMD (forwarded to the intake in the same
   transaction, after a `forceApprove` of exactly that amount). Snapshots the token's symbol with
   a gas-capped, return-size-bounded `staticcall`: 1 to 11 characters, `A-Z a-z 0-9` only,
   otherwise the short token address (`0x6982…1933`). Case numbers start at 1. Emits `CaseOpened`
   with the intake's request id.
2. The oracle panel answers minutes later. The intake calls `onOracleResult(requestId, attestation, signature)`
   with 200,000 gas. The desk checks, in order: the caller is the intake, the request id belongs
   to an open case, the attestation's `chainId` is this chain, the panel is at least what the case
   asked for and `agreed >= quorum`, the answer type is bool, the attestation is inside its window
   and signed by the oracle signer for this contract (EIP-712 domain "IdentityMD Oracle" / "2" /
   this chain / the desk), and the oracle request id has not been consumed. Any failed check
   reverts and stores nothing. A valid answer stores verdict, figure, panelSize, agreed and
   issuedAt, emits `CaseAnswered`, and sends the held SNITCH to the dead address. A "no" is a
   result to store, not a revert. Measured gas: about 98,000 with a zero figure, 146,000 with a
   2^256 - 1 figure.
3. `fileReport(caseId)`: anyone, once per answered case, mints report `caseId` to the opener. A
   plain mint, not a safe mint, so a contract opener without `onERC721Received` still gets its
   report and no receiver hook runs inside the desk.
4. `dropCase(caseId)`: the opener only, after 72 hours with no answer or as soon as a failure has
   been recorded for the case. Refunds the held SNITCH. The IMD paid to the oracle is never
   refunded: the intake does not escrow it.

Verdict semantics: kind 0 asks whether the wallet sent zero units of the token in the window
(true means CLEAN, the figure is the sum sent). Kind 1 asks whether the wallet received any units
in the window (true means CLEAN, the figure is the sum received). Figures are in the token's
smallest unit, as the oracle reports them; the metadata shows them raw.

## The oracle body

The desk sends, compacted:

```json
{"v":1,"question":"Did the address 0x… send zero units of the ERC-20 token at 0x… between block A and block B inclusive? Sum the value of every Transfer event emitted by the token contract 0x… whose from field equals 0x… in that block range. Answer true if that sum is zero and false otherwise. Report the sum as the figure.","chainId":1,"window":{"fromBlock":A,"toBlock":B},"answerType":"bool","evidence":"chain","panelSize":12,"quorum":8,"validForSeconds":1800,"definitions":{"Transfer event":"…","units":"…"}}
```

Kind 1 asks "receive any units … whose to field equals … Answer true if that sum is greater than
zero". The window is absolute, so the oracle's `fromBlock` / `toBlock` are the case's. The
canonical question document (and so `questionHash`) is produced by the plane; the desk does not
recompute it. On the asking chain the binding between an answer and a case is the intake's
request id, which only the desk's own `request` call can create, as the oracle-consumer skill
prescribes for same-chain consumers. The signed `questionHash` is emitted in `CaseAnswered` for
anyone who wants to check it against the plane's record.

## Trust assumptions and operational responsibilities

- **The oracle.** The truth of an answer is the panel's, and its signature is one hot key's. A
  wrong CLEAN costs a reputation, not a liquidation; nothing here moves anyone's funds on an
  answer except the opener's own fee, which burns either way. Still, a compromised signer could
  stamp any verdict. The owner must rotate the signer promptly when api.imd.fun announces a change.
- **Liveness.** An answer can be late, withheld or lost (the writer tries the callback once). The
  opener's SNITCH comes back through `dropCase` after 72 hours; the IMD is spent. With the failure
  hook on, a refused body or disagreement frees the case at once. There is no refund path the
  contract cannot pay.
- **Wording.** The questions are fixed in the contract. If the plane's wording screen ever refuses
  them, cases fail (status 1) until the plane or a new action version accepts them. Check the
  body with `POST /requests/check` before launch; see "After launch".
- **The owner** (two-step `Ownable2Step`, `renounceOwnership` reverts) can change the fee for
  future cases, the intake, action, signer, panel and failure hook. The owner cannot pause, upgrade,
  mint, change an open case, or move held SNITCH: the only outflows are the burn on an answer and
  the refund on a drop. A malicious owner could point the desk at a fake intake and signer and
  thereby stamp future cases at will; this is the trust the brief places in the launch owner.
- **The token being investigated** is any contract with code. Its `symbol()` is called with
  50,000 gas and at most 128 bytes of return data are read, so a reverting, gas-burning,
  bytes32-returning or return-bombing token cannot block a case or cost the opener more than the
  cap.
- **Reentrancy.** `openCase`, `dropCase`, `fileReport` and `onOracleResult` are `nonReentrant`.
  State is written before external calls except the intake's request id, which is only known after
  `request` returns and is bound in the same guarded call.
- **Fee tokens.** SNITCH is the launch token (plain transfers). IMD is the chain's pair token.
  Neither is fee-on-transfer; `SafeERC20` is used for both.
- **No ETH.** The desk has no `receive` or `payable` function.

## What the brief asked that the launch token does not do

Nothing: the brief asks for a fixed-supply, plain-transfer, no-tax, no-mint token, which is exactly
the launch token. The case fee burn is implemented in the desk by transferring SNITCH to the dead
address, not by a burn function on the token.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`cbor_metadata = false`, no `ffi`, no `fs_permissions`. OpenZeppelin Contracts 5.5.0 and forge-std
are vendored as ordinary files under `lib/`.

Test coverage (66 tests, `test/`):

- `LaunchToken.t.sol`: supply, decimals, transfer, no mint or owner.
- `SnitchDesk.t.sol`: construction and zero-address refusal; opening (fees pulled and forwarded,
  body shape, input validation, allowance and balance failures, live price and fee, zero fee,
  unsold action, numbering); symbol snapshot (clean, too long, spaces, empty, non-ASCII, markup,
  reverting, bytes32, gas-burning, return-bombing tokens); the answer (stores and burns, "no" is
  stored, gas under the stipend and under exactly 200,000, wrong sender, unknown request, settled
  or dropped case, consumed oracle id, wrong key, tampered fields, wrong domain, expired, not yet
  valid, wrong chain, wrong answer type, weak panel, per-case panel snapshot); dropping (72-hour
  boundary, opener only, answered case, conservation of funds); the failure hook (frees the case,
  moves nothing, sender and case checks, version 1 intake); filing (anyone, once, to the opener);
  owner setters, non-owner rejection, two-step ownership, renounce disabled, no sweep.
- `SnitchArt.t.sol`: claim sentence, number formatting, short address, UTC date (fixed vectors and
  a fuzz against the civil-from-days algorithm), XML and JSON escaping, SVG fields and stamp
  colours, metadata attributes, base64 data URI.
- `SnitchReports.t.sol`: only the desk mints, token id is the case number, `tokenURI`, transfers,
  a contract opener.
- `OracleConsumerConformance.t.sol`: the protocol's vector digest, signature recovery to the
  vector signer, the canonical callback selector, and a fresh bool answer from the vector key
  delivered under the stipend.
- `Deployment.t.sol`: constructors run with the factory as `msg.sender` on an empty chain, the
  supply stays with the factory, runtimes fit EIP-170 with no `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`.

Static analysis: slither 0.11.6 was run on `src/` during this work. It reports no high or medium
findings; the two low findings it leaves (`reentrancy-benign` for the request-id write after the
intake call, and `timestamp` for the status read in the failure hook) are annotated in place with
the reason.

Tests passing do not constitute a security audit. The independent review step sees this source
and the manifest together.

## ABI exports

`docs/abi/<Contract>.json` holds the ABI of each deployable contract: `LaunchToken`, `SnitchArt`,
`SnitchDesk`, `SnitchReports`. Regenerate with `forge inspect <Contract> abi --json`.

## Frontend notes

- Cases: index `CaseOpened`, `CaseAnswered`, `CaseFailed`, `CaseDropped`, `ReportFiled` from the
  desk; `getCase(caseId)` returns the stored struct. `caseCount()` is the latest case number.
- Opening: approve `caseFee()` SNITCH and `oraclePrice()` IMD to the desk, then `openCase`.
- Reports: `SnitchDesk.reports()` is the ERC-721; `tokenURI(caseId)` is a base64 JSON data URI
  whose `image` is a base64 SVG.
- The pool: SNITCH pairs with IMD at the network's launch fee; nothing here describes or changes it.
