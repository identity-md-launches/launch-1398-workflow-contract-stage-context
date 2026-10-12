// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {SnitchArt} from "../src/SnitchArt.sol";
import {SnitchTypes} from "../src/SnitchTypes.sol";

contract SnitchArtTest is Test {
    SnitchArt art;

    function setUp() public {
        art = new SnitchArt();
    }

    function sample(bool verdict, uint8 kind, string memory symbol) internal pure returns (SnitchTypes.Case memory c) {
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
            issuedAt: 1_760_227_200, // 2025-10-12 00:00:00 UTC
            panelSize: 12,
            agreed: 11,
            figure: 0,
            symbol: symbol
        });
    }

    function test_claimSentence() public view {
        assertEq(
            art.claim(sample(true, 0, "PEPE")),
            unicode"0x8f3a…91c2 never sold PEPE between block 21,004,118 and block 21,077,903"
        );
        assertEq(
            art.claim(sample(false, 1, "PEPE")),
            unicode"0x8f3a…91c2 got in early on PEPE between block 21,004,118 and block 21,077,903"
        );
    }

    function test_helpers() public view {
        assertEq(art.caseNumber(42), "0042");
        assertEq(art.caseNumber(1), "0001");
        assertEq(art.caseNumber(9999), "9999");
        assertEq(art.caseNumber(12345), "12345");
        assertEq(art.commas(0), "0");
        assertEq(art.commas(999), "999");
        assertEq(art.commas(1000), "1,000");
        assertEq(art.commas(21_004_118), "21,004,118");
        assertEq(art.commas(1_000_000_000), "1,000,000,000");
        assertEq(art.shortAddress(0x8f3a0000000000000000000000000000000091C2), unicode"0x8f3a…91c2");
        assertEq(art.verdictWord(true), "CLEAN");
        assertEq(art.verdictWord(false), "SNITCHED");
        assertEq(art.kindName(0), "Never sold");
        assertEq(art.kindName(1), "Got in early");
    }

    function test_utcDate() public view {
        assertEq(art.utcDate(0), "1970-01-01");
        assertEq(art.utcDate(86399), "1970-01-01");
        assertEq(art.utcDate(86400), "1970-01-02");
        assertEq(art.utcDate(951_782_400), "2000-02-29"); // leap day in a 400 year
        assertEq(art.utcDate(951_868_800), "2000-03-01");
        assertEq(art.utcDate(1_760_227_200), "2025-10-12");
        assertEq(art.utcDate(1_800_000_000), "2027-01-15");
        assertEq(art.utcDate(4_102_444_800), "2100-01-01"); // 2100 is not a leap year
        assertEq(art.utcDate(4_107_542_400), "2100-03-01");
        assertEq(art.utcDate(4_107_456_000), "2100-02-28");
    }

    function testFuzz_utcDateMatchesTheCivilAlgorithm(uint64 ts) public view {
        ts = uint64(bound(ts, 0, 253_402_300_799)); // up to 9999-12-31
        (uint256 y, uint256 m, uint256 d) = civil(ts / 86400);
        string memory expected = string.concat(vm.toString(y), "-", two(m), "-", two(d));
        assertEq(art.utcDate(ts), expected);
    }

    function test_escapes() public view {
        assertEq(art.escapeXml("PEPE"), "PEPE");
        assertEq(art.escapeXml("<a href='x'>&\"</a>"), "&lt;a href=&apos;x&apos;&gt;&amp;&quot;&lt;/a&gt;");
        assertEq(art.escapeJson("PEPE"), "PEPE");
        assertEq(art.escapeJson("a\"b\\c\nd"), "a\\\"b\\\\c\\u000ad");
    }

    function test_svgCarriesTheCardFields() public view {
        string memory svg = art.svg(42, sample(true, 0, "PEPE"));
        assertTrue(contains(svg, "<svg xmlns='http://www.w3.org/2000/svg'"));
        assertTrue(contains(svg, ">SNITCH</text>"));
        assertTrue(contains(svg, "CASE FILE No. 0042"));
        assertTrue(contains(svg, unicode"0x8f3a…91c2"));
        assertTrue(contains(svg, "never sold PEPE"));
        assertTrue(contains(svg, "21,004,118"));
        assertTrue(contains(svg, "21,077,903"));
        assertTrue(contains(svg, "Checked by 12 agents. 11 agreed."));
        assertTrue(contains(svg, "2025-10-12 UTC"));
        assertTrue(contains(svg, "rotate(-12"));
        assertTrue(contains(svg, "#23784A"));
        assertTrue(contains(svg, ">CLEAN</text>"));
        assertFalse(contains(svg, "SNITCHED"));
        assertTrue(contains(svg, "#E9D8A6"));
        assertTrue(contains(svg, "#1C1A17"));

        string memory red = art.svg(7, sample(false, 1, "PEPE"));
        assertTrue(contains(red, "CASE FILE No. 0007"));
        assertTrue(contains(red, "got in early on PEPE"));
        assertTrue(contains(red, "#C62A1F"));
        assertTrue(contains(red, ">SNITCHED</text>"));
        assertFalse(contains(red, ">CLEAN<"));
    }

    function test_svgEscapesTheSymbol() public view {
        string memory svg = art.svg(1, sample(true, 0, "<script>&'"));
        assertFalse(contains(svg, "<script>"));
        assertTrue(contains(svg, "&lt;script&gt;&amp;&apos;"));
    }

    function test_metadataIsWellFormedJson() public view {
        string memory json = art.metadata(42, sample(true, 0, "PEPE"));
        assertTrue(startsWith(json, '{"name":"Snitch Report No. 0042","description":"'));
        assertTrue(
            contains(
                json,
                unicode"0x8f3a…91c2 never sold PEPE between block 21,004,118 and block 21,077,903. CLEAN, checked by 11 of 12 agents."
            )
        );
        assertTrue(contains(json, '"image":"data:image/svg+xml;base64,'));
        assertTrue(contains(json, '{"trait_type":"Verdict","value":"CLEAN"}'));
        assertTrue(contains(json, '{"trait_type":"Kind","value":"Never sold"}'));
        assertTrue(contains(json, '{"trait_type":"Token","value":"PEPE"}'));
        assertTrue(
            contains(json, '{"trait_type":"Token Address","value":"0x6982508145454ce325ddbe47a25d4ec3d2311933"}')
        );
        assertTrue(contains(json, '{"trait_type":"Wallet","value":"0x8f3a0000000000000000000000000000000091c2"}'));
        assertTrue(contains(json, '{"trait_type":"From Block","display_type":"number","value":21004118}'));
        assertTrue(contains(json, '{"trait_type":"To Block","display_type":"number","value":21077903}'));
        assertTrue(contains(json, '{"trait_type":"Figure","value":"0"}'));
        assertTrue(contains(json, '{"trait_type":"Panel","display_type":"number","value":12}'));
        assertTrue(contains(json, '{"trait_type":"Agreed","display_type":"number","value":11}'));
        assertTrue(contains(json, '{"trait_type":"Date","value":"2025-10-12"}]}'));
        assertEq(bytes(json)[bytes(json).length - 1], "}");

        SnitchTypes.Case memory c = sample(false, 1, "PEPE");
        c.figure = 123_456_789_000_000_000_000;
        json = art.metadata(42, c);
        assertTrue(contains(json, '{"trait_type":"Verdict","value":"SNITCHED"}'));
        assertTrue(contains(json, '{"trait_type":"Kind","value":"Got in early"}'));
        assertTrue(contains(json, '{"trait_type":"Figure","value":"123456789000000000000"}'));
    }

    function test_metadataEscapesTheSymbol() public view {
        string memory json = art.metadata(1, sample(true, 0, "a\"b"));
        assertTrue(contains(json, '{"trait_type":"Token","value":"a\\"b"}'));
        assertTrue(contains(json, 'never sold a\\"b between'));
    }

    function test_tokenURIIsABase64DataUri() public view {
        string memory uri = art.tokenURI(42, sample(true, 0, "PEPE"));
        assertTrue(startsWith(uri, "data:application/json;base64,"));
        bytes memory payload = bytes(uri);
        bytes memory encoded = new bytes(payload.length - 29);
        for (uint256 i = 0; i < encoded.length; ++i) {
            encoded[i] = payload[29 + i];
        }
        assertEq(Base64.encode(bytes(art.metadata(42, sample(true, 0, "PEPE")))), string(encoded));
    }

    // ---- helpers ----

    /// @dev Howard Hinnant's civil-from-days, as the reference the loop is checked against.
    function civil(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }

    function two(uint256 n) internal pure returns (string memory) {
        return n < 10 ? string.concat("0", vm.toString(n)) : vm.toString(n);
    }

    function startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory p = bytes(prefix);
        if (p.length > a.length) return false;
        for (uint256 i = 0; i < p.length; ++i) {
            if (a[i] != p[i]) return false;
        }
        return true;
    }

    function contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
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
