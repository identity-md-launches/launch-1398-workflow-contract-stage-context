// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SnitchTypes} from "./SnitchTypes.sol";

/// @title The report card renderer
/// @notice Stateless. Takes a case as SnitchDesk stores it and renders ERC-721 metadata with an
/// on-chain SVG: a page torn from a case file, the claim as one sentence, the panel numbers, the
/// UTC date and a tilted rubber stamp, CLEAN in green or SNITCHED in red. Every string that came
/// from outside (the token symbol) is escaped for both SVG and JSON.
contract SnitchArt {
    using Strings for uint256;
    using Strings for address;

    string internal constant PAPER = "#E9D8A6";
    string internal constant INK = "#1C1A17";
    string internal constant RED = "#C62A1F";
    string internal constant GREEN = "#23784A";
    string internal constant HEADLINE = "font-family='Archivo Narrow,Arial Narrow,Helvetica,Arial,sans-serif'";
    string internal constant MONO = "font-family='IBM Plex Mono,Menlo,Consolas,monospace'";
    string internal constant BODY = "font-family='Helvetica,Arial,sans-serif'";

    /// @notice The full token URI: a base64 data URI of the JSON metadata.
    function tokenURI(uint256 caseId, SnitchTypes.Case memory c) external pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(metadata(caseId, c))));
    }

    /// @notice The JSON metadata, unencoded.
    function metadata(uint256 caseId, SnitchTypes.Case memory c) public pure returns (string memory) {
        string memory head = string.concat(
            '{"name":"Snitch Report No. ',
            caseNumber(caseId),
            '","description":"',
            escapeJson(claim(c)),
            ". ",
            verdictWord(c.verdict),
            ", checked by ",
            uint256(c.agreed).toString(),
            " of ",
            uint256(c.panelSize).toString(),
            ' agents.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(caseId, c))),
            '",'
        );
        return string.concat(head, '"attributes":', attributes(c), "}");
    }

    /// @notice The metadata attributes: verdict, kind, token, wallet, blocks, figure, panel, date.
    function attributes(SnitchTypes.Case memory c) public pure returns (string memory) {
        string memory first = string.concat(
            '[{"trait_type":"Verdict","value":"',
            verdictWord(c.verdict),
            '"},{"trait_type":"Kind","value":"',
            kindName(c.kind),
            '"},{"trait_type":"Token","value":"',
            escapeJson(c.symbol),
            '"},{"trait_type":"Token Address","value":"',
            c.token.toHexString(),
            '"},{"trait_type":"Wallet","value":"',
            c.wallet.toHexString(),
            '"},'
        );
        string memory second = string.concat(
            '{"trait_type":"From Block","display_type":"number","value":',
            uint256(c.fromBlock).toString(),
            '},{"trait_type":"To Block","display_type":"number","value":',
            uint256(c.toBlock).toString(),
            '},{"trait_type":"Figure","value":"',
            c.figure.toString(),
            '"},{"trait_type":"Panel","display_type":"number","value":',
            uint256(c.panelSize).toString(),
            '},{"trait_type":"Agreed","display_type":"number","value":',
            uint256(c.agreed).toString(),
            '},{"trait_type":"Date","value":"',
            utcDate(c.issuedAt),
            '"}]'
        );
        return string.concat(first, second);
    }

    /// @notice The claim as one plain sentence, unescaped.
    function claim(SnitchTypes.Case memory c) public pure returns (string memory) {
        return string.concat(
            shortAddress(c.wallet),
            " ",
            c.kind == SnitchTypes.KIND_NEVER_SOLD ? "never sold " : "got in early on ",
            c.symbol,
            " between block ",
            commas(c.fromBlock),
            " and block ",
            commas(c.toBlock)
        );
    }

    /// @notice The SVG card, unencoded.
    function svg(uint256 caseId, SnitchTypes.Case memory c) public pure returns (string memory) {
        string memory top = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 480 640' width='480' height='640'>",
            "<rect width='480' height='640' fill='",
            PAPER,
            "'/>",
            "<rect x='14' y='14' width='452' height='612' fill='none' stroke='",
            INK,
            "' stroke-width='2'/>",
            "<line x1='40' y1='96' x2='440' y2='96' stroke='",
            INK,
            "' stroke-width='2'/>",
            "<text x='40' y='64' ",
            HEADLINE,
            " font-size='40' font-weight='700' fill='",
            INK,
            "'>SNITCH</text>",
            "<text x='40' y='86' ",
            HEADLINE,
            " font-size='18' font-weight='700' fill='",
            INK,
            "'>CASE FILE No. ",
            caseNumber(caseId),
            "</text>"
        );
        return string.concat(top, svgClaim(c), svgFooter(c), svgStamp(c.verdict), "</svg>");
    }

    function svgClaim(SnitchTypes.Case memory c) internal pure returns (string memory) {
        string memory symbol = escapeXml(c.symbol);
        return string.concat(
            "<text x='40' y='150' ",
            BODY,
            " font-size='22' fill='",
            INK,
            "'>",
            "<tspan x='40' dy='0' ",
            MONO,
            ">",
            shortAddress(c.wallet),
            "</tspan>",
            "<tspan x='40' dy='34'>",
            c.kind == SnitchTypes.KIND_NEVER_SOLD ? "never sold " : "got in early on ",
            symbol,
            "</tspan>",
            "<tspan x='40' dy='34'>between block <tspan ",
            MONO,
            ">",
            commas(c.fromBlock),
            "</tspan></tspan>",
            "<tspan x='40' dy='34'>and block <tspan ",
            MONO,
            ">",
            commas(c.toBlock),
            "</tspan></tspan>",
            "</text>"
        );
    }

    function svgFooter(SnitchTypes.Case memory c) internal pure returns (string memory) {
        return string.concat(
            "<text x='40' y='540' ",
            BODY,
            " font-size='18' fill='",
            INK,
            "'>Checked by ",
            uint256(c.panelSize).toString(),
            " agents. ",
            uint256(c.agreed).toString(),
            " agreed.</text>",
            "<text x='40' y='572' ",
            MONO,
            " font-size='16' fill='",
            INK,
            "'>",
            utcDate(c.issuedAt),
            " UTC</text>",
            "<text x='40' y='604' ",
            MONO,
            " font-size='12' fill='",
            INK,
            "'>",
            c.token.toHexString(),
            "</text>"
        );
    }

    /// @dev A tilted rubber stamp: CLEAN in green, SNITCHED in red.
    function svgStamp(bool verdict) internal pure returns (string memory) {
        string memory colour = verdict ? GREEN : RED;
        return string.concat(
            "<g transform='rotate(-12 300 420)' opacity='0.92'>",
            "<rect x='",
            verdict ? "210" : "150",
            "' y='380' width='",
            verdict ? "180" : "300",
            "' height='80' rx='6' fill='none' stroke='",
            colour,
            "' stroke-width='6'/>",
            "<text x='300' y='437' text-anchor='middle' ",
            HEADLINE,
            " font-size='",
            verdict ? "56" : "58",
            "' font-weight='700' letter-spacing='4' fill='",
            colour,
            "'>",
            verdictWord(verdict),
            "</text></g>"
        );
    }

    // ---- small helpers ----

    function verdictWord(bool verdict) public pure returns (string memory) {
        return verdict ? "CLEAN" : "SNITCHED";
    }

    function kindName(uint8 kind) public pure returns (string memory) {
        return kind == SnitchTypes.KIND_NEVER_SOLD ? "Never sold" : "Got in early";
    }

    /// @notice A case number padded to at least four digits: 42 becomes 0042.
    function caseNumber(uint256 caseId) public pure returns (string memory) {
        string memory digits = caseId.toString();
        bytes memory raw = bytes(digits);
        if (raw.length >= 4) return digits;
        bytes memory out = new bytes(4);
        uint256 pad = 4 - raw.length;
        for (uint256 i = 0; i < 4; ++i) {
            out[i] = i < pad ? bytes1("0") : raw[i - pad];
        }
        return string(out);
    }

    /// @notice 0x8f3a…91c2: the first four and last four hex digits.
    function shortAddress(address a) public pure returns (string memory) {
        bytes memory hex_ = bytes(a.toHexString());
        bytes memory out = new bytes(6 + 3 + 4);
        for (uint256 i = 0; i < 6; ++i) {
            out[i] = hex_[i];
        }
        // U+2026 HORIZONTAL ELLIPSIS in UTF-8
        out[6] = 0xE2;
        out[7] = 0x80;
        out[8] = 0xA6;
        for (uint256 i = 0; i < 4; ++i) {
            out[9 + i] = hex_[38 + i];
        }
        return string(out);
    }

    /// @notice A number with thousands separators: 21004118 becomes 21,004,118.
    function commas(uint256 n) public pure returns (string memory) {
        bytes memory raw = bytes(n.toString());
        uint256 len = raw.length;
        uint256 separators = (len - 1) / 3;
        bytes memory out = new bytes(len + separators);
        uint256 o = out.length;
        uint256 group = 0;
        for (uint256 i = len; i > 0; --i) {
            if (group == 3) {
                out[--o] = ",";
                group = 0;
            }
            out[--o] = raw[i - 1];
            ++group;
        }
        return string(out);
    }

    /// @notice A unix timestamp as YYYY-MM-DD, UTC.
    /// @dev Walks years then months from 1970. Bounded by the age of the chain and only ever
    /// called from a view, so the loop is cheap and keeps the arithmetic to additions.
    function utcDate(uint64 timestamp) public pure returns (string memory) {
        uint256 days_ = uint256(timestamp) / 86400;
        uint256 year = 1970;
        while (true) {
            uint256 inYear = isLeap(year) ? 366 : 365;
            if (days_ < inYear) break;
            days_ -= inYear;
            ++year;
        }
        uint256 month = 1;
        while (true) {
            uint256 inMonth = daysInMonth(year, month);
            if (days_ < inMonth) break;
            days_ -= inMonth;
            ++month;
        }
        uint256 day = days_ + 1;
        return string.concat(year.toString(), "-", twoDigits(month), "-", twoDigits(day));
    }

    function isLeap(uint256 year) internal pure returns (bool) {
        if (year % 400 == 0) return true;
        if (year % 100 == 0) return false;
        return year % 4 == 0;
    }

    function daysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 2) return isLeap(year) ? 29 : 28;
        if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
        return 31;
    }

    function twoDigits(uint256 n) internal pure returns (string memory) {
        return n < 10 ? string.concat("0", n.toString()) : n.toString();
    }

    /// @notice Escapes &, <, >, " and ' for use inside SVG text and attributes.
    function escapeXml(string memory s) public pure returns (string memory) {
        bytes memory raw = bytes(s);
        uint256 extra = 0;
        for (uint256 i = 0; i < raw.length; ++i) {
            bytes1 ch = raw[i];
            if (ch == "&") extra += 4;
            else if (ch == "<" || ch == ">") extra += 3;
            else if (ch == '"' || ch == "'") extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(raw.length + extra);
        uint256 o = 0;
        for (uint256 i = 0; i < raw.length; ++i) {
            bytes1 ch = raw[i];
            if (ch == "&") o = put(out, o, "&amp;");
            else if (ch == "<") o = put(out, o, "&lt;");
            else if (ch == ">") o = put(out, o, "&gt;");
            else if (ch == '"') o = put(out, o, "&quot;");
            else if (ch == "'") o = put(out, o, "&apos;");
            else out[o++] = ch;
        }
        return string(out);
    }

    /// @notice Escapes ", \ and control characters for use inside a JSON string.
    function escapeJson(string memory s) public pure returns (string memory) {
        bytes memory raw = bytes(s);
        uint256 extra = 0;
        for (uint256 i = 0; i < raw.length; ++i) {
            bytes1 ch = raw[i];
            if (ch == '"' || ch == "\\") extra += 1;
            else if (uint8(ch) < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(raw.length + extra);
        uint256 o = 0;
        for (uint256 i = 0; i < raw.length; ++i) {
            bytes1 ch = raw[i];
            if (ch == '"') o = put(out, o, '\\"');
            else if (ch == "\\") o = put(out, o, "\\\\");
            else if (uint8(ch) < 0x20) o = put(out, o, string.concat("\\u00", hexByte(uint8(ch))));
            else out[o++] = ch;
        }
        return string(out);
    }

    function hexByte(uint8 b) internal pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory out = new bytes(2);
        out[0] = digits[b >> 4];
        out[1] = digits[b & 0x0f];
        return string(out);
    }

    function put(bytes memory out, uint256 o, string memory piece) internal pure returns (uint256) {
        bytes memory p = bytes(piece);
        for (uint256 i = 0; i < p.length; ++i) {
            out[o + i] = p[i];
        }
        return o + p.length;
    }
}
