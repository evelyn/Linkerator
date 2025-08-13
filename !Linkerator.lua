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

    if query then
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

-- Tries to create a link from a query, be it an ID like "#19019" or a name
function Linkerator.LinkFromQuery(query)
    if not query then return nil end

    local itemID = query:match("^#(%d+)$")
    if itemID then
        local id = tonumber(itemID)
        if id then
            local _, link = GetItemInfo(id)
            return link -- will be nil if invalid, which is fine
        end
    else
        local id, _ = Linkerator.ClosestItem(query)
        if id then
            return Ludwig:GetLink(id)
        end
    end
    return nil
end

-- OnChar handles instant linking when ']' is typed, or starts the suggestion timer
function Linkerator.OnChar(frame)
    local text = frame:GetText()

    -- Check if the last character typed was a closing bracket
    if text:sub(-1) == "]" then
        local content = text:match("%[([^%]]+)%]$") -- Get what was just closed
        if content then
            local fullLink = Linkerator.LinkFromQuery(content)
            if fullLink then
                -- We found a link, so replace the plain text with the full, clickable link
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
