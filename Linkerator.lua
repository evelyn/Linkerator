-- Ensure Ludwig is present
if not Ludwig then return end

local Linkerator = {}
local updateFrame = CreateFrame("Frame")
updateFrame.timer, updateFrame.targetFrame = 0, nil

-- I love RegEx so much
local AUTOCOMPLETE_PATTERN  = "%[([^%]]+)$"
local BRACKETED_CLOSED      = "%[([^%]]+)%]$"
local EXISTING_LINK_PATTERN = "(|c%x+|H.-|h.-|h|r)"
local ID_PREFIX             = "^#(%d+)"
local SUFFIX_CAPTURE        = "/(%-?%d+)"
local ENCHANT_CAPTURE       = "%.(%d+)"

-- Link layout (Classic/era):
-- item:ItemID:EnchantID:Gem1:Gem2:Gem3:Gem4:SuffixID:UniqueID:LinkLevel
local ITEM_STRING_FMT = "item:%d:%d:0:0:0:0:%d:0:%d"

local function escape_pattern(str)
    return (str:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function player_level()
    return (UnitLevel and UnitLevel("player")) or 0
end

-- Suggest a single unambiguous completion
function Linkerator.UpdateSuggestion(frame)
    if not frame then return end
    local text = frame:GetText()
    local query = text and text:match(AUTOCOMPLETE_PATTERN)
    if not query or query:find("^#") then return end

    local matches = Linkerator.GetPrefixMatches(query)
    if #matches == 1 then
        local fullName = matches[1]
        local newText = text:gsub(AUTOCOMPLETE_PATTERN, "[" .. fullName)
        if newText ~= text then
            frame:SetText(newText)
            frame:HighlightText(#text, -1)
        end
    end
end

-- Build links from [#ItemID/SuffixID.EnchantID] or [Item Name]
function Linkerator.LinkFromQuery(query)
    if not query or query == "" then return nil end

    if query:sub(1,1) == "#" then
        local ItemID_str = query:match(ID_PREFIX)
        if not ItemID_str then return nil end

        local SuffixID = tonumber(query:match(SUFFIX_CAPTURE)) or 0
        local EnchantID = tonumber(query:match(ENCHANT_CAPTURE)) or 0
        local ItemID = tonumber(ItemID_str)

        local itemString = ITEM_STRING_FMT:format(ItemID, EnchantID, SuffixID, player_level())
        local _, link = GetItemInfo(itemString)
        return link
    end

    local id = select(1, Linkerator.ClosestItem(query))
    return id and Ludwig:GetLink(id) or nil
end

-- Type: instant-link on ']', else start suggestion timer
function Linkerator.OnChar(frame)
    local text = frame:GetText() or ""
    if text:sub(-1) == "]" then
        local content = text:match(BRACKETED_CLOSED)
        if content then
            local link = Linkerator.LinkFromQuery(content)
            if link then
                local newText = text:gsub("%[[^%]]+%]$", link)
                frame:SetText(newText)
                frame:SetCursorPosition(#newText)
                return
            end
        end
    end

    updateFrame.timer, updateFrame.targetFrame = 0.25, frame
    updateFrame:SetScript("OnUpdate", Linkerator.OnUpdate)
end

-- Debounce timer
function Linkerator.OnUpdate(self, elapsed)
    self.timer = self.timer - elapsed
    if self.timer <= 0 then
        self:SetScript("OnUpdate", nil)
        Linkerator.UpdateSuggestion(self.targetFrame)
        self.targetFrame = nil
    end
end

-- Tab = force completion
function Linkerator.OnTab(frame)
    updateFrame:SetScript("OnUpdate", nil)
    local text = frame:GetText()
    local query = text and text:match(AUTOCOMPLETE_PATTERN)
    if not query then return end

    local link = Linkerator.LinkFromQuery(query)
    if link then
        local newText = text:gsub(AUTOCOMPLETE_PATTERN, link)
        frame:SetText(newText)
        frame:SetCursorPosition(#newText)
    end
end

-- Ludwig wrappers
function Linkerator.ClosestItem(query, ...)
    if type(query) == "string" then query = escape_pattern(query) end
    return Ludwig:Load("Data") and Ludwig.Database:FindClosest(query, ...) or nil
end

function Linkerator.GetPrefixMatches(prefix)
    local matches = {}
    if type(prefix) ~= "string" or #prefix < 2 then return matches end
    if not Ludwig:Load("Data") then return matches end

    local searchPattern = "^" .. escape_pattern(prefix:lower())
    local function Search(tbl)
        for _, v in pairs(tbl) do
            if type(v) == "table" then
                Search(v)
            elseif type(v) == "string" then
                for name in v:gmatch("....([^_]+)_?") do
                    if name:lower():find(searchPattern) then
                        table.insert(matches, name)
                    end
                end
            end
        end
    end
    Search(Ludwig_Items)
    return matches
end

-- Hook chat frames once
hooksecurefunc("ChatEdit_OnTextChanged", function(frame)
    if not Linkerator[frame] then
        frame:HookScript("OnChar", Linkerator.OnChar)
        frame:HookScript("OnTabPressed", Linkerator.OnTab)
        Linkerator[frame] = true
    end
end)

-- When a link with extra data hits chat edit, print a shortcode
hooksecurefunc("ChatEdit_InsertLink", function(link)
    if type(link) ~= "string" or not link:find("item:") then return end

    local ItemID, EnchantID_raw, SuffixID_raw =
        link:match("item:(%d+):(%d*):%d*:%d*:%d*:%d*:(%-?%d*)")
    if not ItemID then return end

    local EnchantID = tonumber(EnchantID_raw) or 0
    local SuffixID = tonumber(SuffixID_raw) or 0
    if EnchantID == 0 and SuffixID == 0 then return end

    local shortcode = "[#" .. ItemID
    if SuffixID ~= 0 then shortcode = shortcode .. "/" .. SuffixID end
    if EnchantID ~= 0 then shortcode = shortcode .. "." .. EnchantID end
    shortcode = shortcode .. "]"

    print("|cffb00b69[Linkerator]|r " .. link .. " - Shortcode: " .. shortcode)
end)

-- Replace bracketed queries just before send
function Linkerator.ParseAndLinkMessage(message)
    local existingLinks = {}
    local tmp = message:gsub(EXISTING_LINK_PATTERN, function(full)
        table.insert(existingLinks, full)
        return "\1LINK:" .. #existingLinks .. "\2"
    end)

    tmp = tmp:gsub("%[([^%]]+)%]", function(content)
        return Linkerator.LinkFromQuery(content) or "[" .. content .. "]"
    end)

    tmp = tmp:gsub("\1LINK:(%d+)\2", function(i)
        return existingLinks[tonumber(i)] or ""
    end)

    return tmp
end

-- Wrap SendChatMessage
local orig_SendChatMessage = SendChatMessage
SendChatMessage = function(message, chatType, language, channel)
    return orig_SendChatMessage(Linkerator.ParseAndLinkMessage(message), chatType, language, channel)
end
