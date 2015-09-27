--[[
        Based upon Victor Scattone's code located at https://github.com/victorso/.hammerspoon/blob/master/tools/clipboard.lua

        Todo:
          [x] add max size for items to be saved
          [x] check against nspasterboard.org identifiers for transient and confidential
          [ ] add alternate (ctrl/right-click) menu to adjust settings
          [ ] save settings with hs.settings
          [ ] don't replicate duplicates

]]--

local utf8 = require("hs.utf8")
-- local menuTitle = utf8.codepointToUTF8("U+1f4ce") -- paperclip
local menuTitle = utf8.codepointToUTF8("U+1f4cb") -- clipboard

-- See http://nspasteboard.org
local ignoreTheseIdentifiers = {
    ["de.petermaurer.TransientPasteboardType"] = true, -- Transient : Textpander, TextExpander, Butler
    ["com.typeit4me.clipping"] = true,                 -- Transient : TypeIt4Me
    ["Pasteboard generator type"] = true,              -- Transient : Typinator
    ["com.agilebits.onepassword"] = true,              -- Confidential : 1Password
    ["org.nspasteboard.TransientType"] = true,         -- Universal, Transient
    ["org.nspasteboard.ConcealedType"] = true,         -- Universal, Concealed
    ["org.nspasteboard.AutoGeneratedType"] = true,     -- Universal, Automatic
}

local maxSize = 2 * 1024 * 1024 -- if it's larger than this, don't record

-- Feel free to change those settings
local frequency = 0.8 -- Speed in seconds to check for clipboard changes. If you check too frequently, you will loose performance, if you check sparsely you will loose copies
local hist_size = 20 -- How many items to keep on history
local label_length = 40 -- How wide (in characters) the dropdown menu should be. Copies larger than this will have their label truncated and end with "…" (unicode for elipsis ...)
local honor_clearcontent = false --asmagill request. If any application clears the pasteboard, we also remove it from the history https://groups.google.com/d/msg/hammerspoon/skEeypZHOmM/Tg8QnEj_N68J
local pasteOnSelect = false -- Auto-type on click

-- Don't change anything bellow this line
local jumpcut = hs.menubar.new()
jumpcut:setTooltip("Jumpcut replacement")
local pasteboard = require("hs.pasteboard") -- http://www.hammerspoon.org/docs/hs.pasteboard.html
local settings = require("hs.settings") -- http://www.hammerspoon.org/docs/hs.settings.html
local last_change = pasteboard.changeCount() -- displays how many times the pasteboard owner has changed // Indicates a new copy has been made

-- initialise as local so it's no longer global
local now = pasteboard.changeCount()

-- verify pasteboard doesn't contain transient or confidential info we should skip
local goodToRecord = function()
    local goAhead = true
    for i,v in ipairs(pasteboard.pasteboardTypes()) do
        if ignoreTheseIdentifiers[v] then
            goAhead = false
            break
        end
    end
    if goAhead then
        for i,v in ipairs(pasteboard.contentTypes()) do
            if ignoreTheseIdentifiers[v] then
                goAhead = false
                break
            end
        end
    end
    return goAhead
end


--Array to store the clipboard history
local clipboard_history = settings.get("so.victor.hs.jumpcut") or {} --If no history is saved on the system, create an empty history

-- Append a history counter to the menu
local function setTitle()
  if (#clipboard_history == 0) then
    jumpcut:setTitle(menuTitle) -- Unicode magic
    else
      jumpcut:setTitle(menuTitle.." ("..#clipboard_history..")") -- updates the menu counter
  end
end

local function putOnPaste(string,key)
  if (pasteOnSelect) then
    hs.eventtap.keyStrokes(string)
    pasteboard.setContents(string)
    last_change = pasteboard.changeCount()
  else
    if (key.alt == true) then -- If the option/alt key is active when clicking on the menu, perform a "direct paste", without changing the clipboard
      hs.eventtap.keyStrokes(string) -- Defeating paste blocking http://www.hammerspoon.org/go/#pasteblock
    else
      pasteboard.setContents(string)
      last_change = pasteboard.changeCount() -- Updates last_change to prevent item duplication when putting on paste
    end
  end
end

-- Clears the clipboard and history
local function clearAll()
  pasteboard.clearContents()
  clipboard_history = {}
  settings.set("so.victor.hs.jumpcut",clipboard_history)
  now = pasteboard.changeCount()
  setTitle()
end

-- Clears the last added to the history
local function clearLastItem()
  table.remove(clipboard_history,#clipboard_history)
  settings.set("so.victor.hs.jumpcut",clipboard_history)
  now = pasteboard.changeCount()
  setTitle()
end

local function pasteboardToClipboard(item)
  -- Loop to enforce limit on qty of elements in history. Removes the oldest items
  while (#clipboard_history >= hist_size) do
    table.remove(clipboard_history,1)
  end
  table.insert(clipboard_history, item)
  settings.set("so.victor.hs.jumpcut",clipboard_history) -- updates the saved history
  setTitle() -- updates the menu counter
end

-- Dynamic menu by cmsj https://github.com/Hammerspoon/hammerspoon/issues/61#issuecomment-64826257
local populateMenu = function(key)
  setTitle() -- Update the counter every time the menu is refreshed
  menuData = {}
  if (#clipboard_history == 0) then
    table.insert(menuData, {title="None", disabled = true}) -- If the history is empty, display "None"
  else
    for k,v in pairs(clipboard_history) do
      if (string.len(v) > label_length) then
        table.insert(menuData,1, {title=string.sub(v,0,label_length).."…", fn = function() putOnPaste(v,key) end }) -- Truncate long strings
      else
        table.insert(menuData,1, {title=v, fn = function() putOnPaste(v,key) end })
      end -- end if else
    end-- end for
  end-- end if else
  -- footer
  table.insert(menuData, {title="-"})
  table.insert(menuData, {title="Clear All", fn = function() clearAll() end })
  if (key.alt == true or pasteOnSelect) then
    table.insert(menuData, {title="Direct Paste Mode ✍", disabled=true})
  end
  return menuData
end

-- If the pasteboard owner has changed, we add the current item to our history and update the counter.
local function storeCopy()
  now = pasteboard.changeCount()
  if (now > last_change) then
    if goodToRecord() then
        local current_clipboard = pasteboard.getContents() or ""

        if #current_clipboard < maxSize then
            -- asmagill requested this feature. It prevents the history from keeping items removed by password managers
            if (current_clipboard == "" and honor_clearcontent) then
              clearLastItem()
            else
              pasteboardToClipboard(current_clipboard)
            end
        else
            print("++ skipping clipboard history update due to size")
        end
    else
        print("++ skipping clipboard history update by request") -- debug; will remove later
    end
    last_change = now
  end
end

--Checks for changes on the pasteboard. Is it possible to replace with eventtap?
local timer = hs.timer.new(frequency, storeCopy)
timer:start()

setTitle() --Avoid wrong title if the user already has something on his saved history
jumpcut:setMenu(populateMenu)

return jumpcut