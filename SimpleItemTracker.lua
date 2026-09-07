--[[
    SimpleItemTracker
    Vanilla World of Warcraft 1.12.1 (Build 5875) / Interface 11200

    A small movable bar that shows bag icons for items you are farming,
    with the total amount currently in your bags drawn on each icon.

    This file is written for the 1.12.1 client only:
      - Lua 5.0 (no '#' operator, no '%', no select(), no string.match)
      - Event payloads arrive as the globals `event`, `arg1` .. `arg9`
      - Widget scripts use the global `this` (the frame that fired the script)
      - No Ace3, no C_* namespaces, no GetCursorInfo, no C_Timer, no SetSize

    SavedVariablesPerCharacter: SimpleItemTrackerDB
]]

--------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------

local ADDON_NAME     = "SimpleItemTracker"
local MAX_TRACKED    = 12          -- hard cap so the bar cannot grow forever
local ICON_SIZE      = 36          -- pixel size of each item button
local ICON_PAD       = 4           -- gap between buttons
local BAR_PAD        = 8           -- inner padding of the tracker bar
local GRIP_WIDTH     = 14          -- left-side drag handle
local BAG_FIRST      = 0           -- backpack
local BAG_LAST       = 4           -- the four equipped bag slots
local MIN_SCALE      = 50
local MAX_SCALE      = 150
local SCALE_STEP     = 10
local DEFAULT_SCALE  = 100
local DEFAULT_ANGLE  = 220         -- minimap button angle in degrees

-- Question-mark icon used when GetItemInfo has not cached the item yet.
local QUESTION_ICON  = "Interface\\Icons\\INV_Misc_QuestionMark"
local EMPTY_SLOT_TEX = "Interface\\Buttons\\UI-Quickslot2"

--------------------------------------------------------------------------
-- Addon state (session only — not saved)
--------------------------------------------------------------------------

local SIT = {
    loaded      = false,
    editMode    = false,   -- red X + empty drop slot
    shown       = true,   -- tracker bar visibility this session
    updating    = false,   -- guard against slider feedback loops
    bagDirty    = false,   -- BAG_UPDATE coalescing flag
    bagElapsed  = 0,       -- seconds since last bag scan
    buttons     = {},      -- reused item buttons, index 1..MAX_TRACKED
    addButton   = nil,     -- the empty "drop an item here" slot
}

--------------------------------------------------------------------------
-- Saved variables helpers
--
-- SimpleItemTrackerDB is declared in the TOC and created by the client.
-- We only fill in missing fields so old saved files keep working.
--------------------------------------------------------------------------

local function SIT_InitDB()
    if not SimpleItemTrackerDB then
        SimpleItemTrackerDB = {}
    end
    local db = SimpleItemTrackerDB
    if type(db.items) ~= "table" then
        db.items = {}
    end
    if type(db.scale) ~= "number" then
        db.scale = DEFAULT_SCALE
    end
    if db.scale < MIN_SCALE or db.scale > MAX_SCALE then
        db.scale = DEFAULT_SCALE
    end
    -- Snap to the nearest 10% so the slider and stored value always agree.
    db.scale = math.floor(db.scale / SCALE_STEP + 0.5) * SCALE_STEP
    if type(db.minimapAngle) ~= "number" then
        db.minimapAngle = DEFAULT_ANGLE
    end
    -- Bar position is stored as point + offsets from UIParent.
    if type(db.posPoint) ~= "string" then
        db.posPoint = "CENTER"
        db.posX = 0
        db.posY = 80
    end
    -- Older saved lists have no `locked` field. Default them to unlocked.
    -- table.getn is used here because SIT_Len is defined further below.
    local i
    for i = 1, table.getn(db.items) do
        if db.items[i].locked ~= true then
            db.items[i].locked = false
        end
    end
end

local function SIT_GetDB()
    return SimpleItemTrackerDB
end

--------------------------------------------------------------------------
-- Small Lua 5.0 helpers
--------------------------------------------------------------------------

-- table.getn is the 5.0 way to read an array length (no '#' operator).
local function SIT_Len(t)
    if not t then
        return 0
    end
    return table.getn(t)
end

-- Round a number to the nearest scale step and clamp to 50..150.
local function SIT_SnapScale(value)
    if not value then
        return DEFAULT_SCALE
    end
    local snapped = math.floor(value / SCALE_STEP + 0.5) * SCALE_STEP
    if snapped < MIN_SCALE then
        snapped = MIN_SCALE
    end
    if snapped > MAX_SCALE then
        snapped = MAX_SCALE
    end
    return snapped
end

-- Pull the numeric item id out of a vanilla item link.
-- 1.12 links look like: |Hitem:12345:0:0:0|h[Name]|h
-- string.find with a capture returns start, end, capture1, ...
local function SIT_ItemIdFromLink(link)
    if not link or type(link) ~= "string" then
        return nil
    end
    local _, _, idStr = string.find(link, "item:(%d+)")
    if not idStr then
        return nil
    end
    return tonumber(idStr)
end

--------------------------------------------------------------------------
-- Inventory
--
-- GetContainerItemInfo (1.12 signature):
--   texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag, slot)
-- GetContainerItemLink(bag, slot) returns the "|Hitem:...|h" hyperlink.
--
-- Bags scanned: 0 (backpack) through 4 (equipped bags). Bank and keyring
-- are ignored on purpose — this is an on-character farm counter.
--------------------------------------------------------------------------

local function SIT_CountItem(itemId)
    if not itemId then
        return 0
    end
    local total = 0
    local bag
    for bag = BAG_FIRST, BAG_LAST do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            local slot
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local id = SIT_ItemIdFromLink(link)
                    if id == itemId then
                        local _, count = GetContainerItemInfo(bag, slot)
                        if count and count > 0 then
                            total = total + count
                        else
                            total = total + 1
                        end
                    end
                end
            end
        end
    end
    return total
end

-- 1.12 has no GetCursorInfo. When the player has picked an item up from
-- a bag, that bag slot stays occupied and its `locked` flag is true until
-- the item is placed somewhere. We walk the bags and return the first
-- locked slot — that is the item sitting on the cursor.
local function SIT_GetCursorBagItem()
    if not CursorHasItem() then
        return nil
    end
    local bag
    for bag = BAG_FIRST, BAG_LAST do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            local slot
            for slot = 1, slots do
                local texture, count, locked = GetContainerItemInfo(bag, slot)
                -- Empty slots can return an empty-string texture which is
                -- still "true" in Lua, so we also require a real item link.
                if locked and texture and texture ~= "" then
                    local link = GetContainerItemLink(bag, slot)
                    local id = SIT_ItemIdFromLink(link)
                    if id then
                        return id, texture, link
                    end
                end
            end
        end
    end
    return nil
end

-- GetItemInfo in 1.12:
--   name, link, quality, minLevel, class, subclass, maxStack, slot, texture
-- The item must already be in the local item cache. If it is not, we keep
-- whatever texture we stored when the item was first added.
local function SIT_GetItemDisplay(entry)
    local name, texture = nil, QUESTION_ICON
    if entry.texture and entry.texture ~= "" then
        texture = entry.texture
    end
    local itemName, _, _, _, _, _, _, _, itemTexture = GetItemInfo(entry.id)
    if itemName then
        name = itemName
    end
    if itemTexture and itemTexture ~= "" then
        texture = itemTexture
        entry.texture = itemTexture
    end
    if not name then
        name = "Item "..tostring(entry.id)
    end
    return name, texture
end

--------------------------------------------------------------------------
-- Tracked-item list
--------------------------------------------------------------------------

local function SIT_IsTracked(itemId)
    local items = SIT_GetDB().items
    local i
    for i = 1, SIT_Len(items) do
        if items[i].id == itemId then
            return true, i
        end
    end
    return false, nil
end

local function SIT_AddItem(itemId, texture)
    if not itemId then
        return false, "No item on the cursor."
    end
    local already = SIT_IsTracked(itemId)
    if already then
        return false, "That item is already being tracked."
    end
    local items = SIT_GetDB().items
    if SIT_Len(items) >= MAX_TRACKED then
        return false, "You can track at most "..MAX_TRACKED.." items."
    end
    table.insert(items, { id = itemId, texture = texture, locked = false })
    return true
end

local function SIT_IsLockedAt(index)
    local items = SIT_GetDB().items
    if index and items[index] and items[index].locked == true then
        return true
    end
    return false
end

local function SIT_ToggleLockAt(index)
    local items = SIT_GetDB().items
    if not index or not items[index] then
        return false
    end
    if items[index].locked == true then
        items[index].locked = false
    else
        items[index].locked = true
    end
    return true, items[index].locked
end

-- Remove one tracked item. Locked items must be unlocked first.
local function SIT_RemoveAt(index)
    local items = SIT_GetDB().items
    if index and index >= 1 and index <= SIT_Len(items) then
        if items[index].locked == true then
            return false, "locked"
        end
        table.remove(items, index)
        return true
    end
    return false
end

-- Drop every UNLOCKED item. Locked items stay on the bar.
-- Returns: removedCount, keptCount
local function SIT_ClearAll()
    local items = SIT_GetDB().items
    local kept = {}
    local removed = 0
    local i
    for i = 1, SIT_Len(items) do
        if items[i].locked == true then
            table.insert(kept, items[i])
        else
            removed = removed + 1
        end
    end
    SIT_GetDB().items = kept
    return removed, SIT_Len(kept)
end

--------------------------------------------------------------------------
-- Forward declarations
-- (Lua 5.0 local functions are not visible above their definition)
--------------------------------------------------------------------------

local SIT_RefreshBar
local SIT_ApplyScale
local SIT_ShowTracker
local SIT_HideTracker
local SIT_ToggleTracker
local SIT_SetEditMode
local SIT_ToggleSettings
local SIT_Print

--------------------------------------------------------------------------
-- Tracker bar — the movable row of icons
--------------------------------------------------------------------------

local function SIT_SaveBarPosition()
    local bar = SIT.bar
    if not bar then
        return
    end
    local point, _, _, x, y = bar:GetPoint()
    local db = SIT_GetDB()
    db.posPoint = point or "CENTER"
    db.posX = x or 0
    db.posY = y or 80
end

local function SIT_RestoreBarPosition()
    local bar = SIT.bar
    local db = SIT_GetDB()
    bar:ClearAllPoints()
    bar:SetPoint(db.posPoint or "CENTER", UIParent, db.posPoint or "CENTER", db.posX or 0, db.posY or 80)
end

local function SIT_StartMovingBar()
    SIT.bar:StartMoving()
end

local function SIT_StopMovingBar()
    SIT.bar:StopMovingOrSizing()
    SIT_SaveBarPosition()
end

-- Tooltip for a tracked item. SetHyperlink works in 1.12 with an item string.
local function SIT_ShowItemTooltip()
    local btn = this
    if not btn.itemId then
        return
    end
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:"..btn.itemId..":0:0:0")
    if btn.itemLocked then
        GameTooltip:AddLine("Locked — kept when you press Clear All.", 1, 0.82, 0)
    end
    if SIT.editMode then
        GameTooltip:AddLine("Lock icon: protect this item from Clear All.", 0.8, 0.8, 0.8)
        if btn.itemLocked then
            GameTooltip:AddLine("Unlock it before you can press the red X.", 1, 0.2, 0.2)
        else
            GameTooltip:AddLine("Click the red X to stop tracking.", 1, 0.2, 0.2)
        end
    end
    GameTooltip:Show()
end

local function SIT_HideTooltip()
    GameTooltip:Hide()
end

-- Try to add whatever item is currently sitting on the cursor.
local function SIT_TryAddFromCursor()
    local itemId, texture, link = SIT_GetCursorBagItem()
    if not itemId then
        if CursorHasItem() then
            SIT_Print("Could not read that item. Pick it up from a bag slot and drop it here.")
        else
            SIT_Print("Pick up an item from your bags and drop it on the empty slot.")
        end
        return
    end
    local ok, err = SIT_AddItem(itemId, texture)
    if ok then
        local name = link or ("item "..itemId)
        SIT_Print("Now tracking "..name..".")
        SIT_RefreshBar()
    else
        SIT_Print(err)
    end
end

local function SIT_CreateItemButton(index)
    -- Named buttons so we can reach the FontString/Texture children that
    -- ItemButtonTemplate creates as GlobalName.."IconTexture" / "Count".
    local name = "SIT_ItemButton"..index
    local btn = CreateFrame("Button", name, SIT.bar, "ItemButtonTemplate")
    btn:SetWidth(ICON_SIZE)
    btn:SetHeight(ICON_SIZE)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Hide leftover template pieces we do not use (cooldown, stock text).
    local cooldown = getglobal(name.."Cooldown")
    if cooldown then
        cooldown:Hide()
    end
    local stock = getglobal(name.."Stock")
    if stock then
        stock:Hide()
    end

    -- Normal count text is already provided by the template. Make sure it
    -- sits in the lower-right corner and can show 0 as well as large stacks.
    local countFS = getglobal(name.."Count")
    if countFS then
        countFS:ClearAllPoints()
        countFS:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
        countFS:SetDrawLayer("OVERLAY")
        countFS:SetJustifyH("RIGHT")
    end
    btn.countFS = countFS
    btn.iconTex = getglobal(name.."IconTexture")

    -- Big red X, only visible in Edit Mode.
    local xbtn = CreateFrame("Button", name.."Remove", btn)
    xbtn:SetWidth(20)
    xbtn:SetHeight(20)
    xbtn:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 6, 6)
    xbtn:SetFrameLevel(btn:GetFrameLevel() + 4)
    xbtn:RegisterForClicks("LeftButtonUp")

    local xfs = xbtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    xfs:SetPoint("CENTER", xbtn, "CENTER", 0, 0)
    xfs:SetText("X")
    xfs:SetTextColor(1, 0.1, 0.1)
    xbtn.text = xfs

    -- A dark circle behind the X so it stays readable on bright icons.
    local xbg = xbtn:CreateTexture(nil, "ARTWORK")
    xbg:SetTexture("Interface\\Buttons\\WHITE8X8")
    xbg:SetVertexColor(0, 0, 0, 0.65)
    xbg:SetWidth(14)
    xbg:SetHeight(14)
    xbg:SetPoint("CENTER", xbtn, "CENTER", 0, 0)

    xbtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        if parent and parent.itemIndex then
            local ok, reason = SIT_RemoveAt(parent.itemIndex)
            if not ok and reason == "locked" then
                SIT_Print("That item is locked. Unlock it first.")
            end
            SIT_RefreshBar()
        end
    end)
    xbtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove from tracker", 1, 0.2, 0.2)
        GameTooltip:Show()
    end)
    xbtn:SetScript("OnLeave", SIT_HideTooltip)
    xbtn:Hide()
    btn.removeBtn = xbtn

    -- Lock toggle (edit mode) sits on the top-left corner.
    -- A smaller padlock badge stays visible even outside edit mode so you
    -- can see which icons survive "Clear All Tracked Items".
    local lockBtn = CreateFrame("Button", name.."Lock", btn)
    lockBtn:SetWidth(18)
    lockBtn:SetHeight(18)
    lockBtn:SetPoint("TOPLEFT", btn, "TOPLEFT", -6, 6)
    lockBtn:SetFrameLevel(btn:GetFrameLevel() + 4)
    lockBtn:RegisterForClicks("LeftButtonUp")

    local lockBg = lockBtn:CreateTexture(nil, "ARTWORK")
    lockBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    lockBg:SetVertexColor(0, 0, 0, 0.75)
    lockBg:SetWidth(14)
    lockBg:SetHeight(14)
    lockBg:SetPoint("CENTER", lockBtn, "CENTER", 0, 0)
    lockBtn.bg = lockBg

    local lockFs = lockBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockFs:SetPoint("CENTER", lockBtn, "CENTER", 0, 0)
    lockFs:SetText("L")
    lockBtn.text = lockFs

    lockBtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        if parent and parent.itemIndex then
            local ok, nowLocked = SIT_ToggleLockAt(parent.itemIndex)
            if ok then
                if nowLocked then
                    SIT_Print("Locked. Clear All will keep this item.")
                else
                    SIT_Print("Unlocked. Clear All can remove this item.")
                end
                SIT_RefreshBar()
            end
        end
    end)
    lockBtn:SetScript("OnEnter", function()
        local parent = this:GetParent()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if parent and parent.itemLocked then
            GameTooltip:SetText("Unlock item", 1, 0.82, 0)
            GameTooltip:AddLine("Clear All and the red X can remove it again.", 0.8, 0.8, 0.8, 1)
        else
            GameTooltip:SetText("Lock item", 1, 0.82, 0)
            GameTooltip:AddLine("Locked items are not removed by Clear All.", 0.8, 0.8, 0.8, 1)
        end
        GameTooltip:Show()
    end)
    lockBtn:SetScript("OnLeave", SIT_HideTooltip)
    lockBtn:Hide()
    btn.lockBtn = lockBtn

    -- Always-on badge (non-clickable) used when the bar is not in Edit Mode.
    local badge = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badge:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    badge:SetText("L")
    badge:SetTextColor(1, 0.82, 0)
    badge:Hide()
    btn.lockBadge = badge

    btn:SetScript("OnEnter", SIT_ShowItemTooltip)
    btn:SetScript("OnLeave", SIT_HideTooltip)
    btn:SetScript("OnDragStart", function()
        -- In normal mode the whole bar is draggable from the icons too.
        if not SIT.editMode then
            SIT_StartMovingBar()
        end
    end)
    btn:SetScript("OnDragStop", SIT_StopMovingBar)

    -- Dropping an item onto an existing icon also adds it (same as the
    -- empty slot) so the player does not have to aim at the tiny plus slot.
    btn:SetScript("OnReceiveDrag", function()
        if SIT.editMode then
            SIT_TryAddFromCursor()
        end
    end)

    btn:Hide()
    SIT.buttons[index] = btn
    return btn
end

local function SIT_CreateAddButton()
    local btn = CreateFrame("Button", "SIT_AddButton", SIT.bar)
    btn:SetWidth(ICON_SIZE)
    btn:SetHeight(ICON_SIZE)
    btn:RegisterForClicks("LeftButtonUp")

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(btn)
    tex:SetTexture(EMPTY_SLOT_TEX)
    btn.iconTex = tex

    -- A "+" in the middle so the empty slot reads as "add".
    local plus = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    plus:SetPoint("CENTER", btn, "CENTER", 0, 1)
    plus:SetText("+")
    plus:SetTextColor(1, 0.82, 0)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add item", 1, 1, 1)
        GameTooltip:AddLine("Drag an item from your bags onto this slot.", 0.8, 0.8, 0.8, 1)
        GameTooltip:AddLine("You can also pick the item up and then click here.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", SIT_HideTooltip)
    btn:SetScript("OnClick", function()
        SIT_TryAddFromCursor()
    end)
    btn:SetScript("OnReceiveDrag", function()
        SIT_TryAddFromCursor()
    end)
    btn:Hide()
    SIT.addButton = btn
    return btn
end

local function SIT_CreateBar()
    local bar = CreateFrame("Frame", "SIT_TrackerBar", UIParent)
    bar:SetFrameStrata("HIGH")
    bar:SetWidth(80)
    bar:SetHeight(ICON_SIZE + BAR_PAD * 2)
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bar:SetBackdropColor(0, 0, 0, 0.70)
    bar:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    bar:SetScript("OnDragStart", SIT_StartMovingBar)
    bar:SetScript("OnDragStop",  SIT_StopMovingBar)

    -- A slim grip on the left so there is always somewhere obvious to grab.
    local grip = bar:CreateTexture(nil, "ARTWORK")
    grip:SetWidth(4)
    grip:SetHeight(ICON_SIZE - 4)
    grip:SetPoint("LEFT", bar, "LEFT", 5, 0)
    grip:SetTexture("Interface\\Buttons\\WHITE8X8")
    grip:SetVertexColor(0.7, 0.7, 0.7, 0.45)
    bar.grip = grip

    SIT.bar = bar

    local i
    for i = 1, MAX_TRACKED do
        SIT_CreateItemButton(i)
    end
    SIT_CreateAddButton()

    -- Hidden by default every login / reload, per the requested behaviour.
    -- bar:Hide()
end

-- Rebuild the visible buttons from the saved item list.
SIT_RefreshBar = function()
    if not SIT.bar then
        return
    end

    local items = SIT_GetDB().items
    local count = SIT_Len(items)
    local visible = count
    if SIT.editMode then
        visible = count + 1
    end
    if visible < 1 then
        visible = 1
    end

    local width = BAR_PAD * 2 + GRIP_WIDTH + visible * ICON_SIZE + (visible - 1) * ICON_PAD
    SIT.bar:SetWidth(width)
    SIT.bar:SetHeight(ICON_SIZE + BAR_PAD * 2)

    local i
    for i = 1, MAX_TRACKED do
        local btn = SIT.buttons[i]
        if i <= count then
            local entry = items[i]
            local name, texture = SIT_GetItemDisplay(entry)
            local owned = SIT_CountItem(entry.id)

            btn.itemId = entry.id
            btn.itemIndex = i
            btn.itemName = name
            btn.itemLocked = (entry.locked == true)

            if btn.iconTex then
                btn.iconTex:SetTexture(texture or QUESTION_ICON)
                if owned <= 0 then
                    btn.iconTex:SetVertexColor(0.45, 0.45, 0.45)
                else
                    btn.iconTex:SetVertexColor(1, 1, 1)
                end
            end

            if btn.countFS then
                btn.countFS:SetText(tostring(owned))
                btn.countFS:Show()
                if owned <= 0 then
                    btn.countFS:SetTextColor(1, 0.2, 0.2)
                else
                    btn.countFS:SetTextColor(1, 1, 1)
                end
            end

            if SIT.editMode then
                -- Locked items keep the lock button but hide the red X so
                -- you have to unlock them before you can delete them.
                btn.lockBtn:Show()
                if btn.itemLocked then
                    btn.lockBtn.text:SetText("L")
                    btn.lockBtn.text:SetTextColor(1, 0.82, 0)
                    btn.removeBtn:Hide()
                else
                    btn.lockBtn.text:SetText("U")
                    btn.lockBtn.text:SetTextColor(0.7, 0.7, 0.7)
                    btn.removeBtn:Show()
                end
                btn.lockBadge:Hide()
            else
                btn.removeBtn:Hide()
                btn.lockBtn:Hide()
                if btn.itemLocked then
                    btn.lockBadge:Show()
                else
                    btn.lockBadge:Hide()
                end
            end

            btn:ClearAllPoints()
            btn:SetPoint(
                "LEFT", SIT.bar, "LEFT",
                BAR_PAD + GRIP_WIDTH + (i - 1) * (ICON_SIZE + ICON_PAD),
                0
            )
            btn:Show()
        else
            btn.itemId = nil
            btn.itemIndex = nil
            btn.itemLocked = nil
            btn:Hide()
            btn.removeBtn:Hide()
            btn.lockBtn:Hide()
            btn.lockBadge:Hide()
        end
    end

    -- Empty drop slot sits after the last real item, edit mode only.
    local add = SIT.addButton
    if SIT.editMode then
        add:ClearAllPoints()
        add:SetPoint(
            "LEFT", SIT.bar, "LEFT",
            BAR_PAD + GRIP_WIDTH + count * (ICON_SIZE + ICON_PAD),
            0
        )
        add:Show()
    else
        add:Hide()
    end

    -- When the list is empty and we are not editing, keep a tiny placeholder
    -- so the player can still grab the bar and open settings.
    if count == 0 and not SIT.editMode then
        SIT.bar:SetWidth(BAR_PAD * 2 + GRIP_WIDTH + ICON_SIZE)
    end
end

SIT_ApplyScale = function(percent)
    local db = SIT_GetDB()
    db.scale = SIT_SnapScale(percent)
    if SIT.bar then
        SIT.bar:SetScale(db.scale / 100)
    end
    if SIT.scaleValueFS then
        SIT.scaleValueFS:SetText(db.scale.."%")
    end
    if SIT.scaleSlider and not SIT.updating then
        SIT.updating = true
        SIT.scaleSlider:SetValue(db.scale)
        SIT.updating = false
    end
end

SIT_ShowTracker = function()
    SIT.shown = true
    SIT.bar:Show()
    SIT_RefreshBar()
end

SIT_HideTracker = function()
    SIT.shown = false
    SIT.editMode = false
    if SIT.editCheck then
        SIT.editCheck:SetChecked(0)
    end
    SIT.bar:Hide()
end

SIT_ToggleTracker = function()
    if SIT.shown and SIT.bar:IsShown() then
        SIT_HideTracker()
    else
        SIT_ShowTracker()
    end
end

SIT_SetEditMode = function(enabled)
    if enabled then
        SIT.editMode = true
        if not SIT.shown then
            SIT_ShowTracker()
        end
    else
        SIT.editMode = false
    end
    if SIT.editCheck then
        if SIT.editMode then
            SIT.editCheck:SetChecked(1)
        else
            SIT.editCheck:SetChecked(0)
        end
    end
    SIT_RefreshBar()
end

--------------------------------------------------------------------------
-- Settings window
--------------------------------------------------------------------------

local function SIT_CreateSettings()
    local f = CreateFrame("Frame", "SIT_SettingsFrame", UIParent)
    f:SetWidth(280)
    f:SetHeight(230)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:Hide()

    -- Title banner
    local titleBg = f:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetWidth(260)
    titleBg:SetHeight(64)
    titleBg:SetPoint("TOP", f, "TOP", 0, 12)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", titleBg, "TOP", 0, -14)
    title:SetText("Simple Item Tracker")

    local close = CreateFrame("Button", "SIT_SettingsClose", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- Scale slider. OptionsSliderTemplate gives us Name.."Low", "High", "Text".
    local slider = CreateFrame("Slider", "SIT_ScaleSlider", f, "OptionsSliderTemplate")
    slider:SetWidth(200)
    slider:SetHeight(16)
    slider:SetPoint("TOP", f, "TOP", 0, -60)
    slider:SetMinMaxValues(MIN_SCALE, MAX_SCALE)
    slider:SetValueStep(SCALE_STEP)
    slider:SetValue(DEFAULT_SCALE)
    getglobal("SIT_ScaleSliderLow"):SetText(MIN_SCALE.."%")
    getglobal("SIT_ScaleSliderHigh"):SetText(MAX_SCALE.."%")
    getglobal("SIT_ScaleSliderText"):SetText("Scale")
    slider.tooltipText = "Size of the tracker bar (50% to 150%)."

    local valueFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valueFS:SetPoint("TOP", slider, "BOTTOM", 0, -2)
    valueFS:SetText(DEFAULT_SCALE.."%")
    SIT.scaleValueFS = valueFS
    SIT.scaleSlider = slider

    slider:SetScript("OnValueChanged", function()
        if SIT.updating then
            return
        end
        local v = SIT_SnapScale(this:GetValue())
        -- Snap the thumb onto the 10% grid if the widget gave us a fraction.
        if this:GetValue() ~= v then
            SIT.updating = true
            this:SetValue(v)
            SIT.updating = false
        end
        SIT_ApplyScale(v)
    end)

    -- Edit Mode checkbox
    local check = CreateFrame("CheckButton", "SIT_EditCheck", f, "UICheckButtonTemplate")
    check:SetWidth(24)
    check:SetHeight(24)
    check:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -120)
    SIT.editCheck = check

    local checkLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    checkLabel:SetPoint("LEFT", check, "RIGHT", 4, 0)
    checkLabel:SetText("Edit Mode")

    local checkHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    checkHint:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 4, 0)
    checkHint:SetJustifyH("LEFT")
    checkHint:SetText("X removes, L locks (kept on Clear All), + adds.")

    check:SetScript("OnClick", function()
        if this:GetChecked() then
            SIT_SetEditMode(true)
        else
            SIT_SetEditMode(false)
        end
    end)

    -- Clear all
    local clear = CreateFrame("Button", "SIT_ClearButton", f, "UIPanelButtonTemplate")
    clear:SetWidth(180)
    clear:SetHeight(22)
    clear:SetPoint("BOTTOM", f, "BOTTOM", 0, 22)
    clear:SetText("Clear All Tracked Items")
    clear:SetScript("OnClick", function()
        local removed, kept = SIT_ClearAll()
        SIT_RefreshBar()
        if removed == 0 and kept == 0 then
            SIT_Print("Nothing to clear.")
        elseif removed == 0 then
            SIT_Print("All tracked items are locked. Unlock them first.")
        elseif kept == 0 then
            SIT_Print("Cleared every tracked item for this character.")
        else
            SIT_Print("Removed "..removed.." unlocked item(s). Kept "..kept.." locked item(s).")
        end
    end)

    SIT.settings = f
end

SIT_ToggleSettings = function()
    if not SIT.settings then
        return
    end
    if SIT.settings:IsShown() then
        SIT.settings:Hide()
    else
        SIT.updating = true
        SIT.scaleSlider:SetValue(SIT_GetDB().scale)
        SIT.updating = false
        SIT.scaleValueFS:SetText(SIT_GetDB().scale.."%")
        if SIT.editMode then
            SIT.editCheck:SetChecked(1)
        else
            SIT.editCheck:SetChecked(0)
        end
        SIT.settings:Show()
    end
end

--------------------------------------------------------------------------
-- Minimap button
--
-- Vanilla has no LibDBIcon. The usual pattern is a 32x32 button parented
-- to Minimap, sitting on a circle of radius ~80, positioned by an angle
-- stored in saved variables. Dragging the button updates that angle.
--------------------------------------------------------------------------

local function SIT_MinimapSetPosition()
    local angle = SIT_GetDB().minimapAngle or DEFAULT_ANGLE
    local rad = angle * math.pi / 180
    -- 80 pixels is the classic radius that clears the minimap border.
    local x = math.cos(rad) * 80
    local y = math.sin(rad) * 80
    SIT.minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function SIT_MinimapOnUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not scale or scale == 0 then
        scale = 1
    end
    cx = cx / scale
    cy = cy / scale
    local dx = cx - mx
    local dy = cy - my
    -- atan2(y, x) -> radians. Convert back to degrees for storage.
    local angle = math.atan2(dy, dx) * 180 / math.pi
    SIT_GetDB().minimapAngle = angle
    SIT_MinimapSetPosition()
end

local function SIT_CreateMinimapButton()
    local btn = CreateFrame("Button", "SIT_MinimapButton", Minimap)
    btn:SetWidth(32)
    btn:SetHeight(32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = btn:CreateTexture("SIT_MinimapButtonIcon", "BACKGROUND")
    icon:SetTexture("Interface\\Addons\\SimpleItemTracker\\ItemTracker.tga")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    -- Trim the default icon's extra border so it sits inside the ring.
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    local overlay = btn:CreateTexture("SIT_MinimapButtonBorder", "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetWidth(54)
    overlay:SetHeight(54)
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    btn:SetScript("OnClick", function()
        -- In 1.12 OnClick, arg1 is the mouse button that was released.
        if arg1 == "RightButton" then
            SIT_ToggleSettings()
        else
            SIT_ToggleTracker()
        end
    end)

    btn:SetScript("OnDragStart", function()
        this:LockHighlight()
        this:SetScript("OnUpdate", SIT_MinimapOnUpdate)
    end)
    btn:SetScript("OnDragStop", function()
        this:UnlockHighlight()
        this:SetScript("OnUpdate", nil)
        SIT_MinimapSetPosition()
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Simple Item Tracker", 1, 1, 1)
        GameTooltip:AddLine("Left-click: show / hide the tracker bar", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: settings (edit + scale)", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", SIT_HideTooltip)

    SIT.minimapBtn = btn
    SIT_MinimapSetPosition()
end

--------------------------------------------------------------------------
-- Chat output and slash commands
--------------------------------------------------------------------------

SIT_Print = function(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SimpleItemTracker:|r "..tostring(msg))
    end
end

-- /sit [settings|edit|scale N]
SLASH_SIMPLEITEMTRACKER1 = "/sit"
SLASH_SIMPLEITEMTRACKER2 = "/simpleitemtracker"
SlashCmdList["SIMPLEITEMTRACKER"] = function(msg)
    msg = msg or ""
    -- Lowercase + trim. string.lower exists in 5.0; no string.match.
    msg = string.lower(msg)
    local _, _, cmd, rest = string.find(msg, "^(%S+)%s*(.*)$")
    if not cmd or cmd == "" then
        SIT_ToggleTracker()
        return
    end
    if cmd == "settings" or cmd == "config" or cmd == "opt" or cmd == "options" then
        SIT_ToggleSettings()
    elseif cmd == "edit" then
        SIT_SetEditMode(not SIT.editMode)
        if SIT.editMode then
            SIT_Print("Edit Mode on. Drop items on +, click L to lock, X to remove.")
        else
            SIT_Print("Edit Mode off.")
        end
    elseif cmd == "scale" then
        local n = tonumber(rest)
        if not n then
            SIT_Print("Usage: /sit scale 50-150   (current: "..SIT_GetDB().scale.."%)")
        else
            SIT_ApplyScale(n)
            SIT_Print("Scale set to "..SIT_GetDB().scale.."%.")
        end
    elseif cmd == "show" then
        SIT_ShowTracker()
    elseif cmd == "hide" then
        SIT_HideTracker()
    elseif cmd == "clear" then
        local removed, kept = SIT_ClearAll()
        SIT_RefreshBar()
        if removed == 0 and kept == 0 then
            SIT_Print("Nothing to clear.")
        elseif removed == 0 then
            SIT_Print("All tracked items are locked. Unlock them first.")
        elseif kept == 0 then
            SIT_Print("Cleared every tracked item for this character.")
        else
            SIT_Print("Removed "..removed.." unlocked item(s). Kept "..kept.." locked item(s).")
        end
    else
        SIT_Print("Commands: /sit  /sit settings  /sit edit  /sit scale 100  /sit clear")
    end
end

--------------------------------------------------------------------------
-- Events
--
-- 1.12 OnEvent signature: the handler takes NO arguments.
--   event  = name of the event
--   arg1.. = payload (ADDON_LOADED -> addon name, BAG_UPDATE -> bag id)
--
-- BAG_UPDATE can fire many times in a row while loot is landing. We mark
-- the bags dirty and let a short OnUpdate delay do one scan, instead of
-- walking every slot on every event.
--------------------------------------------------------------------------

local function SIT_OnEvent()
    if event == "ADDON_LOADED" then
        -- arg1 is the addon name that just loaded.
        if arg1 == ADDON_NAME then
            SIT_InitDB()
            SIT_CreateBar()
            SIT_CreateSettings()
            SIT_CreateMinimapButton()
            SIT_RestoreBarPosition()
            SIT_ApplyScale(SIT_GetDB().scale)
            SIT.loaded = true
            -- Tracker stays hidden until the player left-clicks the minimap
            -- button or types /sit. That is the requested default.
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if SIT.loaded then
            SIT_MinimapSetPosition()
            if SIT.shown then
                SIT_RefreshBar()
            end
        end
    elseif event == "BAG_UPDATE" or event == "PLAYER_LOGIN" then
        SIT.bagDirty = true
        SIT.bagElapsed = 0
    end
end

local function SIT_OnUpdate()
    -- arg1 is the elapsed seconds since the last OnUpdate in 1.12.
    if not SIT.bagDirty then
        return
    end
    SIT.bagElapsed = SIT.bagElapsed + (arg1 or 0)
    if SIT.bagElapsed < 0.15 then
        return
    end
    SIT.bagDirty = false
    SIT.bagElapsed = 0
    if SIT.shown then
        SIT_RefreshBar()
    end
end

local eventFrame = CreateFrame("Frame", "SIT_EventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:SetScript("OnEvent", SIT_OnEvent)
eventFrame:SetScript("OnUpdate", SIT_OnUpdate)
