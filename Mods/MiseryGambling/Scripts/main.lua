-- misery gambling mod
-- by @cultcompiler

local TAG = "[MiseryGambling] "
local DEBUG = false

local CURRENCY_ROW   = "Resource_Rubles"
local ITEM_LIST_PATH = "/Script/Engine.CompositeDataTable'/Game/SurvivalGameKitV2/Blueprints/Items/MasterLists/MasterItemList.MasterItemList'"

local BJ_BET = 25

local STOCK_BJ_START = 1900100000
local STOCK_BJ_HIT   = 1900200000
local STOCK_BJ_STAND = 1900300000

local NPC_CLASS_PATH  = "/Game/SurvivalGameKitV2/Blueprints/BuildParts/Traders/BP_Barman.BP_Barman_C"
local NPC_CLASS_SHORT = "BP_Barman_C"

local NPC_DISPLAY_NAME = "Gambler"
local NPC_PROMPT_TEXT  = "Gamble"

local NPC_SPAWN_Z_OFFSET = 0

local function log(s) print(TAG .. s .. "\n") end
local function dbg(s) if DEBUG then log(s) end end

math.randomseed(os.time())
math.random(); math.random(); math.random()

local hooks_registered = false
local setup_done       = false
local client_reopening = false
local BJ_START_SLOT    = nil
local BJ_HIT_SLOT      = nil
local BJ_STAND_SLOT    = nil

local BJ = {
    active       = false,
    player_cards = {},
    dealer_cards = {},
    last_result  = nil,
}

local gambling_barman       = nil
local gambling_barman_actor = nil
local injected_into_real    = false
local last_known_balance    = nil

local function reset_state()
    BJ.active        = false
    BJ.player_cards  = {}
    BJ.dealer_cards  = {}
    BJ.last_result   = nil
    BJ_START_SLOT    = nil
    BJ_HIT_SLOT      = nil
    BJ_STAND_SLOT    = nil
    if gambling_barman_actor then
        pcall(function() gambling_barman_actor:K2_DestroyActor() end)
    end
    setup_done            = false
    client_reopening      = false
    gambling_barman       = nil
    gambling_barman_actor = nil
    injected_into_real    = false
end

local function is_valid(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid
end

local function safe_get(o, k)
    if o == nil then return nil end
    local ok, r = pcall(function() return o[k] end)
    if ok then return r end
    return nil
end

local function safe_call0(obj, method)
    local m = safe_get(obj, method)
    if type(m) ~= "function" then return nil end
    local ok, r = pcall(function() return m(obj) end)
    if ok then return r end
    return nil
end

local function fname_to_string(fn)
    local s = safe_call0(fn, "ToString"); if type(s) == "string" then return s end
    s = safe_call0(fn, "GetPlainNameString"); if type(s) == "string" then return s end
    return tostring(fn)
end

local function safe_index(arr, i)
    if arr == nil then return nil, false end
    local ok, v = pcall(function() return arr[i] end)
    if ok then return v, true end
    return nil, false
end

local function is_host()
    local world = FindFirstOf("World")
    if not is_valid(world) then return false end
    local ok, netmode = pcall(function() return world:GetNetMode() end)
    return ok and netmode == 0
end

local BJ_RANK = { "A","2","3","4","5","6","7","8","9","10","J","Q","K" }
local BJ_SUIT = { "S","H","D","C" }

local function bj_draw()
    return { rank = math.random(1,13), suit = math.random(1,4) }
end

local function bj_card_value(c)
    if c.rank == 1 then return 11 end
    if c.rank >= 10 then return 10 end
    return c.rank
end

local function bj_hand_total(cards)
    local total, aces = 0, 0
    for _, c in ipairs(cards) do
        total = total + bj_card_value(c)
        if c.rank == 1 then aces = aces + 1 end
    end
    while total > 21 and aces > 0 do
        total = total - 10
        aces = aces - 1
    end
    return total
end

local function bj_is_soft(cards)
    local total, aces = 0, 0
    for _, c in ipairs(cards) do
        total = total + bj_card_value(c)
        if c.rank == 1 then aces = aces + 1 end
    end
    return (total <= 21) and (aces > 0)
end

local function bj_card_str(c) return BJ_RANK[c.rank] .. BJ_SUIT[c.suit] end

local function bj_hand_str(cards)
    local parts = {}
    for _, c in ipairs(cards) do table.insert(parts, bj_card_str(c)) end
    return table.concat(parts, " ")
end

local function bj_play_dealer()
    local cards = { bj_draw(), bj_draw() }
    while true do
        local total = bj_hand_total(cards)
        if total < 17 then
            table.insert(cards, bj_draw())
        elseif total == 17 and bj_is_soft(cards) then
            table.insert(cards, bj_draw())
        else
            break
        end
    end
    return cards
end

local function bj_compute_payout()
    local p = bj_hand_total(BJ.player_cards)
    local d = bj_hand_total(BJ.dealer_cards)
    if p > 21 then return 0 end
    local is_p_bj = (#BJ.player_cards == 2 and p == 21)
    local is_d_bj = (#BJ.dealer_cards == 2 and d == 21)
    if is_d_bj and not is_p_bj then return 0          end
    if is_p_bj and not is_d_bj then return math.floor(BJ_BET * 5 / 2) end
    if is_p_bj and is_d_bj     then return BJ_BET     end
    if d > 21                  then return BJ_BET * 2 end
    if p > d                   then return BJ_BET * 2 end
    if p < d                   then return 0          end
    return BJ_BET
end

local function bj_end_message(net)
    local p = bj_hand_total(BJ.player_cards)
    local d = bj_hand_total(BJ.dealer_cards)
    local sign = (net >= 0) and "+" or "-"
    return string.format("GAME END | YOU: %d | DEALER: %d | %s%d RUBLES",
        p, d, sign, math.abs(net))
end

local function bj_start()
    BJ.active       = true
    BJ.player_cards = { bj_draw(), bj_draw() }
    BJ.dealer_cards = bj_play_dealer()
    BJ.last_result  = nil
    return bj_compute_payout()
end

local function bj_hit()
    if not BJ.active then return 0 end
    table.insert(BJ.player_cards, bj_draw())
    if bj_hand_total(BJ.player_cards) > 21 then
        BJ.last_result = bj_end_message(-BJ_BET)
        BJ.active = false
        return 0
    end
    return bj_compute_payout()
end

local function bj_stand_resolve()
    if not BJ.active then return 0 end
    local payout = bj_compute_payout()
    BJ.last_result = bj_end_message(payout - BJ_BET)
    BJ.active = false
    return payout
end

local function find_any_trader_vendor()
    local vendors
    pcall(function() vendors = FindAllOf("BP_VendorComponent_C") end)
    if not vendors then return nil end
    for _, vendor in ipairs(vendors) do
        if is_valid(vendor) then return vendor end
    end
    return nil
end
local find_barman = find_any_trader_vendor

local F_BUY_ITEM  = "Item_14_070A36824EDC84B7D36215B209442FF9"
local F_BUY_PRICE = "Price_13_FBBBC2BD486FD812AFE6BA947CE8EDD7"
local F_BUY_STOCK = "Stock_17_DB81849743F8694701EA61B74F879068"
local F_COST_ITEM = "Item_2_75DA1F3645FDA366094190A853658F2B"
local F_COST_AMT  = "Amount_5_9BB6E2444CD3AA340121BA986DA11205"

local function fmt_handle(row_str, include_dt)
    if not row_str or row_str == "" or row_str == "None" then return nil end
    if include_dt then
        return string.format("(DataTable=\"%s\",RowName=\"%s\")", ITEM_LIST_PATH, row_str)
    end
    return string.format("(RowName=\"%s\")", row_str)
end

local function fmt_cost(row_str, amt, include_dt)
    local h = fmt_handle(row_str, include_dt)
    if not h then return nil end
    return string.format("(%s=%s,%s=%d)", F_COST_ITEM, h, F_COST_AMT, amt or 0)
end

local function fmt_entry(item_row, item_amt, price_specs, stock_marker)
    local item_text = fmt_cost(item_row, item_amt, false)
    if not item_text then return nil end
    local parts = {}
    for _, p in ipairs(price_specs) do
        local pt = fmt_cost(p.row, p.amt, true)
        if pt then table.insert(parts, pt) end
    end
    local price_block = "(" .. table.concat(parts, ",") .. ")"
    if stock_marker then
        return string.format("(%s=%s,%s=%s,%s=%d)",
            F_BUY_ITEM, item_text, F_BUY_PRICE, price_block,
            F_BUY_STOCK, stock_marker)
    end
    return string.format("(%s=%s,%s=%s)",
        F_BUY_ITEM, item_text, F_BUY_PRICE, price_block)
end

local function serialize_existing_entry(entry)
    if not entry then return nil end
    local item = safe_get(entry, F_BUY_ITEM)
    if not item then return nil end
    local item_handle = safe_get(item, F_COST_ITEM)
    if not item_handle then return nil end
    local item_row = fname_to_string(safe_get(item_handle, "RowName"))
    local item_amt = safe_get(item, F_COST_AMT) or 0

    local price_arr = safe_get(entry, F_BUY_PRICE)
    if not price_arr then return nil end
    local price_specs = {}
    local pn = 0
    pcall(function() pn = #price_arr end)
    for i = 1, pn do
        local p = price_arr[i]
        local p_handle = safe_get(p, F_COST_ITEM)
        if p_handle then
            local p_row = fname_to_string(safe_get(p_handle, "RowName"))
            local p_amt = safe_get(p, F_COST_AMT) or 0
            if p_row and p_row ~= "" and p_row ~= "None" then
                table.insert(price_specs, { row = p_row, amt = p_amt })
            end
        end
    end
    return fmt_entry(item_row, item_amt, price_specs)
end

local function gambling_entry_text(payout_amount, bet_amount, stock_marker)
    return fmt_entry(
        CURRENCY_ROW, payout_amount,
        { { row = CURRENCY_ROW, amt = bet_amount } },
        stock_marker
    )
end

local function build_buylist_text(barman)
    local parts = {}
    local existing = safe_get(barman, "BuyList")
    if existing then
        local n = 0
        pcall(function() n = #existing end)
        for i = 1, n do
            local text = serialize_existing_entry(existing[i])
            if text then table.insert(parts, text) end
        end
    end
    BJ_START_SLOT = #parts + 1; table.insert(parts, gambling_entry_text(0, BJ_BET, STOCK_BJ_START))
    BJ_HIT_SLOT   = #parts + 1; table.insert(parts, gambling_entry_text(0, 0,      STOCK_BJ_HIT))
    BJ_STAND_SLOT = #parts + 1; table.insert(parts, gambling_entry_text(0, 0,      STOCK_BJ_STAND))
    return "(" .. table.concat(parts, ",") .. ")"
end

local function set_buylist_from_text(barman, text)
    if not is_valid(barman) then return false end
    local ok, err = pcall(function()
        local refl = barman:Reflection()
        local prop = refl:GetProperty("BuyList")
        local data = prop:ContainerPtrToValuePtr(barman, 0)
        prop:ImportText(text, data, 0, barman)
    end)
    if not ok then log("BuyList ImportText failed: " .. tostring(err)) end
    return ok
end

local function set_slot_payout(barman, slot_index, payout)
    if not is_valid(barman) or not slot_index then return end
    local arr = safe_get(barman, "BuyList")
    if not arr then return end
    local entry, ok = safe_index(arr, slot_index)
    if not ok or not entry then return end
    local item_entry = safe_get(entry, F_BUY_ITEM)
    if not item_entry then return end
    pcall(function() item_entry[F_COST_AMT] = payout end)
end

local function set_slot_by_stock(vendor, stock_marker, payout)
    if not is_valid(vendor) then return end
    local arr = safe_get(vendor, "BuyList")
    if not arr then return end
    local n = 0
    pcall(function() n = #arr end)
    for i = 1, n do
        local entry = arr[i]
        if entry then
            local s = safe_get(entry, F_BUY_STOCK) or 0
            if s == stock_marker then
                pcall(function() entry[F_BUY_STOCK] = stock_marker end)
                local item_entry = safe_get(entry, F_BUY_ITEM)
                if item_entry then
                    pcall(function() item_entry[F_COST_AMT] = payout end)
                end
                return
            end
        end
    end
end

local build_gambling_only_text
local customize_spawned_barman

local function topup_vender_stock(vendor)
    if not is_valid(vendor) then return end
    pcall(function()
        local vs = vendor.VenderStock
        if not vs then return end
        local n = 0
        pcall(function() n = #vs end)
        for i = 1, n do
            pcall(function() vs[i] = 1000000000 end)
        end
    end)
end

local function reapply_vendor(vendor)
    if not is_valid(vendor) then return end
    local stand_p = (BJ.active and bj_compute_payout()) or 0
    set_slot_by_stock(vendor, STOCK_BJ_STAND, stand_p)
    set_slot_by_stock(vendor, STOCK_BJ_START, 0)
    set_slot_by_stock(vendor, STOCK_BJ_HIT,   0)
    pcall(function() vendor.UseStockLimits = false end)
end

local function reapply_stand_payout(_unused_barman)
    if is_valid(gambling_barman) then
        reapply_vendor(gambling_barman)
    elseif injected_into_real then
        reapply_vendor(find_barman())
    end
end

local function run_setup()
    local barman = find_barman()
    if not is_valid(barman) then return false end
    if not set_buylist_from_text(barman, build_buylist_text(barman)) then
        return false
    end
    reapply_stand_payout(barman)
    log(string.format("Setup OK -- BJ %d/%d/%d.",
        BJ_START_SLOT or -1, BJ_HIT_SLOT or -1, BJ_STAND_SLOT or -1))
    setup_done = true
    return true
end

local function bj_label_start()
    if not BJ.active then
        if BJ.last_result then return BJ.last_result end
        return "BLACKJACK"
    end
    if not BJ.player_cards or #BJ.player_cards == 0 then
        return "BLACKJACK"
    end
    local you = bj_hand_total(BJ.player_cards)
    if not BJ.dealer_cards or #BJ.dealer_cards == 0 or not BJ.dealer_cards[1] then
        return string.format("YOU: %d", you)
    end
    local dealer_up = bj_card_value(BJ.dealer_cards[1])
    return string.format("YOU: %d | DEALER: %d", you, dealer_up)
end

local function bj_label_hit()
    return "HIT"
end

local function bj_label_stand()
    return "STAND"
end

local function label_for_stock(stock)
    if stock == STOCK_BJ_START then return bj_label_start() end
    if stock == STOCK_BJ_HIT   then return bj_label_hit()   end
    if stock == STOCK_BJ_STAND then return bj_label_stand() end
    return nil
end

local function set_text_block(tb, str)
    if not is_valid(tb) then return end
    local ok = pcall(function() tb:SetText(FText(str)) end)
    if ok then return end
    pcall(function() tb.Text = FText(str) end)
end

local function rename_gambling_listings()
    local listings
    pcall(function() listings = FindAllOf("BP_VendorListing_C") end)
    if not listings then return end
    for _, listing in ipairs(listings) do
        if is_valid(listing) then
            local buy_data = safe_get(listing, "VenderBuyListing")
            if buy_data then
                local stock = safe_get(buy_data, F_BUY_STOCK) or 0
                local label
                pcall(function() label = label_for_stock(stock) end)
                if label then
                    local name_text = safe_get(listing, "CraftingRecipeNameText")
                    set_text_block(name_text, label)
                end
            end
        end
    end
end

local function schedule_rename(delay_ms)
    for _, ms in ipairs({ delay_ms or 50, 150, 300, 500, 800, 1200, 1800, 2500 }) do
        ExecuteWithDelay(ms, function() pcall(rename_gambling_listings) end)
    end
end

local F_SLOT_OCCUPIED  = "Occupied_7_0F396F8C4E8A3B8E24C3BF9D4E366AAC"
local F_INVSLOT_ITEM   = "Item_10_95D912F14C7740665FD844AF7EA87327"
local F_INVITEM_ID     = "ID_2_84C2CB8945979246059C568DCD463423"
local F_INVITEM_AMOUNT = "Amount_5_62DB2267439500D86A52E0B2266494D2"

local function get_ruble_balance(inv)
    if not is_valid(inv) then return 0 end
    local total = 0
    pcall(function()
        local slots = inv.Inventory
        if not slots then return end
        for i = 1, #slots do
            local slot = slots[i]
            if slot and slot[F_SLOT_OCCUPIED] then
                local item = slot[F_INVSLOT_ITEM]
                if item then
                    local id_str = fname_to_string(item[F_INVITEM_ID])
                    if id_str == CURRENCY_ROW then
                        local amt = item[F_INVITEM_AMOUNT]
                        if amt then total = total + amt end
                    end
                end
            end
        end
    end)
    return total
end

local function grant_rubles_to_player(inv, amount)
    if not is_valid(inv) or not amount or amount <= 0 then return false end
    local granted = false
    pcall(function()
        local slots = inv.Inventory
        if not slots then return end
        for i = 1, #slots do
            local slot = slots[i]
            if slot and slot[F_SLOT_OCCUPIED] then
                local item = slot[F_INVSLOT_ITEM]
                if item then
                    local id_str = fname_to_string(item[F_INVITEM_ID])
                    if id_str == CURRENCY_ROW then
                        local current = item[F_INVITEM_AMOUNT] or 0
                        item[F_INVITEM_AMOUNT] = current + amount
                        granted = true
                        return
                    end
                end
            end
        end
    end)
    return granted
end

local function deferred_refresh(inv, barman)
    ExecuteWithDelay(100, function()
        if not is_valid(inv) or not is_valid(barman) then return end
        pcall(function() inv:CloseInventory() end)
        pcall(function() reapply_stand_payout(barman) end)
        pcall(function() topup_vender_stock(barman) end)
        pcall(function() inv:ServerOpenVenderMenu(barman) end)
        schedule_rename(150)
    end)
end

local function classify_stock(stock)
    if not stock then return nil end
    if stock >= STOCK_BJ_START - 1000 and stock <= STOCK_BJ_START + 1000 then return STOCK_BJ_START end
    if stock >= STOCK_BJ_HIT   - 1000 and stock <= STOCK_BJ_HIT   + 1000 then return STOCK_BJ_HIT   end
    if stock >= STOCK_BJ_STAND - 1000 and stock <= STOCK_BJ_STAND + 1000 then return STOCK_BJ_STAND end
    return nil
end

local function on_server_buy(self, VenderBuyListing, Amount)
    local listing = VenderBuyListing:get()
    if not listing then return end

    local raw_stock = safe_get(listing, F_BUY_STOCK) or 0
    local stock = classify_stock(raw_stock)
    if not stock then return end

    local vendor = (is_valid(gambling_barman) and gambling_barman) or find_barman()
    if not is_valid(vendor) then return end
    local inv = self:get()
    if not is_valid(inv) then return end

    if stock == STOCK_BJ_START then
        if BJ.active then
            dbg("BJ_START ignored")
        elseif last_known_balance and last_known_balance < BJ_BET then
            BJ.last_result = string.format("NEED %d RUBLES TO PLAY (you have %d)",
                BJ_BET, last_known_balance)
        else
            bj_start()
            dbg(string.format("BJ deal: you %d [%s] dealer shows %s",
                bj_hand_total(BJ.player_cards), bj_hand_str(BJ.player_cards),
                bj_card_str(BJ.dealer_cards[1])))
        end
    elseif stock == STOCK_BJ_HIT then
        if BJ.active then
            bj_hit()
            dbg(string.format("BJ hit: you %d [%s]",
                bj_hand_total(BJ.player_cards), bj_hand_str(BJ.player_cards)))
        end
    elseif stock == STOCK_BJ_STAND then
        if BJ.active then
            bj_stand_resolve()
            dbg("BJ stand: " .. tostring(BJ.last_result))
        end
    end

    deferred_refresh(inv, vendor)
end

local function on_client_open(self, VenderComponent)
    local vc = VenderComponent:get()
    if not is_valid(vc) then return end
    local name = safe_call0(vc, "GetFullName")
    if not name or not name:find(NPC_CLASS_SHORT) then return end

    if is_valid(gambling_barman) then
        local gb_name = safe_call0(gambling_barman, "GetFullName")
        if gb_name == name then
            pcall(function()
                local inv = self:get()
                if is_valid(inv) then
                    last_known_balance = get_ruble_balance(inv)
                end
            end)
            ExecuteWithDelay(80, function()
                if is_valid(gambling_barman) then
                    pcall(function() gambling_barman.UseStockLimits = false end)
                    reapply_vendor(gambling_barman)
                end
            end)
            schedule_rename(100)
            return
        end
    end

    if not injected_into_real then return end
    local barman = find_barman()
    if not is_valid(barman) then return end
    if is_host() then
        reapply_stand_payout(barman)
        schedule_rename(200)
        return
    end
    if client_reopening then return end
    reapply_stand_payout(barman)
    local inv = self:get()
    if not is_valid(inv) then return end
    pcall(function() inv:CloseInventory() end)
    client_reopening = true
    ExecuteWithDelay(150, function()
        pcall(function() inv:ServerOpenVenderMenu(barman) end)
        ExecuteWithDelay(150, function() client_reopening = false end)
        schedule_rename(250)
    end)
end

local function context_menu_targets_gambling_npc()
    if not is_valid(gambling_barman_actor) then return false end
    local menus
    pcall(function() menus = FindAllOf("BP_InteractionContextMenu_C") end)
    if not menus then return false end
    for _, m in ipairs(menus) do
        local target = safe_get(m, "LastLookAtActor")
        if is_valid(target) and target == gambling_barman_actor then
            return true
        end
    end
    return false
end

local hook_fired_count = 0
local hook_log_throttle = 0
local function on_entry_update_text(self)
    local entry = self:get()
    if not is_valid(entry) then return end
    local vm
    pcall(function() vm = FindFirstOf("BP_VendorMenu_C") end)
    if vm then return end
    if not context_menu_targets_gambling_npc() then return end
    hook_fired_count = hook_fired_count + 1
    if (hook_fired_count - hook_log_throttle) >= 60 then
        log(string.format("hook fired %d times (showing every 60th)", hook_fired_count))
        hook_log_throttle = hook_fired_count
    end
    for _, fld in ipairs({ "TextBlock", "TextBlock_86" }) do
        local tb = safe_get(entry, fld)
        if is_valid(tb) then
            local s = get_text_block_str(tb)
            if matches_any(s, NAME_NEEDLES) then
                set_text_block(tb, NPC_DISPLAY_NAME)
            elseif matches_any(s, PROMPT_NEEDLES) then
                set_text_block(tb, NPC_PROMPT_TEXT)
            end
        end
    end
end

local function on_stock_limit_check(self, BuyListing, RemoveStock, Amount, ReturnValue)
    local listing = BuyListing:get()
    if not listing then return end
    local raw_stock = safe_get(listing, F_BUY_STOCK) or 0
    if classify_stock(raw_stock) == nil then return end
    pcall(function() ReturnValue:set(true) end)
end

local function register_hooks()
    if hooks_registered then return end
    RegisterHook(
        "/Game/SurvivalGameKitV2/Components/BP_PlayerInventory.BP_PlayerInventory_C:ServerBuyVenderItem",
        on_server_buy
    )
    RegisterHook(
        "/Game/SurvivalGameKitV2/Components/BP_PlayerInventory.BP_PlayerInventory_C:ClientOpenVenderMenu",
        on_client_open
    )
    pcall(function()
        RegisterHook(
            "/Game/SurvivalGameKitV2/Blueprints/Widgets/BP_InteractContextMenuEntry.BP_InteractContextMenuEntry_C:UpdateText",
            on_entry_update_text
        )
    end)
    pcall(function()
        RegisterHook(
            "/Game/SurvivalGameKitV2/Blueprints/Widgets/BP_InteractContextMenuEntry.BP_InteractContextMenuEntry_C:InitializeEntry",
            on_entry_update_text
        )
    end)
    hooks_registered = true
end

local function get_player_pawn()
    local pc = FindFirstOf("PlayerController")
    if not is_valid(pc) then return nil end
    local pawn
    pcall(function() pawn = pc.AcknowledgedPawn end)
    if not is_valid(pawn) then pcall(function() pawn = pc.Pawn end) end
    if not is_valid(pawn) then
        pcall(function() pawn = FindFirstOf("BP_SGKMasterCharacter_C") end)
    end
    return pawn
end

local function get_player_location()
    local pawn = get_player_pawn()
    if not is_valid(pawn) then return nil end
    local loc
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if not loc then return nil end
    return { X = loc.X, Y = loc.Y, Z = loc.Z }
end

local PLAYER_CAPSULE_HALF_HEIGHT = 90

local function destroy_gambling_barman()
    if is_valid(gambling_barman_actor) then
        pcall(function() gambling_barman_actor:K2_DestroyActor() end)
        pcall(function() gambling_barman_actor:SetActorHiddenInGame(true) end)
        pcall(function() gambling_barman_actor.bHidden = true end)
        log("Destroyed spawned gambling barman.")
    end
    gambling_barman       = nil
    gambling_barman_actor = nil
end

build_gambling_only_text = function()
    local parts = {
        gambling_entry_text(0,           BJ_BET, STOCK_BJ_START),
        gambling_entry_text(0,           0,      STOCK_BJ_HIT),
        gambling_entry_text(0,           0,      STOCK_BJ_STAND),
    }
    return "(" .. table.concat(parts, ",") .. ")"
end

local function find_real_barman_actor()
    local all
    pcall(function() all = FindAllOf("BP_Barman_C") end)
    if not all then return nil end
    for _, a in ipairs(all) do
        if is_valid(a) and a ~= gambling_barman_actor then
            local name = safe_call0(a, "GetFullName") or ""
            if not name:find("Default__") then
                local loc
                pcall(function() loc = a:K2_GetActorLocation() end)
                if loc and (loc.X ~= 0 or loc.Y ~= 0 or loc.Z ~= 0) then
                    return a
                end
            end
        end
    end
    return nil
end

local function spawn_gambling_barman(force)
    if not force and is_valid(gambling_barman_actor) then
        return true
    end
    destroy_gambling_barman()
    local class
    pcall(function() class = StaticFindObject(NPC_CLASS_PATH) end)
    if not class then
        log("spawn_gambling_barman: " .. NPC_CLASS_SHORT .. " class not found.")
        return false
    end
    local pc = FindFirstOf("PlayerController")
    if not is_valid(pc) then return false end
    local world
    pcall(function() world = pc:GetWorld() end)
    if not is_valid(world) then return false end

    local anchor = find_real_barman_actor()
    if not is_valid(anchor) then
        dbg("no real Barman yet")
        return false
    end
    local anchor_loc, anchor_rot
    pcall(function() anchor_loc = anchor:K2_GetActorLocation() end)
    pcall(function() anchor_rot = anchor:K2_GetActorRotation() end)
    if not anchor_loc then return false end

    local spawn_loc = {
        X = anchor_loc.X,
        Y = anchor_loc.Y + 250,
        Z = anchor_loc.Z + NPC_SPAWN_Z_OFFSET,
    }
    local yaw = (anchor_rot and anchor_rot.Yaw) or 0
    local rotation = { Pitch = 0, Yaw = yaw, Roll = 0 }

    local actor
    pcall(function()
        actor = world:SpawnActor(class, spawn_loc, rotation)
    end)
    if not is_valid(actor) then
        dbg("spawn_gambling_barman: SpawnActor failed.")
        return false
    end
    gambling_barman_actor = actor

    pcall(function() actor:SetActorHiddenInGame(false) end)
    pcall(function() actor.bHidden = false end)

    local names = { "BP_VenderComponent", "BP_VendorComponent",
                    "VenderComponent",    "VendorComponent" }
    for _, name in ipairs(names) do
        local c = safe_get(actor, name)
        if is_valid(c) then gambling_barman = c; break end
    end
    if not is_valid(gambling_barman) then
        log("spawn_gambling_barman: no vendor component on spawned barman.")
        destroy_gambling_barman()
        return false
    end

    if not set_buylist_from_text(gambling_barman, build_gambling_only_text()) then
        log("spawn_gambling_barman: initial BuyList ImportText failed.")
        destroy_gambling_barman()
        return false
    end
    pcall(function() gambling_barman.UseStockLimits = false end)
    pcall(function()
        local refl = gambling_barman:Reflection()
        local prop = refl:GetProperty("SellList")
        local data = prop:ContainerPtrToValuePtr(gambling_barman, 0)
        prop:ImportText("()", data, 0, gambling_barman)
    end)
    customize_spawned_barman(actor, gambling_barman)
    log(string.format("Gambling barman spawned at (%.1f, %.1f, %.1f).",
        spawn_loc.X, spawn_loc.Y, spawn_loc.Z))
    return true
end

local function walk_text_blocks(widget, fn)
    if not is_valid(widget) then return end
    pcall(function()
        local wt = widget.WidgetTree
        if not wt then return end
        local all
        pcall(function() all = wt:GetAllWidgets() end)
        if not all then
            pcall(function() wt:ForEachWidget(function(w) fn(w) end) end)
            return
        end
        local n = 0
        pcall(function() n = #all end)
        for i = 1, n do
            local w = all[i]
            if w then fn(w) end
        end
    end)
end

local function is_text_block(w)
    if not is_valid(w) then return false end
    local cls_name = ""
    pcall(function() cls_name = w:GetClass():GetFName():ToString() end)
    return cls_name == "TextBlock" or cls_name == "RichTextBlock"
end

local function get_text_block_str(w)
    local s = ""
    pcall(function()
        local t = w:GetText()
        if t and t.ToString then s = t:ToString() else s = tostring(t) end
    end)
    return s
end

local NAME_NEEDLES   = { "BARMAN", "DEALER", "TRADER", "MEDIC", "HUNTER", "VASYA", "TECHNICIAN" }
local PROMPT_NEEDLES = { "TRADE" }

local function matches_any(haystack, needles)
    if not haystack or haystack == "" then return false end
    local up = haystack:upper()
    for _, n in ipairs(needles) do
        if up:find(n, 1, true) then return true end
    end
    return false
end

local function rename_prompt_via_entries()
    if not is_valid(gambling_barman_actor) then return end
    local vm
    pcall(function() vm = FindFirstOf("BP_VendorMenu_C") end)
    if vm then return end
    if not context_menu_targets_gambling_npc() then return end
    local entries
    pcall(function() entries = FindAllOf("BP_InteractContextMenuEntry_C") end)
    if not entries then return end
    for _, entry in ipairs(entries) do
        if is_valid(entry) then
            for _, fld in ipairs({ "TextBlock", "TextBlock_86" }) do
                local tb = safe_get(entry, fld)
                if is_valid(tb) then
                    local s = get_text_block_str(tb)
                    if matches_any(s, NAME_NEEDLES) then
                        set_text_block(tb, NPC_DISPLAY_NAME)
                    elseif matches_any(s, PROMPT_NEEDLES) then
                        set_text_block(tb, NPC_PROMPT_TEXT)
                    end
                end
            end
        end
    end
end

customize_spawned_barman = function(actor, vendor)
end

local function cleanup_leaked_barmen()
    local vendors
    pcall(function() vendors = FindAllOf("BP_VendorComponent_C") end)
    if not vendors then return 0 end
    local destroyed = 0
    for _, v in ipairs(vendors) do
        if v then
            local arr = safe_get(v, "BuyList")
            if arr then
                local n = 0
                pcall(function() n = #arr end)
                for i = 1, n do
                    local entry = arr[i]
                    if entry then
                        local s = safe_get(entry, F_BUY_STOCK) or 0
                        local is_marker =
                            (s == STOCK_BJ_START
                          or s == STOCK_BJ_HIT or s == STOCK_BJ_STAND)
                          or (s >= 999000000 and s <= 999300000)
                          or (s >= 1900000000 and s <= 1900300000)
                        if is_marker then
                            local owner = safe_call0(v, "GetOwner")
                            if owner then
                                pcall(function() owner:K2_DestroyActor() end)
                                destroyed = destroyed + 1
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    if destroyed > 0 then
        log(string.format("Cleaned up %d leaked gambling barman(s).", destroyed))
    end
    return destroyed
end

local rename_loop_started = false

local function start_rename_loop()
    if rename_loop_started then return end
    rename_loop_started = true
    LoopAsync(150, function()
        local menu
        pcall(function() menu = FindFirstOf("BP_VendorMenu_C") end)
        if menu then pcall(rename_gambling_listings) end
        if is_valid(gambling_barman) then
            pcall(function() gambling_barman.UseStockLimits = false end)
        end
        return false
    end)
    LoopAsync(50, function()
        pcall(rename_prompt_via_entries)
        return false
    end)
end

local function try_init()
    local inv = FindFirstOf("BP_PlayerInventory_C")
    if not is_valid(inv) then
        ExecuteWithDelay(2000, try_init)
        return
    end
    if not is_valid(find_real_barman_actor()) then
        ExecuteWithDelay(2000, try_init)
        return
    end
    register_hooks()
    pcall(cleanup_leaked_barmen)

    if not is_valid(gambling_barman_actor) then
        ExecuteWithDelay(2000, function()
            pcall(function() spawn_gambling_barman(false) end)
        end)
    end

    start_rename_loop()
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    reset_state()
    ExecuteWithDelay(3000, try_init)
end)

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientTravel", function()
        log("ClientTravel -- preemptive destroy of gambling barman.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientTravelInternal", function()
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientReturnToMainMenu", function()
        log("ClientReturnToMainMenu -- preemptive destroy of gambling barman.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientReturnToMainMenuWithTextReason", function()
        log("ClientReturnToMainMenuWithTextReason -- preemptive destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.GameModeBase:ReturnToMainMenuHost", function()
        log("ReturnToMainMenuHost -- preemptive destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:LocalTravel", function()
        log("LocalTravel -- preemptive destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.GameInstance:ReceiveShutdown", function()
        log("GameInstance:ReceiveShutdown -- preemptive destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.GameInstance:HandleTravelError", function()
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ReceiveEndPlay", function()
        log("PlayerController:ReceiveEndPlay -- preemptive destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.Pawn:ReceiveEndPlay", function()
        destroy_gambling_barman()
    end)
end)

pcall(function()
    RegisterHook("/Game/SurvivalGameKitV2/Blueprints/Widgets/BP_InGameMenu.BP_InGameMenu_C:Construct", function()
        log("BP_InGameMenu Construct -- destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Game/SurvivalGameKitV2/Blueprints/Characters/BP_SGKController.BP_SGKController_C:ToggleInGameMenu", function()
        log("ToggleInGameMenu -- destroy.")
        destroy_gambling_barman()
    end)
end)
pcall(function()
    RegisterHook("/Game/SurvivalGameKitV2/Blueprints/Characters/BP_SGKController.BP_SGKController_C:InpActEvt_Escape_K2Node_InputKeyEvent_0", function()
        log("ESC pressed -- destroy.")
        destroy_gambling_barman()
    end)
end)

local function hide_main_menu_buttons()
    local list
    pcall(function() list = FindAllOf("TextBlock") end)
    if not list then return end
    for _, tb in ipairs(list) do
        if is_valid(tb) then
            local s = ""
            pcall(function()
                local t = tb:GetText()
                if t and t.ToString then s = t:ToString() else s = tostring(t) end
            end)
            if s and (s:upper() == "MAIN MENU" or s:upper() == "MAIN MENU ") then
                local owner
                pcall(function() owner = tb:GetOuter() end)
                while is_valid(owner) do
                    local cls = ""
                    pcall(function() cls = owner:GetClass():GetFName():ToString() end)
                    if cls:find("Button") or cls:find("BP_MenuButton") then
                        pcall(function() owner:SetVisibility(1) end)
                        break
                    end
                    local nxt
                    pcall(function() nxt = owner:GetOuter() end)
                    if nxt == owner then break end
                    owner = nxt
                end
                pcall(function() tb:SetVisibility(1) end)
            end
        end
    end
end

LoopAsync(200, function()
    pcall(hide_main_menu_buttons)
    local paused = false
    local tearing = false
    pcall(function()
        local pc = FindFirstOf("PlayerController")
        if not is_valid(pc) then return end
        local w = pc:GetWorld()
        if not is_valid(w) then return end
        local b
        pcall(function() b = w.bIsPaused end)
        if b == true then paused = true end
        pcall(function() b = w:IsPaused() end)
        if b == true then paused = true end
        pcall(function() b = w.bIsTearingDown end)
        if b == true then tearing = true end
    end)
    if tearing and is_valid(gambling_barman_actor) then
        destroy_gambling_barman()
        return false
    end
    local menu_widget
    pcall(function() menu_widget = FindFirstOf("BP_InGameMenu_C") end)
    if is_valid(menu_widget) and not paused then
        pcall(function()
            local v = menu_widget:GetVisibility()
            if v == 0 then paused = true end
        end)
    end
    if paused and is_valid(gambling_barman_actor) then
        destroy_gambling_barman()
        return false
    end
    if not paused and not is_valid(gambling_barman_actor) and is_valid(find_real_barman_actor()) then
        pcall(function() spawn_gambling_barman(false) end)
    end
    return false
end)

ExecuteWithDelay(5000, try_init)

log("MiseryGambling loaded.")
log("Gambler auto-spawns in the bunker. Walk up to him + press E to gamble.")
