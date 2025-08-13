-- Ensure Ludwig and its data are loaded before running
if not Ludwig then return end

local Linkerator = {}

local updateFrame = CreateFrame("Frame")
updateFrame.timer = 0
updateFrame.targetFrame = nil

local AUTOCOMPLETE_PATTERN = "%[([^%]]+)$"

-- This runs when the user has stopped typing
function Linkerator.UpdateSuggestion(frame)
    if not frame then return end
    local text = frame:GetText()
    local query = text:match(AUTOCOMPLETE_PATTERN)

    if query and not query:find("^#") then -- Don't autocomplete for ID-based links
        -- find all possible matches
        local matches = Linkerator.GetPrefixMatches(query)

        -- only autocomplete if there is exactly one possible result
        if #matches == 1 then
            local originalTextLength = #text
            local fullName = matches[1]
            local newText = text:gsub(AUTOCOMPLETE_PATTERN, "[" .. fullName)
            
            if newText ~= text then
                frame:SetText(newText)
                frame:HighlightText(originalTextLength, -1)
            end
        end
    end
end

-- Tries to create a link from a query, with graceful fallbacks for shortcodes
function Linkerator.LinkFromQuery(query)
    if not query then return nil end

    if query:sub(1,1) == "#" then
        local content = query:sub(2) -- Get everything after the '#'
        
        -- This robust method correctly parses all parts of the shortcode
        local itemID_str, enchantID_str = strsplit(".", content)
        local final_itemID_str, suffixID_str = strsplit("/", itemID_str)

        local itemID = tonumber(final_itemID_str)
        local enchantID = tonumber(enchantID_str)
        local suffixID = tonumber(suffixID_str)

        if not itemID then return nil end -- The base ID must exist

        -- Attempt to link the most specific version first (full combo)
        if suffixID and enchantID then
            local itemString = "item:" .. itemID .. ":" .. enchantID .. ":::::" .. suffixID
            local _, link = GetItemInfo(itemString)
            if link then return link end
        end

        -- Fallback 1: Try with just suffix or just enchant
        if suffixID then
            local itemString = "item:" .. itemID .. ":::::" .. suffixID
            local _, link = GetItemInfo(itemString)
            if link then return link end
        end
        if enchantID then
            local itemString = "item:" .. itemID .. ":" .. enchantID .. ":::::0"
            local _, link = GetItemInfo(itemString)
            if link then return link end
        end

        -- Fallback 2: Try with only the base ItemID
        local _, link = GetItemInfo(itemID)
        if link then return link end
    else
        -- Fallback to searching by name if it's not a shortcode
        local id, _ = Linkerator.ClosestItem(query)
        if id then
            return Ludwig:GetLink(id)
        end
    end

    return nil -- All attempts failed
end

-- OnChar handles instant linking when ']' is typed, or starts the suggestion timer
function Linkerator.OnChar(frame)
    local text = frame:GetText()

    if text:sub(-1) == "]" then
        local content = text:match("%[([^%]]+)%]$") -- Get what was just closed
        if content then
            local fullLink = Linkerator.LinkFromQuery(content)
            if fullLink then
                local newText = text:gsub("%[[^%]]+%]$", fullLink)
                frame:SetText(newText)
                frame:SetCursorPosition(string.len(newText))
                return -- Stop processing to avoid starting the suggestion timer
            end
        end
    end

    -- If we didn't just link something, start the timer for name suggestions
    updateFrame.timer = 0.25
    updateFrame.targetFrame = frame
    updateFrame:SetScript("OnUpdate", Linkerator.OnUpdate)
end

-- The timer's update function
function Linkerator.OnUpdate(self, elapsed)
    self.timer = self.timer - elapsed
    if self.timer <= 0 then
        -- User paused, so show a suggestion if we have one
        self:SetScript("OnUpdate", nil)
        Linkerator.UpdateSuggestion(self.targetFrame)
        self.targetFrame = nil
    end
end

-- Tab forces a completion and creates the link
function Linkerator.OnTab(frame)
    updateFrame:SetScript("OnUpdate", nil) -- Cancel any pending suggestion
    local text = frame:GetText()
    local query = text:match(AUTOCOMPLETE_PATTERN)

    if query then
        local fullLink = Linkerator.LinkFromQuery(query)
        if fullLink then
            local newText = text:gsub(AUTOCOMPLETE_PATTERN, fullLink)
            frame:SetText(newText)
            frame:SetCursorPosition(string.len(newText))
        end
    end
end

-- Wrapper for Ludwig's "FindClosest"
function Linkerator.ClosestItem(query, ...)
    if type(query) == "string" then
        query = query:gsub("([%(%)%.%%%+%-*?%[%]%^%$])", "%%%1")
    end
    if Ludwig:Load('Data') then
        return Ludwig.Database:FindClosest(query, ...)
    end
    return nil
end

-- Get ALL matches for a prefix
function Linkerator.GetPrefixMatches(prefix)
    local matches = {}
    if type(prefix) ~= "string" or #prefix < 2 then return matches end

    if Ludwig:Load('Data') then
        local searchPattern = "^" .. prefix:lower():gsub("([%(%)%.%%%+%-*?%[%]%^%$])", "%%%1")
        
        -- Recursively search the nested Ludwig database
        local function SearchLudwigData(dataTable)
            for _, value in pairs(dataTable) do
                if type(value) == "table" then
                    SearchLudwigData(value) -- It's another table, go deeper
                elseif type(value) == "string" then
                    -- We've hit the item strings, so we can search them
                    for name in value:gmatch("....([^_]+)_?") do
                        if name:lower():find(searchPattern) then
                            table.insert(matches, name)
                        end
                    end
                end
            end
        end

        SearchLudwigData(Ludwig_Items)
    end
    return matches
end

-- Hook chat frame events
hooksecurefunc('ChatEdit_OnTextChanged', function(frame)
    if not Linkerator[frame] then
        frame:HookScript('OnChar', Linkerator.OnChar)
        frame:HookScript('OnTabPressed', Linkerator.OnTab)
        Linkerator[frame] = true
    end
end)

-- This function prints a shortcode anytime a link with extra data is inserted into chat
hooksecurefunc("ChatEdit_InsertLink", function(link)
    if not link or type(link) ~= "string" or not link:find("item:") then
        return
    end

    local itemID, enchantID, suffixID = link:match("item:(%d+):(%d*):%d*:%d*:%d*:%d*:(%-?%d*)")
    
    if itemID then
        enchantID = tonumber(enchantID) or 0
        suffixID = tonumber(suffixID) or 0
        
        -- Only print a message if the item has an enchant or a suffix
        if enchantID ~= 0 or suffixID ~= 0 then
            local shortcode_text = "[#" .. itemID
            
            if suffixID ~= 0 then
                shortcode_text = shortcode_text .. "/" .. suffixID
            end
            if enchantID ~= 0 then
                shortcode_text = shortcode_text .. "." .. enchantID
            end
            shortcode_text = shortcode_text .. "]"

            local prefix = "|cffb00b69[Linkerator]|r "
            local message = prefix .. link .. " - Shortcode: " .. shortcode_text
            print(message)
        end
    end
end)

-- Linkifies any unlinked text in a message just before sending
function Linkerator.ParseAndLinkMessage(message)
    local existingLinks = {}
    local tempMessage = message:gsub("(|c%x+|H.-|h.-|h|r)", function(fullLink)
        table.insert(existingLinks, fullLink)
        return "\1LINK:" .. #existingLinks .. "\2"
    end)
    tempMessage = tempMessage:gsub("%[([^%]]+)%]", function(content)
        local link = Linkerator.LinkFromQuery(content)
        if link then
            return link
        else
            return "[" .. content .. "]"
        end
    end)
    local finalMessage = tempMessage:gsub("\1LINK:(%d+)\2", function(index)
        return existingLinks[tonumber(index)] or ""
    end)
    return finalMessage
end

local originalSendChatMessage = SendChatMessage
SendChatMessage = function(message, chatType, language, channel)
    local linkedMessage = Linkerator.ParseAndLinkMessage(message)
    originalSendChatMessage(linkedMessage, chatType, language, channel)
end
