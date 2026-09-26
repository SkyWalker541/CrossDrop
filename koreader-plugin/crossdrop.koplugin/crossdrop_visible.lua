--[[
crossdrop_visible.lua — CrossPoint KoSync parity for read positions.

Ports CrossPoint's ProgressMapper (XPath parsing + ParagraphStreamer visible-codepoint
counting) to pure Lua so the plugin can resolve a KOReader last_xpointer like
"/body/DocFragment[15]/body/div/div[2]/p[16]/b[1]/text().0" against the actual spine-item
XHTML and produce the visibleTextOffset that the Xteink's own KoSync would have stored in
progress.bin bytes 6-9.

The reader restores positions with getPageForVisibleTextOffset() (which takes priority over
pageNumber), and that offset is defined by the page LUT the reader built by counting visible
UTF-8 codepoints in the same spine-item XHTML. So this module must count codepoints exactly
like CrossPoint's ParagraphStreamer does: only text inside <body>, outside non-visible
elements, with XML line-ending normalization and entity resolution identical to the expat
build of the LUT.

The spine-item raw bytes are recovered on-device by reading the source epub (io.open, "rb"),
parsing the zip central directory and inflating the item (RFC1951, ported in pure Lua: the
KOReader ffi/zlib only exposes zlib-wrapped uncompress, not raw inflate).

Pure Lua, no KOReader widgets — safe to require at plugin load (Storefront pattern) and
exercised by the harness with fixture chapters.
]]

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, char, sub, find, gsub = string.byte, string.char, string.sub, string.find, string.gsub

local Visible = {}

-- HTML entities: key (with leading '&' and trailing ';') -> UTF-8 replacement string.
-- 253 pairs, values are single codepoints (matches CrossPoint's htmlEntities.cpp).
local ENTITY_TABLE = {
    ["&AElig;"] = "\195\134",
    ["&Aacute;"] = "\195\129",
    ["&Acirc;"] = "\195\130",
    ["&Agrave;"] = "\195\128",
    ["&Alpha;"] = "\206\145",
    ["&Aring;"] = "\195\133",
    ["&Atilde;"] = "\195\131",
    ["&Auml;"] = "\195\132",
    ["&Beta;"] = "\206\146",
    ["&Ccedil;"] = "\195\135",
    ["&Chi;"] = "\206\167",
    ["&Dagger;"] = "\226\128\161",
    ["&Delta;"] = "\206\148",
    ["&ETH;"] = "\195\144",
    ["&Eacute;"] = "\195\137",
    ["&Ecirc;"] = "\195\138",
    ["&Egrave;"] = "\195\136",
    ["&Epsilon;"] = "\206\149",
    ["&Eta;"] = "\206\151",
    ["&Euml;"] = "\195\139",
    ["&Gamma;"] = "\206\147",
    ["&Iacute;"] = "\195\141",
    ["&Icirc;"] = "\195\142",
    ["&Igrave;"] = "\195\140",
    ["&Iota;"] = "\206\153",
    ["&Iuml;"] = "\195\143",
    ["&Kappa;"] = "\206\154",
    ["&Lambda;"] = "\206\155",
    ["&Mu;"] = "\206\156",
    ["&Ntilde;"] = "\195\145",
    ["&Nu;"] = "\206\157",
    ["&OElig;"] = "\197\146",
    ["&Oacute;"] = "\195\147",
    ["&Ocirc;"] = "\195\148",
    ["&Ograve;"] = "\195\146",
    ["&Omega;"] = "\206\169",
    ["&Omicron;"] = "\206\159",
    ["&Oslash;"] = "\195\152",
    ["&Otilde;"] = "\195\149",
    ["&Ouml;"] = "\195\150",
    ["&Phi;"] = "\206\166",
    ["&Pi;"] = "\206\160",
    ["&Prime;"] = "\226\128\179",
    ["&Psi;"] = "\206\168",
    ["&Rho;"] = "\206\161",
    ["&Scaron;"] = "\197\160",
    ["&Sigma;"] = "\206\163",
    ["&THORN;"] = "\195\158",
    ["&Tau;"] = "\206\164",
    ["&Theta;"] = "\206\152",
    ["&Uacute;"] = "\195\154",
    ["&Ucirc;"] = "\195\155",
    ["&Ugrave;"] = "\195\153",
    ["&Upsilon;"] = "\206\165",
    ["&Uuml;"] = "\195\156",
    ["&Xi;"] = "\206\158",
    ["&Yacute;"] = "\195\157",
    ["&Yuml;"] = "\197\184",
    ["&Zeta;"] = "\206\150",
    ["&aacute;"] = "\195\161",
    ["&acirc;"] = "\195\162",
    ["&acute;"] = "\194\180",
    ["&aelig;"] = "\195\166",
    ["&agrave;"] = "\195\160",
    ["&alefsym;"] = "\226\132\181",
    ["&alpha;"] = "\206\177",
    ["&amp;"] = "\38",
    ["&and;"] = "\226\136\167",
    ["&ang;"] = "\226\136\160",
    ["&apos;"] = "\39",
    ["&aring;"] = "\195\165",
    ["&asymp;"] = "\226\137\136",
    ["&atilde;"] = "\195\163",
    ["&auml;"] = "\195\164",
    ["&bdquo;"] = "\226\128\158",
    ["&beta;"] = "\206\178",
    ["&brvbar;"] = "\194\166",
    ["&bull;"] = "\226\128\162",
    ["&cap;"] = "\226\136\169",
    ["&ccedil;"] = "\195\167",
    ["&cedil;"] = "\194\184",
    ["&cent;"] = "\194\162",
    ["&chi;"] = "\207\135",
    ["&circ;"] = "\203\134",
    ["&clubs;"] = "\226\153\163",
    ["&cong;"] = "\226\137\133",
    ["&copy;"] = "\194\169",
    ["&crarr;"] = "\226\134\181",
    ["&cup;"] = "\226\136\170",
    ["&curren;"] = "\194\164",
    ["&dArr;"] = "\226\135\147",
    ["&dagger;"] = "\226\128\160",
    ["&darr;"] = "\226\134\147",
    ["&deg;"] = "\194\176",
    ["&delta;"] = "\206\180",
    ["&diams;"] = "\226\153\166",
    ["&divide;"] = "\195\183",
    ["&eacute;"] = "\195\169",
    ["&ecirc;"] = "\195\170",
    ["&egrave;"] = "\195\168",
    ["&empty;"] = "\226\136\133",
    ["&emsp;"] = "\32",
    ["&ensp;"] = "\32",
    ["&epsilon;"] = "\206\181",
    ["&equiv;"] = "\226\137\161",
    ["&eta;"] = "\206\183",
    ["&eth;"] = "\195\176",
    ["&euml;"] = "\195\171",
    ["&euro;"] = "\226\130\172",
    ["&exist;"] = "\226\136\131",
    ["&fnof;"] = "\198\146",
    ["&forall;"] = "\226\136\128",
    ["&frac12;"] = "\194\189",
    ["&frac14;"] = "\194\188",
    ["&frac34;"] = "\194\190",
    ["&frasl;"] = "\226\129\132",
    ["&gamma;"] = "\206\179",
    ["&ge;"] = "\226\137\165",
    ["&gt;"] = "\62",
    ["&hArr;"] = "\226\135\148",
    ["&harr;"] = "\226\134\148",
    ["&hearts;"] = "\226\153\165",
    ["&hellip;"] = "\226\128\166",
    ["&iacute;"] = "\195\173",
    ["&icirc;"] = "\195\174",
    ["&iexcl;"] = "\194\161",
    ["&igrave;"] = "\195\172",
    ["&image;"] = "\226\132\145",
    ["&infin;"] = "\226\136\158",
    ["&int;"] = "\226\136\171",
    ["&iota;"] = "\206\185",
    ["&iquest;"] = "\194\191",
    ["&isin;"] = "\226\136\136",
    ["&iuml;"] = "\195\175",
    ["&kappa;"] = "\206\186",
    ["&lArr;"] = "\226\135\144",
    ["&lambda;"] = "\206\187",
    ["&lang;"] = "\227\128\136",
    ["&laquo;"] = "\194\171",
    ["&larr;"] = "\226\134\144",
    ["&lceil;"] = "\226\140\136",
    ["&ldquo;"] = "\226\128\156",
    ["&le;"] = "\226\137\164",
    ["&lfloor;"] = "\226\140\138",
    ["&lowast;"] = "\226\136\151",
    ["&loz;"] = "\226\151\138",
    ["&lrm;"] = "\226\128\142",
    ["&lsaquo;"] = "\226\128\185",
    ["&lsquo;"] = "\226\128\152",
    ["&lt;"] = "\60",
    ["&macr;"] = "\194\175",
    ["&mdash;"] = "\226\128\148",
    ["&micro;"] = "\194\181",
    ["&middot;"] = "\194\183",
    ["&minus;"] = "\226\136\146",
    ["&mu;"] = "\206\188",
    ["&nabla;"] = "\226\136\135",
    ["&nbsp;"] = "\194\160",
    ["&ndash;"] = "\226\128\147",
    ["&ne;"] = "\226\137\160",
    ["&ni;"] = "\226\136\139",
    ["&not;"] = "\194\172",
    ["&notin;"] = "\226\136\137",
    ["&nsub;"] = "\226\138\132",
    ["&ntilde;"] = "\195\177",
    ["&nu;"] = "\206\189",
    ["&oacute;"] = "\195\179",
    ["&ocirc;"] = "\195\180",
    ["&oelig;"] = "\197\147",
    ["&ograve;"] = "\195\178",
    ["&oline;"] = "\226\128\190",
    ["&omega;"] = "\207\137",
    ["&omicron;"] = "\206\191",
    ["&oplus;"] = "\226\138\149",
    ["&or;"] = "\226\136\168",
    ["&ordf;"] = "\194\170",
    ["&ordm;"] = "\194\186",
    ["&oslash;"] = "\195\184",
    ["&otilde;"] = "\195\181",
    ["&otimes;"] = "\226\138\151",
    ["&ouml;"] = "\195\182",
    ["&para;"] = "\194\182",
    ["&part;"] = "\226\136\130",
    ["&permil;"] = "\226\128\176",
    ["&perp;"] = "\226\138\165",
    ["&phi;"] = "\207\134",
    ["&pi;"] = "\207\128",
    ["&piv;"] = "\207\150",
    ["&plusmn;"] = "\194\177",
    ["&pound;"] = "\194\163",
    ["&prime;"] = "\226\128\178",
    ["&prod;"] = "\226\136\143",
    ["&prop;"] = "\226\136\157",
    ["&psi;"] = "\207\136",
    ["&quot;"] = "\34",
    ["&rArr;"] = "\226\135\146",
    ["&radic;"] = "\226\136\154",
    ["&rang;"] = "\227\128\137",
    ["&raquo;"] = "\194\187",
    ["&rarr;"] = "\226\134\146",
    ["&rceil;"] = "\226\140\137",
    ["&rdquo;"] = "\226\128\157",
    ["&real;"] = "\226\132\156",
    ["&reg;"] = "\194\174",
    ["&rfloor;"] = "\226\140\139",
    ["&rho;"] = "\207\129",
    ["&rlm;"] = "\226\128\143",
    ["&rsaquo;"] = "\226\128\186",
    ["&rsquo;"] = "\226\128\153",
    ["&sbquo;"] = "\226\128\154",
    ["&scaron;"] = "\197\161",
    ["&sdot;"] = "\226\139\133",
    ["&sect;"] = "\194\167",
    ["&shy;"] = "\194\173",
    ["&sigma;"] = "\207\131",
    ["&sigmaf;"] = "\207\130",
    ["&sim;"] = "\226\136\188",
    ["&spades;"] = "\226\153\160",
    ["&sub;"] = "\226\138\130",
    ["&sube;"] = "\226\138\134",
    ["&sum;"] = "\226\136\145",
    ["&sup1;"] = "\194\185",
    ["&sup2;"] = "\194\178",
    ["&sup3;"] = "\194\179",
    ["&sup;"] = "\226\138\131",
    ["&supe;"] = "\226\138\135",
    ["&szlig;"] = "\195\159",
    ["&tau;"] = "\207\132",
    ["&there4;"] = "\226\136\180",
    ["&theta;"] = "\206\184",
    ["&thetasym;"] = "\207\145",
    ["&thinsp;"] = "\32",
    ["&thorn;"] = "\195\190",
    ["&tilde;"] = "\203\156",
    ["&times;"] = "\195\151",
    ["&trade;"] = "\226\132\162",
    ["&uArr;"] = "\226\135\145",
    ["&uacute;"] = "\195\186",
    ["&uarr;"] = "\226\134\145",
    ["&ucirc;"] = "\195\187",
    ["&ugrave;"] = "\195\185",
    ["&uml;"] = "\194\168",
    ["&upsih;"] = "\207\146",
    ["&upsilon;"] = "\207\133",
    ["&uuml;"] = "\195\188",
    ["&weierp;"] = "\226\132\152",
    ["&xi;"] = "\206\190",
    ["&yacute;"] = "\195\189",
    ["&yen;"] = "\194\165",
    ["&yuml;"] = "\195\191",
    ["&zeta;"] = "\206\182",
    ["&zwj;"] = "\226\128\141",
    ["&zwnj;"] = "\226\128\140",
}
local entity_entries = {}
for k, v in pairs(ENTITY_TABLE) do entity_entries[#entity_entries + 1] = k end
table.sort(entity_entries)

local function entity_lookup(entity) return ENTITY_TABLE[entity] end

-- Count visible codepoints in a UTF-8 string using CrossPoint's lead-byte rule
-- (a byte is a codepoint start unless it's a continuation byte, 0b10xxxxxx).
local function count_codepoints(s)
    local n, i = 0, 1
    local last = #s
    while i <= last do
        local c = byte(s, i)
        if band(c, 0xC0) ~= 0x80 then n = n + 1 end
        i = i + 1
    end
    return n
end

--[[ XPath parsing (ports ProgressMapper.cpp) ]]

local function parseIndex(xpath, prefix, last)
    local prefixLen = #prefix
    local pos
    if last then
        pos = xpath:match(".*" .. prefix:gsub("%p", "%%%0") .. "()")
    else
        pos = xpath:find(prefix .. "()", 1, true)
    end
    if not pos then return -1 end
    local numStart = pos + prefixLen
    local numEnd = xpath:find("]", numStart, true)
    if not numEnd or numEnd == numStart then return -1 end
    local val = 0
    for i = numStart, numEnd - 1 do
        local ch = xpath:sub(i, i)
        if ch < "0" or ch > "9" then return -1 end
        val = val * 10 + (byte(ch) - 48)
    end
    return val
end

local function parseCharOffset(xpath)
    local textPos = xpath:match(".*text()()")
    local dotPos
    if textPos then
        dotPos = xpath:find(".", textPos, true)
    else
        dotPos = xpath:match(".*%.()")
        if dotPos then dotPos = dotPos - 1 end
    end
    if not dotPos or dotPos + 1 > #xpath then return 0 end
    local val = 0
    for i = dotPos + 1, #xpath do
        local ch = xpath:sub(i, i)
        if ch < "0" or ch > "9" then return 0 end
        val = val * 10 + (byte(ch) - 48)
    end
    return val
end

local function parseTextNodeIndex(xpath)
    local textPos = xpath:match(".*text()%[()")
    if not textPos then return 1 end
    local numStart = textPos + 1
    local numEnd = xpath:find("]", numStart, true)
    if not numEnd or numEnd == numStart then return 1 end
    local val = 0
    for i = numStart, numEnd - 1 do
        local ch = xpath:sub(i, i)
        if ch < "0" or ch > "9" then return 1 end
        val = val * 10 + (byte(ch) - 48)
    end
    return val > 0 and val or 1
end

local function isChapterStartXPath(xpath)
    if xpath:find("/p[", 1, true) or xpath:find("/li[", 1, true) then return false end
    local docFragPos = xpath:find("/body/DocFragment[", 1, true)
    if not docFragPos then return false end
    local docFragEnd = xpath:find("]", docFragPos + #"/body/DocFragment[", true)
    if not docFragEnd then return false end
    if docFragEnd + 1 == #xpath then return true end
    if xpath:sub(docFragEnd + 1, docFragEnd + 1) == "." then
        if docFragEnd + 2 > #xpath then return false end
        if xpath:sub(docFragEnd + 2):match("^0*$") and #xpath - (docFragEnd + 1) >= 1 then return true end
        return false
    end
    local docBodyPos = xpath:find("]/body", 1, true)
    if not docBodyPos then return false end
    local bodyContentStart = docBodyPos + #"]/body"
    if bodyContentStart == #xpath then return true end
    if xpath:sub(bodyContentStart + 1, bodyContentStart + 1) ~= "/" then return false end
    bodyContentStart = bodyContentStart + 1
    if bodyContentStart == #xpath then return true end

    local dotPos = xpath:match(".*%.()")
    if not dotPos then return false end
    dotPos = dotPos - 1
    if dotPos <= bodyContentStart or dotPos + 1 > #xpath then return false end

    local terminalEnd = dotPos
    local textNodePos = xpath:match(".*()/text()")
    if textNodePos then
        textNodePos = textNodePos - #"/text()" + 1
        if textNodePos >= bodyContentStart then terminalEnd = textNodePos end
    end
    local slashInBefore = xpath:find("/", bodyContentStart + 1, true)
    if slashInBefore and slashInBefore - 1 < terminalEnd then return false end

    for i = dotPos + 1, #xpath do
        if xpath:sub(i, i) ~= "0" then return false end
    end
    return parseTextNodeIndex(xpath) <= 1
end

local function isBodyTextXPath(xpath)
    local fragPos = xpath:find("/body/DocFragment[", 1, true)
    if not fragPos then return false end
    local afterBracket = xpath:find("]", fragPos + #"/body/DocFragment[", true)
    if not afterBracket then return false end
    local bodyPrefix = "/body/"
    if xpath:sub(afterBracket + 1, afterBracket + #bodyPrefix) ~= bodyPrefix then return false end
    local contentPos = afterBracket + 1 + #bodyPrefix
    return xpath:sub(contentPos, contentPos + #"text()" - 1) == "text()"
end

-- Parse the XPath segment between /body/DocFragment[N]/body/ and the terminal position
-- into an ordered sequence of {tag, siblingIndex}. Returns array (empty on failure).
local function parseXPathSteps(xpath)
    local fragPos = xpath:find("/body/DocFragment[", 1, true)
    if not fragPos then return {} end
    local afterBracket = xpath:find("]", fragPos + #"/body/DocFragment[", true)
    if not afterBracket then return {} end
    local bodyPrefix = "/body/"
    if xpath:sub(afterBracket + 1, afterBracket + #bodyPrefix) ~= bodyPrefix then return {} end
    local pos = afterBracket + 1 + #bodyPrefix

    local stepsEnd = xpath:match(".*()/text()")
    if stepsEnd then
        -- stepsEnd is the position before "/text()"
    else
        local dotPos = xpath:match(".*%.()")
        stepsEnd = dotPos
        if not stepsEnd or stepsEnd <= pos or stepsEnd - 1 + 1 > #xpath then return {} end
        stepsEnd = stepsEnd - 1
        for i = stepsEnd + 1, #xpath do
            if xpath:sub(i, i) < "0" or xpath:sub(i, i) > "9" then return {} end
        end
    end
    if stepsEnd <= pos then return {} end

    local steps = {}
    local i = pos
    while i <= stepsEnd and #steps < 16 do
        local slash = xpath:find("/", i, true)
        local segEnd = (slash and slash < stepsEnd) and slash or stepsEnd
        local bracket = xpath:find("[", i, true)
        local nameEnd = (bracket and bracket < segEnd) and (bracket - 1) or (slash and slash - 1 or stepsEnd)
        local nameLen = nameEnd - i + 1
        if nameLen == 0 or nameLen >= 12 then return {} end
        local step = { tag = xpath:sub(i, nameEnd), siblingIndex = 0 }
        if bracket and bracket < segEnd then
            local closeBracket = xpath:find("]", bracket + 1, true)
            if not closeBracket or closeBracket > segEnd then return {} end
            local idx = 0
            for j = bracket + 1, closeBracket - 1 do
                local ch = xpath:sub(j, j)
                if ch < "0" or ch > "9" then return {} end
                idx = idx * 10 + (byte(ch) - 48)
            end
            step.siblingIndex = idx
        end
        steps[#steps + 1] = step
        i = (slash and slash < stepsEnd) and (slash + 1) or (stepsEnd + 1)
    end
    return steps
end

--[[ ParagraphStreamer port (byte-level, mirrors ProgressMapper.cpp) ]]

local MAX_ENTITY_SIZE = 16
local MAX_XPATH_DEPTH = 16

-- non-visible elements per VisibleTextUtils.isNonVisibleElement (case-insensitive)
local NON_VISIBLE = {
    head = true, style = true, script = true, title = true, rp = true,
}

local Streamer = {}
Streamer.__index = Streamer

function Streamer:init_common()
    self.globalInTag = false
    self.globalInEntity = false
    self.entityBuffer = {}
    self.entityLen = 0
    self.prevCR = false
    self.tagState = 0            -- TAG_IDLE
    self.tagIsClose = false
    self.tagName = {}
    self.tagNameLen = 0
    self.nonVisibleDepth = 0
    self.insideBody = false
    self.htmlDepth = 0
    self.totalVisChars = 0
    self.targetVisChars = 0
    self.revDone = false
    self.revPFound = false
    self.revVisChars = 0
    self.currentTextNode = 0
    self.paragraphHtmlDepth = -1
    self.pCount = 0
    self.liCount = 0
    self.stepEnteredAtDepth = {}
    for i = 1, MAX_XPATH_DEPTH do
        self.stepEnteredAtDepth[i] = -1
        self.siblingCounters = self.siblingCounters or {}
        self.insideStep = self.insideStep or {}
        self.siblingCounters[i] = 0
        self.insideStep[i] = false
    end
    self.matchedDepth = 0
    self.inAttrQuote = false
    self.attrQuoteChar = 0
end

function Streamer:new(o)
    local self = setmetatable({}, Streamer)
    if o and o.fwdTarget then
        self.fwdTarget = o.fwdTarget
        self.fwdResult = 0
        self.fwdCaptured = false
        self.revChar = 0
    elseif o and o.paragraph then
        self.revChar = o.charOff or 0
        self.revParagraph = o.paragraph
        self.targetTextNode = o.textNodeIdx or 1
        self.stepCount = 0
    elseif o and o.steps then
        self.revChar = o.charOff or 0
        self.steps = o.steps
        self.stepCount = #o.steps
        self.targetTextNode = o.textNodeIdx or 1
        self.relaxFirstStepDepth = o.relaxFirstStep or false
    elseif o and o.bodyText ~= nil then
        self.revChar = o.charOff or 0
        self.targetTextNode = o.textNodeIdx or 1
        self.targetBodyText = o.bodyText
        self.stepCount = 0
    else
        self.revChar = 0
        self.stepCount = 0
        self.targetTextNode = o and o.textNodeIdx or 1
    end
    self:init_common()
    return self
end

local function eq_ci(a, b)
    return a:lower() == b:lower()
end

function Streamer:isNonVisibleTag()
    local tn = type(self.tagName) == "table" and table.concat(self.tagName) or self.tagName
    return NON_VISIBLE[tn] ~= nil
end

function Streamer:onVisibleCodepoint()
    self.totalVisChars = self.totalVisChars + 1
    if self.revPFound and not self.revDone then
        local inTargetNode
        if self.stepCount > 0 then
            inTargetNode = self.matchedDepth == self.stepCount
                and self.htmlDepth == self.stepEnteredAtDepth[self.stepCount]
                and self.currentTextNode == self.targetTextNode
        else
            inTargetNode = self.paragraphHtmlDepth >= 0
                and self.htmlDepth == self.paragraphHtmlDepth
                and self.currentTextNode == self.targetTextNode
        end
        if inTargetNode then
            self.revVisChars = self.revVisChars + 1
            if self.revVisChars >= self.revChar then
                self.targetVisChars = self.totalVisChars
                self.revDone = true
            end
        end
    end
end

function Streamer:onVisibleText(text)
    if not text then return end
    for i = 1, #text do
        local c = byte(text, i)
        if band(c, 0xC0) ~= 0x80 then
            self:onVisibleCodepoint()
        end
    end
end

function Streamer:flushEntityAsLiteral()
    for i = 1, self.entityLen do self:onVisibleCodepoint() end
end

function Streamer:finishEntity()
    local resolved = entity_lookup(table.concat(self.entityBuffer))
    if resolved then
        self:onVisibleText(resolved)
    elseif self.entityLen >= 3 and self.entityBuffer[2] == "#" then
        self:onVisibleCodepoint()  -- numeric char reference = single codepoint (expat parity)
    else
        self:flushEntityAsLiteral()
    end
    self.globalInEntity = false
    self.entityLen = 0
end

function Streamer:onLegacyP()
    self.pCount = self.pCount + 1
    if not self.revPFound and self.revParagraph > 0 and self.pCount >= self.revParagraph then
        self.revPFound = true
        self.revVisChars = 0
        self.paragraphHtmlDepth = self.htmlDepth
        self.currentTextNode = 1
        if self.revChar <= 0 and self.targetTextNode <= 1 then
            self.targetVisChars = self.totalVisChars
            self.revDone = true
        end
    end
end

function Streamer:onOpenTag(tag_str)
    self.htmlDepth = self.htmlDepth + 1
    local tn = tag_str or (type(self.tagName) == "table" and table.concat(self.tagName) or self.tagName)
    if eq_ci(tn, "body") then
        self.insideBody = true
        self.bodyHtmlDepth = self.htmlDepth
        if self.targetBodyText then
            self.revPFound = true
            self.paragraphHtmlDepth = self.htmlDepth
            self.currentTextNode = 1
            if self.revChar <= 0 and self.targetTextNode <= 1 then
                self.targetVisChars = self.totalVisChars
                self.revDone = true
            end
        end
        return
    end
    if not self.insideBody then return end

    if self.nonVisibleDepth > 0 or self:isNonVisibleTag() then
        self.nonVisibleDepth = self.nonVisibleDepth + 1
        return
    end

    if self.stepCount == 0 then
        if eq_ci(tn, "p") then self:onLegacyP() end
        return
    end

    if self.revDone then return end

    if eq_ci(tn, "p") then self.pCount = self.pCount + 1 end
    if eq_ci(tn, "li") then self.liCount = self.liCount + 1 end

    if self.matchedDepth < self.stepCount then
        local target = self.steps[self.matchedDepth + 1]
        if eq_ci(tn, target.tag) then
            local atCorrectDepth
            if self.matchedDepth == 0 then
                atCorrectDepth = self.relaxFirstStepDepth or self.htmlDepth == self.bodyHtmlDepth + 1
            else
                atCorrectDepth = self.htmlDepth == self.stepEnteredAtDepth[self.matchedDepth] + 1
            end
            if not atCorrectDepth then return end
            self.siblingCounters[self.matchedDepth + 1] = self.siblingCounters[self.matchedDepth + 1] + 1
            if target.siblingIndex == 0 or self.siblingCounters[self.matchedDepth + 1] == target.siblingIndex then
                self.insideStep[self.matchedDepth + 1] = true
                self.stepEnteredAtDepth[self.matchedDepth + 1] = self.htmlDepth
                self.matchedDepth = self.matchedDepth + 1
                if self.matchedDepth == self.stepCount then
                    self.paragraphAtMatch = self.pCount
                    self.liCountAtMatch = self.liCount
                    self.revPFound = true
                    self.revVisChars = 0
                    self.currentTextNode = 1
                    if self.revChar <= 0 and self.targetTextNode <= 1 then
                        self.targetVisChars = self.totalVisChars
                        self.revDone = true
                    end
                end
            end
        end
    end
end

function Streamer:onCloseTag(tag_str)
    local tn = tag_str or (type(self.tagName) == "table" and table.concat(self.tagName) or self.tagName)
    if eq_ci(tn, "body") then
        self.insideBody = false
        if self.htmlDepth > 0 then self.htmlDepth = self.htmlDepth - 1 end
        return
    end
    if not self.insideBody then
        if self.htmlDepth > 0 then self.htmlDepth = self.htmlDepth - 1 end
        return
    end

    if self.nonVisibleDepth > 0 then
        self.nonVisibleDepth = self.nonVisibleDepth - 1
        if self.htmlDepth > 0 then self.htmlDepth = self.htmlDepth - 1 end
        return
    end

    if self.stepCount == 0 and self.revPFound and not self.revDone
        and self.paragraphHtmlDepth >= 0 and self.htmlDepth == self.paragraphHtmlDepth + 1 then
        self.currentTextNode = self.currentTextNode + 1
        if self.currentTextNode == self.targetTextNode and self.revChar <= 0 then
            self.targetVisChars = self.totalVisChars
            self.revDone = true
        end
    end
    if self.stepCount == 0 and self.revPFound and not self.revDone
        and self.paragraphHtmlDepth >= 0 and self.htmlDepth == self.paragraphHtmlDepth then
        self.revPFound = false
        self.paragraphHtmlDepth = -1
    end

    if self.stepCount > 0 and self.matchedDepth == self.stepCount and self.revPFound and not self.revDone then
        local elementDepth = self.stepEnteredAtDepth[self.stepCount]
        if self.htmlDepth == elementDepth + 1 then
            self.currentTextNode = self.currentTextNode + 1
            if self.currentTextNode == self.targetTextNode and self.revChar <= 0 then
                self.targetVisChars = self.totalVisChars
                self.revDone = true
            end
        end
    end

    if self.stepCount > 0 and self.matchedDepth > 0 then
        local step = self.matchedDepth
        if self.insideStep[step] and self.htmlDepth == self.stepEnteredAtDepth[step] then
            self.insideStep[step] = false
            self.matchedDepth = self.matchedDepth - 1
            if self.matchedDepth < self.stepCount and self.revPFound and not self.revDone then
                self.revPFound = false
            end
            for i = self.matchedDepth + 1, self.stepCount do
                self.siblingCounters[i] = 0
                self.insideStep[i] = false
                self.stepEnteredAtDepth[i] = -1
            end
        end
    end
    if self.htmlDepth > 0 then self.htmlDepth = self.htmlDepth - 1 end
end

local function isAttrWhitespace(c) return c == " " or c == "\t" or c == "\n" or c == "\r" end
local function isAttrNameChar(c)
    local b = byte(c)
    return (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57)
        or c == "_" or c == "-" or c == ":" or c == "."
end

function Streamer:processByteInTag(c)
    if self.tagState == 0 then           -- TAG_IDLE
        if c == "/" then
            self.tagIsClose = true
            self.tagState = 1            -- TAG_IN_NAME
        elseif c ~= "!" and c ~= "?" then
            self.tagIsClose = false
            self.tagName = { [1] = c }
            self.tagNameLen = 1
            self.tagState = 1
        end
    elseif self.tagState == 1 then       -- TAG_IN_NAME
        if c == ">" or c == " " or c == "\t" or c == "\n" or c == "\r" or c == "/" then
            self.tagName = table.concat(self.tagName)
            if self.tagNameLen > 0 then
                if self.tagIsClose then
                    self:onCloseTag()
                else
                    self:onOpenTag()
                end
                if c == "/" and not self.tagIsClose then self:onCloseTag() end
            end
            self.tagNameLen = 0
            self.tagName = {}
            self.tagState = (c == ">") and 0 or 2  -- TAG_IDLE / TAG_ATTRS
        elseif self.tagNameLen + 1 < 12 then
            self.tagName[self.tagNameLen + 1] = c
            self.tagNameLen = self.tagNameLen + 1
        end
    else                                  -- TAG_ATTRS
        if not self.inAttrQuote then
            if c == '"' or c == "'" then
                self.inAttrQuote = true
                self.attrQuoteChar = c
            end
        elseif c == self.attrQuoteChar then
            self.inAttrQuote = false
            self.attrQuoteChar = 0
        end
        if c == "/" and not self.inAttrQuote then
            self:onCloseTag()
        end
    end
end

function Streamer:write(c)
    -- Forward mode (paragraph at byte offset) is IPv4-only in ProgressMapper for
    -- generateXPath() which this plugin does not need; all of our entries are
    -- reverse (ancestry / body-text / legacy paragraph). Keep the write() path identical
    -- to the C++ for the reverse machinery used here.

    if self.globalInEntity then
        if self.entityLen + 1 < MAX_ENTITY_SIZE then
            self.entityLen = self.entityLen + 1
            self.entityBuffer[self.entityLen] = c
        else
            self:flushEntityAsLiteral()
            self.globalInEntity = false
            self.entityLen = 0
        end
        if self.globalInEntity then
            if c == ";" then
                self:finishEntity()
            elseif c == "<" or c == " " or c == "\t" or c == "\n" or c == "\r" then
                self:flushEntityAsLiteral()
                self.globalInEntity = false
                self.entityLen = 0
            end
        end
        return
    end

    local afterCR = self.prevCR
    self.prevCR = false

    if c == "<" then
        self.globalInTag = true
        self.tagState = 0
        self.tagNameLen = 0
        self.tagIsClose = false
        self.tagName = {}
        self.inAttrQuote = false
        self.attrQuoteChar = 0
    elseif c == ">" and not self.inAttrQuote then
        self.globalInTag = false
        self.inAttrQuote = false
        if self.tagState == 1 and self.tagNameLen > 0 then
            self.tagName = table.concat(self.tagName)
            if self.tagIsClose then
                self:onCloseTag()
            else
                self:onOpenTag()
            end
            self.tagNameLen = 0
            self.tagName = {}
        end
        self.tagState = 0
    elseif self.globalInTag then
        self:processByteInTag(c)
    elseif not self.insideBody or self.nonVisibleDepth > 0 then
        -- ignore head/style/script/title text
    else
        if c == "&" then
            self.globalInEntity = true
            self.entityBuffer = { "&" }
            self.entityLen = 1
        elseif c == "\n" and afterCR then
            -- second half of a CRLF: already counted on the preceding CR
        else
            local startsCodepoint = band(byte(c), 0xC0) ~= 0x80
            if startsCodepoint then self:onVisibleCodepoint() end
            self.prevCR = (c == "\r")
        end
    end
end

function Streamer:found() return self.revDone end
function Streamer:getTotalVisChars() return self.totalVisChars end
function Streamer:getTargetVisChars() return self.targetVisChars end

local function streamSpine(xhtml, streamer)
    for i = 1, #xhtml do streamer:write(string.char(byte(xhtml, i))) end
    return true
end

--[[ RFC1951 (DEFLATE) inflater, pure Lua. Input: raw deflate byte string.
Returns inflated byte string or nil on error. This is a straight port of the
well-known fixpoint-free decode: bit reader is LSB-first; Huffman codes are
canonical; literal/length 257-285 map to lengths with extra bits; distances
map to offsets with extra bits. ]]

local inflate_mt = {}
inflate_mt.__index = inflate_mt

local function new_bit_reader(s)
    return setmetatable({ s = s, pos = 1, bit = 0, buf = 0 }, inflate_mt)
end

function inflate_mt:bits(n)
    local v = 0
    for i = 0, n - 1 do
        if self.bit == 0 then
            if self.pos > #self.s then return nil, "eof" end
            self.buf = byte(self.s, self.pos)
            self.pos = self.pos + 1
            self.bit = 8
        end
        v = v + bor(lshift(band(self.buf, 1), i)) -- build little-endian bit order
        self.buf = rshift(self.buf, 1)
        self.bit = self.bit - 1
    end
    return v
end

function inflate_mt:align_byte()
    -- skip to byte boundary (discard remainder of current byte)
    if self.bit ~= 0 and self.bit ~= 8 then
        self.bit = 0
    end
end

function inflate_mt:bytes(n)
    if self.pos + n - 1 > #self.s then return nil, "eof" end
    local out = sub(self.s, self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return out
end

-- Canonical Huffman decoder. counts[b] = number of codes of length b;
-- symbols[b] = ordered symbol list for that length (ascending symbol values,
-- in canonical code order). Returns function(symbol) that consumes bits.
local function make_huff(reader, counts, symbols)
    local first_code = {}
    local offset = {}
    local next_code = 0
    local acc = 0
    for b = 1, 15 do
        first_code[b] = next_code
        offset[b] = acc
        acc = acc + (counts[b] or 0)
        next_code = lshift(next_code + (counts[b] or 0), 1)
    end
    return function()
        local code = 0
        for b = 1, 15 do
            local bit, err = reader:bits(1)
            if not bit then return nil, err end
            code = lshift(code, 1) + bit
            local cnt = counts[b] or 0
            local idx = code - first_code[b]
            if cnt > 0 and idx >= 0 and idx < cnt then
                return symbols[b][idx + 1]
            end
        end
        return nil, "bad code"
    end
end

local LENGTH_BASE = {
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
    67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LENGTH_EXTRA = {
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0,
}
local DIST_BASE = {
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577,
}
local DIST_EXTRA = {
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

function Visible.inflate(raw, expected_size)
    if not raw or #raw == 0 then return nil end
    local reader = new_bit_reader(raw)
    local out = {}
    local win = {}
    local win_pos = 0

    local function emit(b)
        win_pos = win_pos + 1
        out[win_pos] = char(b)
        win[win_pos] = b
    end



    local function copy_match(dist, length)
        if dist > win_pos or dist == 0 then return false end
        local base = win_pos - dist
        for i = 1, length do
            local src = base + i
            local v = win[src]
            if v == nil then return false end
            win_pos = win_pos + 1
            out[win_pos] = char(v)
            win[win_pos] = v
        end
        return true
    end

    while true do
        local bfinal, err = reader:bits(1)
        if not bfinal then return nil end
        local btype, e2 = reader:bits(2)
        if not btype then return nil, e2 end

        if btype == 0 then
            reader:align_byte()
            local len_le = reader:bytes(2)
            local nlen_le = reader:bytes(2)
            if not len_le or not nlen_le then return nil end
            local len = byte(len_le, 1) + byte(len_le, 2) * 256
            local nlen = byte(nlen_le, 1) + byte(nlen_le, 2) * 256
            if bor(len, nlen) ~= 0xFFFF then return nil end  -- sanity: len + ~nlen
            local data = reader:bytes(len)
            if not data then return nil end
            for i = 1, len do emit(byte(data, i)) end
        elseif btype == 1 or btype == 2 then
            local lit_counts, lit_syms = {}, {}
            local dist_counts, dist_syms = {}, {}
            if btype == 1 then
                -- fixed literal/length: 0-143:8, 144-255:9, 256-279:7, 280-287:8
                for i = 0, 287 do lit_counts[7] = 0; lit_counts[8] = 0; lit_counts[9] = 0 end
                for i = 0, 143 do lit_counts[8] = lit_counts[8] + 1 end
                for i = 144, 255 do lit_counts[9] = lit_counts[9] + 1 end
                for i = 256, 279 do lit_counts[7] = lit_counts[7] + 1 end
                for i = 280, 287 do lit_counts[8] = lit_counts[8] + 1 end
                lit_syms[7] = {}; lit_syms[8] = {}; lit_syms[9] = {}
                for i = 256, 279 do lit_syms[7][#lit_syms[7] + 1] = i end
                for i = 0, 143 do lit_syms[8][#lit_syms[8] + 1] = i end
                for i = 280, 287 do lit_syms[8][#lit_syms[8] + 1] = i end
                for i = 144, 255 do lit_syms[9][#lit_syms[9] + 1] = i end
                dist_counts[5] = 32
                dist_syms[5] = {}
                for i = 0, 31 do dist_syms[5][#dist_syms[5] + 1] = i end
            else
                local hlit, e3 = reader:bits(5)
                if not hlit then return nil end
                hlit = hlit + 257
                local hdist, e4 = reader:bits(5)
                if not hdist then return nil end
                hdist = hdist + 1
                local hclen, e5 = reader:bits(4)
                if not hclen then return nil end
                hclen = hclen + 4
                local cl_order = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }
                -- read the HCLEN bit lengths; symbols not listed have length 0
                local cl_len = {}
                for i = 1, hclen do
                    local v, e6 = reader:bits(3)
                    if not v then return nil end
                    cl_len[cl_order[i]] = v
                end
                -- counts keyed by bit length, symbol lists ascending per length
                local cl_counts, cl_syms = {}, {}
                for b = 0, 7 do cl_counts[b] = 0 end
                for sym = 0, 18 do
                    local v = cl_len[sym]
                    if v and v > 0 then
                        cl_counts[v] = cl_counts[v] + 1
                        if not cl_syms[v] then cl_syms[v] = {} end
                        cl_syms[v][#cl_syms[v] + 1] = sym
                    end
                end
                local cl_decode = make_huff(reader, cl_counts, cl_syms)
                local lengths = {}
                local total = hlit + hdist
                local i = 1
                while i <= total do
                    local sym = cl_decode()
                    if not sym then return nil end
                    if sym < 16 then
                        lengths[i] = sym
                        i = i + 1
                    elseif sym == 16 then
                        local extra, e7 = reader:bits(2)
                        if not extra then return nil end
                        local rep = 3 + extra
                        local val = lengths[i - 1]
                        if not val then return nil end
                        for _ = 1, rep do lengths[i] = val; i = i + 1 end
                    elseif sym == 17 then
                        local extra, e8 = reader:bits(3)
                        if not extra then return nil end
                        local rep = 3 + extra
                        for _ = 1, rep do lengths[i] = 0; i = i + 1 end
                    elseif sym == 18 then
                        local extra, e9 = reader:bits(7)
                        if not extra then return nil end
                        local rep = 11 + extra
                        for _ = 1, rep do lengths[i] = 0; i = i + 1 end
                    end
                end
                lit_counts, lit_syms = {}, {}
                for b = 0, 15 do lit_counts[b] = 0; lit_syms[b] = {} end
                for i = 0, hlit - 1 do
                    local b = lengths[i + 1]
                    if b > 0 then lit_counts[b] = lit_counts[b] + 1; lit_syms[b][#lit_syms[b] + 1] = i end
                end
                dist_counts, dist_syms = {}, {}
                for b = 0, 15 do dist_counts[b] = 0; dist_syms[b] = {} end
                for i = 0, hdist - 1 do
                    local b = lengths[hlit + 1 + i]
                    if b > 0 then dist_counts[b] = dist_counts[b] + 1; dist_syms[b][#dist_syms[b] + 1] = i end
                end
            end

            local lit = make_huff(reader, lit_counts, lit_syms)
            local dist = make_huff(reader, dist_counts, dist_syms)
            while true do
                local sym = lit()
                if not sym then return nil end
                if sym < 256 then
                    emit(sym)
                elseif sym == 256 then
                    break
                else
                    local li = sym - 257
                    if li >= #LENGTH_BASE then return nil end
                    local len = LENGTH_BASE[li + 1]
                    local le = LENGTH_EXTRA[li + 1]
                    if le > 0 then
                        local x, e10 = reader:bits(le)
                        if not x then return nil end
                        len = len + x
                    end
                    local dsym = dist()
                    if not dsym then return nil end
                    if dsym >= #DIST_BASE then return nil end
                    local dbase = DIST_BASE[dsym + 1]
                    local de = DIST_EXTRA[dsym + 1]
                    if de > 0 then
                        local x, e11 = reader:bits(de)
                        if not x then return nil end
                        dbase = dbase + x
                    end
                    if not copy_match(dbase, len) then return nil end
                end
            end
        else
            return nil  -- bad block type
        end

        if bfinal == 1 then break end
    end

    local result = table.concat(out)
    if expected_size and #result ~= expected_size then
        return nil  -- size mismatch: caller can decide
    end
    return result
end

--[[ Resolver: replicate ProgressMapper::toCrossPoint's offset resolution path ]]

-- Returns visibleTextOffset (number) or nil.
function Visible.resolveVisibleTextOffset(xhtml, xpath)
    if not xhtml or #xhtml == 0 or not xpath or #xpath == 0 then return nil end

    local xpathChar = parseCharOffset(xpath)
    local xpathTextNode = parseTextNodeIndex(xpath)
    local steps = parseXPathSteps(xpath)
    local useAncestry = #steps > 0
    local useBodyText = not useAncestry and isBodyTextXPath(xpath)

    if useAncestry then
        local function try(steps, relax)
            local s = Streamer:new({ steps = steps, charOff = xpathChar, textNodeIdx = xpathTextNode, relaxFirstStep = relax })
            streamSpine(xhtml, s)
            return s
        end
        local strict = try(steps, false)
        if strict:found() then return strict:getTargetVisChars() end
        local relaxed = try(steps, true)
        if relaxed:found() then return relaxed:getTargetVisChars() end
    elseif useBodyText then
        local s = Streamer:new({ bodyText = true, charOff = xpathChar, textNodeIdx = xpathTextNode })
        streamSpine(xhtml, s)
        if s:found() then return s:getTargetVisChars() end
    else
        local xpathP = parseIndex(xpath, "/p[", true)
        if xpathP > 0 then
            local s = Streamer:new({ paragraph = xpathP, charOff = xpathChar, textNodeIdx = xpathTextNode })
            streamSpine(xhtml, s)
            if s:found() then return s:getTargetVisChars() end
        end
    end

    if isChapterStartXPath(xpath) then return 0 end
    return nil
end

--[[ Minimal zip reading for epub spine-item extraction ]]

local function u16le(s, i) return byte(s, i) + byte(s, i + 1) * 256 end
local function u32le(s, i)
    return byte(s, i) + byte(s, i + 1) * 256 + byte(s, i + 2) * 65536 + byte(s, i + 3) * 16777216
end

-- Find the zip central directory offset by scanning for EOCD from the end.
local function find_central_dir(data)
    local n = #data
    if n < 22 then return nil end
    local i = n - 21
    while i >= 1 do
        if byte(data, i) == 0x50 and byte(data, i + 1) == 0x4b
            and byte(data, i + 2) == 0x05 and byte(data, i + 3) == 0x06 then
            return u32le(data, i + 16)
        end
        i = i - 1
    end
    return nil
end

-- Build { name -> {method, compSize, uncompSize, localOffset} } from the central directory.
local function zip_index(data)
    local cd = find_central_dir(data)
    if not cd then return {} end
    local idx = {}
    local pos = cd + 1
    local n = #data
    while pos + 4 <= n do
        local sig = u32le(data, pos)
        if sig ~= 0x02014b50 then break end
        local method = u16le(data, pos + 10)
        local compSize = u32le(data, pos + 20)
        local uncompSize = u32le(data, pos + 24)
        local nameLen = u16le(data, pos + 28)
        local extraLen = u16le(data, pos + 30)
        local commentLen = u16le(data, pos + 32)
        local localOffset = u32le(data, pos + 42)
        local name = sub(data, pos + 46, pos + 45 + nameLen)
        idx[name] = { method = method, compSize = compSize, uncompSize = uncompSize, localOffset = localOffset }
        pos = pos + 46 + nameLen + extraLen + commentLen
    end
    return idx
end

local function read_zip_entry(data, idx, name)
    local e = idx[name]
    if not e then return nil end
    local lh = e.localOffset
    if u32le(data, lh + 1) ~= 0x04034b50 then return nil end
    local nameLen = u16le(data, lh + 26 + 1)
    local extraLen = u16le(data, lh + 28 + 1)
    local start = lh + 30 + nameLen + extraLen
    local raw = sub(data, start + 1, start + e.compSize)
    if e.method == 8 then
        return Visible.inflate(raw, e.uncompSize)
    elseif e.method == 0 then
        return raw
    end
    return nil  -- unsupported compression (bzip2, LZMA, ...)
end

local function decode_uri_escapes(s)
    return s:gsub("%%(%x%x)", function(h) return char(tonumber(h, 16)) end)
end

-- Find content.opf relative path from container.xml (rootfile full-path).
local function opf_from_container(container)
    local full = container:match('rootfile[^>]*full%-path="([^"]*)"')
    if not full then
        full = container:match("rootfile[^>]*full%-path='([^']*)'")
    end
    return full
end

-- Parse content.opf: return spine hrefs in order (basePath + manifest href).
local function spine_hrefs(opf, basePath)
    local manifest = {}
    local mstart = opf:find("<manifest", 1, true)
    local mend = opf:find("</manifest>", 1, true)
    if mstart and mend then
        local block = sub(opf, mstart, mend)
        for id, href, mtype in block:gmatch('<item[^>]*id="([^"]*)"[^>]*href="([^"]*)"[^>]*media%-type="([^"]*)"') do
            manifest[id] = { href = href, mtype = mtype }
        end
        -- fallback: attribute order not guaranteed
        if not next(manifest) then
            for tag in block:gmatch("<item[^>]*>") do
                local id = tag:match('id="([^"]*)"')
                local href = tag:match('href="([^"]*)"')
                if id and href then manifest[id] = { href = href, mtype = "" } end
            end
        end
    end
    local hrefs = {}
    local sstart = opf:find("<spine", 1, true)
    local send_ = opf:find("</spine>", 1, true)
    if sstart and send_ then
        local block = sub(opf, sstart, send_)
        for idref in block:gmatch('itemref%s+idref="([^"]*)"') do
            local item = manifest[idref]
            if item then
                local href = decode_uri_escapes(basePath .. item.href)
                hrefs[#hrefs + 1] = href
            end
        end
    end
    return hrefs
end

--[[ On-device entry point: read the epub and resolve the xpointer to a visibleTextOffset ]]

-- Returns { offset = number, spineIndex = number } (spineIndex 0-based) or nil.
-- file_path: local epub path; spineIndex: 0-based spine index; xpath: KOReader last_xpointer.
-- Any failure returns nil so callers fall back to their existing heuristic.
function Visible.resolve(file_path, spineIndex, xpath)
    if not file_path or not io.open then return nil end
    local fh = io.open(file_path, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    if not data then return nil end
    local ok, res = pcall(function()
        local idx = zip_index(data)
        local containerEntry = read_zip_entry(data, idx, "META-INF/container.xml")
        if not containerEntry then return nil end
        local opfPath = opf_from_container(containerEntry)
        if not opfPath then return nil end
        if opfPath:sub(1, 1) == "/" then opfPath = opfPath:sub(2) end
        local basePath = opfPath:match("^(.*)/") or ""
        if basePath ~= "" then basePath = basePath .. "/" end
        local opf = read_zip_entry(data, idx, opfPath)
        if not opf then return nil end
        local hrefs = spine_hrefs(opf, basePath)
        local href = hrefs[spineIndex + 1]
        if not href then return nil end
        local xhtml = read_zip_entry(data, idx, href)
        if not xhtml then return nil end
        local offset = Visible.resolveVisibleTextOffset(xhtml, xpath)
        if offset == nil then return nil end
        return { offset = offset, spineIndex = spineIndex }
    end)
    if not ok then return nil end
    return res
end

-- Exposed for the pure-Lua harness (device-true components, no stubs needed).
Visible.zip_index = zip_index
Visible.read_zip_entry = read_zip_entry
Visible.opf_from_container = opf_from_container
Visible.spine_hrefs = spine_hrefs
Visible.inflate = Visible.inflate
Visible.count_codepoints = count_codepoints
Visible.parseCharOffset = parseCharOffset
Visible.parseTextNodeIndex = parseTextNodeIndex
Visible.isChapterStartXPath = isChapterStartXPath
Visible.isBodyTextXPath = isBodyTextXPath
Visible.parseXPathSteps = parseXPathSteps
Visible.Streamer = Streamer
Visible.streamSpine = streamSpine
Visible.entityLookup = entity_lookup
Visible.decodeUriEscapes = decode_uri_escapes

return Visible
