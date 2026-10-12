// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SnitchArt} from "../src/SnitchArt.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";

/// @notice Properties of the renderer for any input: escaping round-trips and leaves no raw
/// specials, number formatting round-trips, and the metadata stays well-formed JSON with any symbol.
/// forge-config: default.fuzz.runs = 512
contract SnitchArtPropertiesTest is Test {
    using Strings for uint256;

    SnitchArt art;

    function setUp() public {
        art = new SnitchArt();
    }

    function sample(bytes memory symbol, bool verdict, uint8 kind, uint256 figure, uint64 issuedAt)
        internal
        pure
        returns (SnitchTypes.Case memory c)
    {
        c = SnitchTypes.Case({
            opener: address(0xA11CE),
            openedAt: 1_760_000_000,
            kind: kind,
            status: SnitchTypes.Status.Filed,
            verdict: verdict,
            token: 0x6982508145454Ce325dDbE47a25d4ec3d2311933,
            fromBlock: 21_004_118,
            askedPanelSize: 12,
            askedQuorum: 8,
            wallet: 0x8f3a0000000000000000000000000000000091C2,
            toBlock: 21_077_903,
            fee: 200_000 ether,
            issuedAt: issuedAt,
            panelSize: 12,
            agreed: 11,
            figure: figure,
            symbol: string(symbol)
        });
    }

    // ---- escaping ----

    function testFuzz_escapeJsonRoundTripsAndLeavesNoRawSpecials(bytes memory raw) public view {
        bytes memory out = bytes(art.escapeJson(string(raw)));
        bytes memory back = unescapeJson(out);
        assertEq(back, raw, "unescape(escape(x)) != x");
        // scanning: no raw quote or control character survives outside an escape
        for (uint256 i = 0; i < out.length; ++i) {
            if (out[i] == "\\") {
                bytes1 n = out[i + 1];
                assertTrue(n == '"' || n == "\\" || n == "u", "unknown escape");
                i += n == "u" ? 5 : 1;
                continue;
            }
            assertTrue(out[i] != '"', "raw quote");
            assertTrue(uint8(out[i]) >= 0x20, "raw control character");
        }
    }

    function testFuzz_escapeXmlRoundTripsAndLeavesNoRawSpecials(bytes memory raw) public view {
        bytes memory out = bytes(art.escapeXml(string(raw)));
        assertEq(unescapeXml(out), raw, "unescape(escape(x)) != x");
        for (uint256 i = 0; i < out.length; ++i) {
            bytes1 ch = out[i];
            assertTrue(ch != "<" && ch != ">" && ch != '"' && ch != "'", "raw markup character");
            if (ch == "&") {
                // only as the start of one of the five entities
                uint256 end = i;
                while (out[end] != ";") {
                    ++end;
                }
                bytes memory entity = slice(out, i, end + 1);
                assertTrue(
                    eq(entity, "&amp;") || eq(entity, "&lt;") || eq(entity, "&gt;") || eq(entity, "&quot;")
                        || eq(entity, "&apos;"),
                    "unknown entity"
                );
                i = end;
            }
        }
    }

    function testFuzz_escapingIsIdempotentOnCleanText(bytes memory raw) public view {
        for (uint256 i = 0; i < raw.length; ++i) {
            raw[i] = bytes1(uint8(0x61 + uint8(raw[i]) % 26)); // a-z only
        }
        assertEq(art.escapeJson(string(raw)), string(raw));
        assertEq(art.escapeXml(string(raw)), string(raw));
    }

    // ---- numbers and addresses ----

    function testFuzz_commasRoundTripAndGroupByThree(uint256 n) public view {
        bytes memory out = bytes(art.commas(n));
        bytes memory digits = bytes(n.toString());
        bytes memory stripped = new bytes(digits.length);
        uint256 d;
        uint256 sinceComma = 0;
        for (uint256 i = 0; i < out.length; ++i) {
            if (out[i] == ",") {
                assertTrue(i != 0, "leading comma");
                sinceComma = 0;
            } else {
                stripped[d++] = out[i];
                ++sinceComma;
            }
        }
        assertEq(d, digits.length, "digit count changed");
        assertEq(stripped, digits, "digits changed");
        assertEq(out.length, digits.length + (digits.length - 1) / 3, "separator count");
        // from the right, a comma sits before every third digit
        uint256 fromRight = 0;
        for (uint256 i = out.length; i > 0; --i) {
            bytes1 ch = out[i - 1];
            if (ch == ",") {
                assertEq(fromRight % 3, 0, "comma off the grid");
                assertTrue(fromRight > 0, "trailing comma");
            } else {
                ++fromRight;
            }
        }
    }

    function testFuzz_caseNumberPadsToFourAndKeepsTheValue(uint256 id) public view {
        bytes memory out = bytes(art.caseNumber(id));
        assertGe(out.length, 4);
        bytes memory digits = bytes(id.toString());
        uint256 pad = digits.length < 4 ? 4 - digits.length : 0;
        assertEq(out.length, digits.length + pad);
        for (uint256 i = 0; i < out.length; ++i) {
            assertTrue(out[i] >= "0" && out[i] <= "9", "non-digit");
            assertEq(out[i], i < pad ? bytes1("0") : digits[i - pad], "digit changed");
        }
    }

    function testFuzz_shortAddressIsTheEndsOfTheHexString(address a) public view {
        bytes memory out = bytes(art.shortAddress(a));
        bytes memory full = bytes(Strings.toHexString(a));
        assertEq(out.length, 13);
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(out[i], full[i]);
        }
        assertEq(out[6], bytes1(0xE2));
        assertEq(out[7], bytes1(0x80));
        assertEq(out[8], bytes1(0xA6));
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(out[9 + i], full[38 + i]);
        }
    }

    // ---- the whole card ----

    function testFuzz_metadataStaysWellFormedJsonForAnySymbol(
        bytes memory symbol,
        bool verdict,
        uint8 kind,
        uint256 figure
    ) public view {
        if (symbol.length > 24) symbol = slice(symbol, 0, 24);
        kind = uint8(bound(kind, 0, 1));
        SnitchTypes.Case memory c = sample(symbol, verdict, kind, figure, 1_760_227_200);
        bytes memory json = bytes(art.metadata(42, c));
        assertJsonShape(json);
        bytes memory attrs = bytes(art.attributes(c));
        assertJsonShape(attrs);
        // the figure is carried raw, as a string
        assertTrue(contains(json, bytes(string.concat('{"trait_type":"Figure","value":"', figure.toString(), '"}'))));
        assertTrue(contains(json, verdict ? bytes('"Verdict","value":"CLEAN"') : bytes('"Verdict","value":"SNITCHED"')));
    }

    function testFuzz_svgTagCountIsIndependentOfTheSymbol(bytes memory symbol, bool verdict) public view {
        if (symbol.length > 24) symbol = slice(symbol, 0, 24);
        bytes memory withSymbol = bytes(art.svg(1, sample(symbol, verdict, 0, 0, 1_760_227_200)));
        bytes memory clean = bytes(art.svg(1, sample("PEPE", verdict, 0, 0, 1_760_227_200)));
        assertEq(count(withSymbol, "<"), count(clean, "<"), "the symbol injected markup");
        assertEq(count(withSymbol, ">"), count(clean, ">"), "the symbol injected markup");
        assertEq(count(withSymbol, "'"), count(clean, "'"), "the symbol broke an attribute");
        assertEq(count(withSymbol, '"'), count(clean, '"'), "the symbol broke an attribute");
    }

    function testFuzz_utcDateIsAlwaysTenCharactersInShape(uint64 ts) public view {
        ts = uint64(bound(ts, 0, 253_402_300_799));
        bytes memory out = bytes(art.utcDate(ts));
        assertEq(out.length, 10);
        assertEq(out[4], "-");
        assertEq(out[7], "-");
        uint256 month = (uint8(out[5]) - 48) * 10 + (uint8(out[6]) - 48);
        uint256 day = (uint8(out[8]) - 48) * 10 + (uint8(out[9]) - 48);
        assertTrue(month >= 1 && month <= 12, "month out of range");
        assertTrue(day >= 1 && day <= 31, "day out of range");
    }

    // ---- helpers ----

    /// @dev A minimal JSON scanner: strings are closed and escape-clean, braces and brackets balance
    /// outside strings, nothing follows the last brace.
    function assertJsonShape(bytes memory json) internal pure {
        int256 depth = 0;
        bool inString = false;
        for (uint256 i = 0; i < json.length; ++i) {
            bytes1 ch = json[i];
            if (inString) {
                if (ch == "\\") {
                    bytes1 n = json[i + 1];
                    assertTrue(n == '"' || n == "\\" || n == "u" || n == "/", "bad escape in json");
                    i += n == "u" ? 5 : 1;
                } else if (ch == '"') {
                    inString = false;
                } else {
                    assertTrue(uint8(ch) >= 0x20, "raw control character in json string");
                }
                continue;
            }
            if (ch == '"') {
                inString = true;
            } else if (ch == "{" || ch == "[") {
                ++depth;
            } else if (ch == "}" || ch == "]") {
                --depth;
                assertTrue(depth >= 0, "unbalanced json");
            }
        }
        assertFalse(inString, "unterminated json string");
        assertEq(depth, 0, "unbalanced json");
        bytes1 first = json[0];
        bytes1 last = json[json.length - 1];
        assertTrue((first == "{" && last == "}") || (first == "[" && last == "]"), "not one json value");
    }

    function unescapeJson(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length);
        uint256 o;
        for (uint256 i = 0; i < s.length; ++i) {
            if (s[i] == "\\") {
                bytes1 n = s[++i];
                if (n == "u") {
                    out[o++] = bytes1(uint8(hexVal(s[i + 3]) * 16 + hexVal(s[i + 4])));
                    i += 4;
                } else {
                    out[o++] = n;
                }
            } else {
                out[o++] = s[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, o)
        }
    }

    function unescapeXml(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length);
        uint256 o;
        for (uint256 i = 0; i < s.length; ++i) {
            if (s[i] == "&") {
                uint256 end = i;
                while (s[end] != ";") {
                    ++end;
                }
                bytes memory e = slice(s, i, end + 1);
                if (eq(e, "&amp;")) out[o++] = "&";
                else if (eq(e, "&lt;")) out[o++] = "<";
                else if (eq(e, "&gt;")) out[o++] = ">";
                else if (eq(e, "&quot;")) out[o++] = '"';
                else if (eq(e, "&apos;")) out[o++] = "'";
                else revert("unknown entity");
                i = end;
            } else {
                out[o++] = s[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, o)
        }
    }

    function hexVal(bytes1 c) internal pure returns (uint8) {
        if (c >= "0" && c <= "9") return uint8(c) - 48;
        return uint8(c) - 87; // a-f
    }

    function slice(bytes memory s, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = s[i];
        }
    }

    function eq(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    function count(bytes memory s, bytes1 ch) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < s.length; ++i) {
            if (s[i] == ch) ++n;
        }
    }

    function contains(bytes memory h, bytes memory n) internal pure returns (bool) {
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
