--[[
CrossPoint Sync for KOReader
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local mime = require("mime")
local sha2 = require("ffi/sha2")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template


local TUNABLES = {
    stats_idle = { default = 300, min = 5, max = 600, step = 5 },         -- timeout without a page turn
    stats_min_page = { default = 5, min = 0, max = 60, step = 1 },       -- don't push skimmed pages
    stats_history_days = { default = 730, min = 30, max = 730, step = 30 },
    push_delay = { default = 20, min = 5, max = 300, step = 5 },         -- seconds after the last page turn
}

local STATUS_LABELS = {
    reading = _("Reading"), paused = _("Paused"),
    finished = _("Finished"), dnf = _("Did not finish"),
}

local PUSH_STATUSES = {
    { "reading", _("Reading") },
    { "abandoned", _("On hold") },
    { "complete", _("Finished") },
}

local CrossPointSync = WidgetContainer:extend{
    name = "crosspointsync",
    is_doc_only = false,
}

local function clamp01(x)
    x = tonumber(x) or 0
    if x < 0 then return 0 elseif x > 1 then return 1 end
    return x
end

local function basename(path)
    return path:match("([^/]*)$")
end

local function formatPercent(p)
    return string.format("%.1f%%", clamp01(p) * 100)
end

local function sha16(s)
    return sha2.sha256(s):sub(1, 16)
end

local function str(v)
    return type(v) == "string" and v or ""
end

local function truncateUtf8(s, max_bytes)
    if #s <= max_bytes then return s end
    local cut = max_bytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

local function truncateChars(s, max_chars)
    local n, i = 0, 1
    while i <= #s do
        n = n + 1
        if n > max_chars then return s:sub(1, i - 1) end
        local b = s:byte(i)
        i = i + (b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1)
    end
    return s
end

local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end
local DAY0 = daysFromCivil(2000, 1, 1)

local function statsDay(t)
    local d = os.date("*t", t)
    return daysFromCivil(d.year, d.month, d.day) - DAY0
end

local function statsDateSeconds(t)
    local d = os.date("*t", t)
    return daysFromCivil(d.year, d.month, d.day) * 86400
end

local function timeOfDay(hour)
    if hour >= 5 and hour < 12 then return 1 end
    if hour >= 12 and hour < 17 then return 2 end
    if hour >= 17 and hour < 22 then return 3 end
    return 4
end

local function parseDatetime(s)
    local y, mo, d, h, mi, se = tostring(s or ""):match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):?(%d*)")
    if not y then return os.time() end
    return os.time{year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                   hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) or 0}
end

local ACCENTS = {
    ["à"]="a", ["á"]="a", ["â"]="a", ["ã"]="a", ["ä"]="a", ["å"]="a", ["ā"]="a", ["ą"]="a",
    ["À"]="a", ["Á"]="a", ["Â"]="a", ["Ã"]="a", ["Ä"]="a", ["Å"]="a",
    ["ç"]="c", ["ć"]="c", ["č"]="c", ["Ç"]="c", ["Ć"]="c", ["Č"]="c",
    ["è"]="e", ["é"]="e", ["ê"]="e", ["ë"]="e", ["ē"]="e", ["ę"]="e", ["ě"]="e",
    ["È"]="e", ["É"]="e", ["Ê"]="e", ["Ë"]="e",
    ["ì"]="i", ["í"]="i", ["î"]="i", ["ï"]="i", ["ī"]="i", ["Ì"]="i", ["Í"]="i", ["Î"]="i", ["Ï"]="i",
    ["ł"]="l", ["Ł"]="l", ["ñ"]="n", ["ń"]="n", ["ň"]="n", ["Ñ"]="n",
    ["ò"]="o", ["ó"]="o", ["ô"]="o", ["õ"]="o", ["ö"]="o", ["ø"]="o", ["ō"]="o", ["ő"]="o",
    ["Ò"]="o", ["Ó"]="o", ["Ô"]="o", ["Õ"]="o", ["Ö"]="o", ["Ø"]="o",
    ["ř"]="r", ["ś"]="s", ["š"]="s", ["ş"]="s", ["Ś"]="s", ["Š"]="s", ["ť"]="t",
    ["ù"]="u", ["ú"]="u", ["û"]="u", ["ü"]="u", ["ū"]="u", ["ů"]="u", ["ű"]="u",
    ["Ù"]="u", ["Ú"]="u", ["Û"]="u", ["Ü"]="u",
    ["ý"]="y", ["ÿ"]="y", ["Ý"]="y", ["ź"]="z", ["ż"]="z", ["ž"]="z", ["Ź"]="z", ["Ż"]="z", ["Ž"]="z",
    ["ß"]="ss", ["æ"]="ae", ["œ"]="oe", ["đ"]="d", ["ð"]="d", ["þ"]="th",
}

local function normalizeText(s)
    s = tostring(s or "")
    s = s:gsub("[\195-\197][\128-\191]", function(ch) return ACCENTS[ch] end)
    s = s:gsub("\226\128[\128-\191]", " "):gsub("\226\129[\128-\175]", " "):gsub("\194[\128-\191]", " ")
    s = s:lower():gsub("[^%w\128-\255]+", " ")
    return util.trim(s)
end

local function tokenSet(s)
    local set, n = {}, 0
    for w in normalizeText(s):gmatch("%S+") do
        if #w > 1 and not set[w] then set[w] = true; n = n + 1 end
    end
    return set, n
end

local function sameAuthor(a, b)
    local ta, na = tokenSet(a)
    local tb, nb = tokenSet(b)
    if na == 0 or nb == 0 then return false end
    local small, large = ta, tb
    if na > nb then small, large = tb, ta end
    for w in pairs(small) do
        if not large[w] then return false end
    end
    return true
end

local function stripSeriesPrefix(title)
    return (title:gsub("^.-%s%d+%.?%d*%s*:%s*", ""))
end

local function cleanTitle(title)
    title = title or ""
    local rest = title:gsub("^%d+%.?%d*%s*:%s*", "", 1)
    if rest == title then rest = title:gsub("^.-%s%d+%.?%d*%s*:%s*", "", 1) end
    rest = util.trim(rest)
    return rest ~= "" and rest or title
end

local function sameTitle(remote_title, local_title)
    remote_title = str(remote_title)
    local nl = normalizeText(local_title)
    if nl == "" then return false end
    if normalizeText(remote_title) == nl or normalizeText(stripSeriesPrefix(remote_title)) == nl then
        return true
    end
    local nr = normalizeText(remote_title)
    if math.min(#nl, #nr) >= 8 then
        return (" " .. nr .. " "):find(" " .. nl .. " ", 1, true) ~= nil
            or (" " .. nl .. " "):find(" " .. nr .. " ", 1, true) ~= nil
    end
    return false
end

function CrossPointSync:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/crosspointsync.lua")
    self.stats = self.settings:readSetting("stats", { books = {}, days = {} })
    self.stats.books = self.stats.books or {}
    self.stats.days = self.stats.days or {}
    self.status_sent = self.settings:readSetting("status_sent", {}) 
    self.matches = self.settings:readSetting("matches", {})           
    if not self.settings:readSetting("device_id") then
        local t = {}
        math.randomseed(os.time() + math.floor(os.clock() * 1e6))
        for i = 1, 16 do t[i] = string.format("%02x", math.random(0, 255)) end
        self.settings:saveSetting("device_id", table.concat(t))
        self.settings:flush()
    end
    self.cur = nil           
    self.push_scheduled = false
    self.hash_cache = {}
    CrossPointSync.instance = self
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:registerFileDialogButtons()
end

function CrossPointSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("crosspoint_push", { category = "none", event = "CrossPointPush",
        title = _("CrossPoint: push progress"), reader = true })
    Dispatcher:registerAction("crosspoint_pull", { category = "none", event = "CrossPointPull",
        title = _("CrossPoint: pull progress"), reader = true })
    Dispatcher:registerAction("crosspoint_sync_all", { category = "none", event = "CrossPointSyncAll",
        title = _("CrossPoint: sync everything"), reader = true })
    Dispatcher:registerAction("crosspoint_push_all_books", { category = "none", event = "CrossPointPushAllBooks",
        title = _("CrossPoint: push all books"), general = true, filemanager = true })
    Dispatcher:registerAction("crosspoint_show_library", { category = "none", event = "CrossPointShowLibrary",
        title = _("CrossPoint: browse library"), general = true })
    Dispatcher:registerAction("crosspoint_sync_all_annotations", { category = "none", event = "CrossPointSyncAllAnnotations",
        title = _("CrossPoint: sync all highlights and bookmarks"), general = true })
end

function CrossPointSync:getSetting(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function CrossPointSync:setSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function CrossPointSync:tunable(key)
    local t = TUNABLES[key]
    local v = tonumber(self:getSetting(key, t.default)) or t.default
    return math.max(t.min, math.min(t.max, v))
end

function CrossPointSync:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

function CrossPointSync:isConfigured()
    return self:getSetting("server", "") ~= ""
        and self:getSetting("username", "") ~= ""
        and self:getSetting("password_md5", "") ~= ""
end

function CrossPointSync:withNetwork(callback)
    local was_connected = NetworkMgr:isConnected()
    NetworkMgr:runWhenOnline(function()
        local finished = false
        local function done()
            if finished then return end
            finished = true
            if not was_connected then
                UIManager:scheduleIn(1, function() NetworkMgr:afterWifiAction() end)
            end
        end
        local ok, async = pcall(callback, done)
        if not ok then
            logger.warn("CrossPointSync: network action failed:", async)
            done()
        elseif async ~= true then
            done()
        end
    end)
end

function CrossPointSync:runOnlineBlocking(callback)
    if NetworkMgr:isConnected() then
        pcall(callback)
        return
    end
    if not (Device:hasWifiToggle() and NetworkMgr.goOnlineToRun) then return end
    local prev_action = G_reader_settings:readSetting("wifi_enable_action")
    G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
    local ok, err = pcall(function()
        NetworkMgr:goOnlineToRun(function() pcall(callback) end)
    end)
    if prev_action == nil then
        G_reader_settings:delSetting("wifi_enable_action")
    else
        G_reader_settings:saveSetting("wifi_enable_action", prev_action)
    end
    if not ok then logger.warn("CrossPointSync: could not go online:", err) end
    if NetworkMgr:getBeforeActionFlag() then
        NetworkMgr:clearBeforeActionFlag()
        if G_reader_settings:readSetting("wifi_disable_action") ~= "leave_on" then
            pcall(function() NetworkMgr:disableWifi() end)
        end
    end
end

function CrossPointSync:onlineOrAsk(callback)
    if not self:isConfigured() then
        self:notify(_("Set the server, username and password first (Tools → CrossPoint Sync → Settings → Account & server)."))
        return
    end
    self:withNetwork(callback)
end

function CrossPointSync:request(method, path, body, auth)
    local server = self:getSetting("server", "")
    if server == "" then return nil, _("No server set") end
    local url = (server:gsub("/+$", "")) .. path
    local headers = {
        ["Accept"] = "application/vnd.koreader.v1+json",
    }
    if auth ~= false then
        headers["x-auth-user"] = self:getSetting("username", "")
        headers["x-auth-key"] = self:getSetting("password_md5", "")
    end
    local payload
    if body ~= nil then
        payload = type(body) == "string" and body or json.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end
    local sink = {}
    local req = { url = url, method = method, headers = headers, sink = socketutil.table_sink(sink) }
    if payload then req.source = ltn12.source.string(payload) end
    local http = url:match("^https") and require("ssl.https") or require("socket.http")
    socketutil:set_timeout(10, 30)
    local ok, code = pcall(function() return socket.skip(1, http.request(req)) end)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    if type(code) ~= "number" then return nil, tostring(code) end
    local data
    local text = table.concat(sink)
    if text ~= "" then
        local ok2, decoded = pcall(json.decode, text)
        if ok2 then data = decoded end
    end
    if code == 401 then return code, data, _("Authentication failed") end
    return code, data
end

local function httpOk(code)
    return type(code) == "number" and code >= 200 and code < 300
end

local function reqError(code, data, err)
    if err then return err end
    if not code then return tostring(data or _("no connection")) end
    return "HTTP " .. code
end

function CrossPointSync:hashesFor(file)
    local h = self.hash_cache[file]
    if not h then
        h = { filename = sha2.md5(basename(file)) }
        local ok, bin = pcall(util.partialMD5, file)
        h.binary = ok and bin or nil
        self.hash_cache[file] = h
    end
    return h
end

function CrossPointSync:idsFor(ctx)
    local h = ctx.hashes
    if self:getSetting("match", "filename") == "binary" and h.binary then
        return { primary = h.binary, alt = h.filename }
    end
    return { primary = h.filename, alt = (h.binary ~= h.filename) and h.binary or nil }
end

function CrossPointSync:readerProps()
    local props = {}
    local ok, p = pcall(function() return self.ui.document:getProps() end)
    if ok and type(p) == "table" then props = p end
    local title = props.title
    if (not title or title == "") and self.ui.doc_settings then
        local dp = self.ui.doc_settings:readSetting("doc_props")
        title = dp and dp.title
    end
    local authors = props.authors or ""
    return { title = cleanTitle(title), authors = (authors:gsub("\n", ", ")) }
end

function CrossPointSync:getLocalProgress()
    if self.ui.document.info.has_pages then
        return {
            progress = tostring(self.ui.paging:getLastProgress()),
            percentage = clamp01(self.ui.paging:getLastPercent()),
            paging = true,
        }
    end
    return {
        progress = self.ui.rolling:getLastProgress(),
        percentage = clamp01(self.ui.rolling:getLastPercent()),
    }
end

function CrossPointSync:readerContext()
    local ui = self.ui
    if not (ui and ui.document) then return nil end
    local file = ui.document.file
    local ctx = {
        file = file, filename = basename(file), open = true,
        hashes = self:hashesFor(file),
        rolling = not ui.document.info.has_pages,
        props = self:readerProps(),
        progress = self:getLocalProgress(),
        annotations = ui.annotation and ui.annotation.annotations,
    }
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
    ctx.status = summary and summary.status
    return ctx
end

function CrossPointSync:fileContext(file)
    local DocSettings = require("docsettings")
    local ctx = {
        file = file, filename = basename(file), open = false,
        hashes = self:hashesFor(file),
        props = { title = "", authors = "" },
        rolling = false,
    }
    local title, authors
    if DocSettings:hasSidecarFile(file) then
        local ds = DocSettings:open(file)
        local summary = ds:readSetting("summary")
        ctx.status = summary and summary.status
        local dp = ds:readSetting("doc_props")
        if type(dp) == "table" then title, authors = dp.title, dp.authors end
        ctx.annotations = ds:readSetting("annotations")
        ctx.doc_pages = tonumber(ds:readSetting("doc_pages"))
        local pct = tonumber(ds:readSetting("percent_finished"))
        local xp = ds:readSetting("last_xpointer")
        local page = ds:readSetting("last_page")
        ctx.rolling = type(xp) == "string"
        if pct and pct > 0 then
            ctx.progress = {
                progress = ctx.rolling and xp or tostring(page or ""),
                percentage = clamp01(pct),
                paging = not ctx.rolling,
            }
        end
    end
    if not title or title == "" then
        local ok, bp = pcall(function()
            return require("apps/filemanager/filemanagerbookinfo").getDocProps(file, nil, true)
        end)
        if ok and type(bp) == "table" then
            title = bp.title
            if not authors or authors == "" then authors = bp.authors end
        end
    end
    if not title or title == "" then
        title = (ctx.filename:gsub("%.[^.]*$", ""))
    end
    ctx.props = { title = cleanTitle(title), authors = ((authors or ""):gsub("\n", ", ")) }
    return ctx
end

function CrossPointSync:contextFor(file)
    if self.ui and self.ui.document and self.ui.document.file == file then
        return self:readerContext()
    end
    return self:fileContext(file)
end

function CrossPointSync:xpointerExists(xp)
    local doc = self.ui.document
    if doc.isXPointerInDocument then
        local ok, res = pcall(doc.isXPointerInDocument, doc, xp)
        return ok and res and true or false
    end
    return false
end

function CrossPointSync:spineInfo(ctx, xp)
    local n = tonumber(tostring(xp or ""):match("DocFragment%[(%d+)%]"))
    if not n then return 0, 0, 1 end
    if not ctx.open then return n - 1, 0, 1 end
    local doc = self.ui.document
    local ok, s, e, cur = pcall(function()
        local start = doc:getPageFromXPointer("/body/DocFragment[" .. n .. "]/body")
        local nxt = "/body/DocFragment[" .. (n + 1) .. "]/body"
        local stop
        if self:xpointerExists(nxt) then stop = doc:getPageFromXPointer(nxt) end
        stop = stop or (doc:getPageCount() + 1)
        return start, stop, doc:getPageFromXPointer(xp)
    end)
    if not ok or not s or not e or not cur then return n - 1, 0, 1 end
    local pages = math.max(e - s, 1)
    local page = math.min(math.max(cur - s, 0), pages - 1)
    return n - 1, page, pages
end

function CrossPointSync:percentOfXPointer(xp)
    local ok, res = pcall(function()
        local h = (self.ui.rolling and self.ui.rolling.doc_height) or self.ui.document.info.doc_height
        if not h or h == 0 then return nil end
        return self.ui.document:getPosFromXPointer(xp) / h
    end)
    return ok and res and clamp01(res) or nil
end

function CrossPointSync:percentOfAnnotation(ctx, a, xp)
    if ctx.open then return self:percentOfXPointer(xp) end
    if tonumber(a.pageno) and ctx.doc_pages and ctx.doc_pages > 0 then
        return clamp01(a.pageno / ctx.doc_pages)
    end
    return nil
end

function CrossPointSync:fetchRemote(id)
    local code, data, err = self:request("GET", "/syncs/progress/" .. id)
    if not code then return nil, data or err end
    if code == 204 or code == 404 then return nil end
    if code == 401 then return nil, err end
    if not httpOk(code) then return nil, "HTTP " .. code end
    if type(data) ~= "table" or (data.progress == nil and data.percentage == nil) then return nil end
    data.id = id
    data.percentage = tonumber(data.percentage)
    return data
end

function CrossPointSync:findTitleMatches(ctx, own_ids)
    local title, author = ctx.props.title, ctx.props.authors
    if title == "" or author == "" then return {} end
    local code, data = self:request("GET", "/api/v1/progress?limit=500")
    if not httpOk(code) or type(data) ~= "table" or type(data.items) ~= "table" then return {} end
    local matches = {}
    for _i, it in ipairs(data.items) do
        if type(it) == "table" and type(it.document) == "string" and not own_ids[it.document]
                and sameTitle(it.title, title) and sameAuthor(it.author, author) then
            matches[#matches + 1] = {
                id = it.document,
                progress = it.progress,
                percentage = tonumber(it.percentage),
                device = type(it.device) == "string" and it.device or nil,
                device_id = type(it.device_id) == "string" and it.device_id or nil,
                title_match = true,
            }
        end
    end
    return matches
end

function CrossPointSync:rememberMatches(ctx, matches)
    local key = ctx.hashes.filename
    local ids = {}
    for _i, m in ipairs(matches) do ids[#ids + 1] = m.id end
    if #ids == 0 then ids = nil end
    if ids == nil and self.matches[key] == nil then return end
    self.matches[key] = ids
    self:setSetting("matches", self.matches)
end

function CrossPointSync:uploadProgress(ctx, ids, local_p)
    local pct = local_p.percentage
    local base = {
        progress = local_p.progress,
        percentage = pct,
        device = self:getSetting("device_name", "KOReader"),
        device_id = self:getSetting("device_id"),
    }
    local function send(doc_id, extra)
        local body = { document = doc_id }
        for k, v in pairs(base) do body[k] = v end
        if extra then for k, v in pairs(extra) do body[k] = v end end
        local code, data, err = self:request("PUT", "/syncs/progress", body)
        if not httpOk(code) then return false, reqError(code, data, err) end
        return true
    end

    local extra = {}
    if ctx.open and not local_p.paging then
        local spine, page, pages = self:spineInfo(ctx, local_p.progress)
        extra.position = {
            pctQ = math.floor(pct * 1000000 + 0.5),
            spine = spine, page = page, pages = pages,
        }
        if #local_p.progress <= 120 then extra.position.xpath = local_p.progress end
    end
    extra.metadata = { filename = ctx.filename }
    if ctx.props.title ~= "" then extra.metadata.title = ctx.props.title end
    if ctx.props.authors ~= "" then extra.metadata.authors = ctx.props.authors end

    local ok, err = send(ids.primary, extra)
    if not ok then return false, err end
    if ids.alt and self:getSetting("write_alias", true) then send(ids.alt) end
    for _i, other in ipairs(self.matches[ctx.hashes.filename] or {}) do send(other) end
    return true
end

function CrossPointSync:applyRemote(remote)
    local ok = false
    if self.ui.document.info.has_pages then
        local pages = self.ui.document:getPageCount()
        local page = math.max(1, math.min(pages, math.floor(remote.percentage * pages + 0.5)))
        self.ui:handleEvent(Event:new("GotoPage", page))
        ok = true
    else
        local xp = remote.progress
        if type(xp) == "string" and xp:match("^/body/DocFragment") and self:xpointerExists(xp)
                and (self:percentOfXPointer(xp) == nil
                     or math.abs(self:percentOfXPointer(xp) - remote.percentage) <= 0.05) then
            self.ui:handleEvent(Event:new("GotoXPointer", xp))
            ok = true
        end
        if not ok then
            local h = (self.ui.rolling and self.ui.rolling.doc_height) or self.ui.document.info.doc_height
            if h and h > 0 then
                self.ui.rolling:gotoPos(remote.percentage * h)
                ok = true
            end
        end
    end
    return ok
end

local function compare(local_p, remote)
    local delta = local_p.percentage - (remote.percentage or 0)
    if math.abs(delta) <= 0.001 then return "synced" end
    return delta > 0 and "local" or "remote"
end

function CrossPointSync:syncProgress(ctx, mode, silent)
    if not ctx then return end
    if not self:isConfigured() then
        if not silent then self:notify(_("Set the server, username and password first (Tools → CrossPoint Sync → Settings → Account & server).")) end
        return
    end
    local ids = self:idsFor(ctx)
    local local_p = ctx.progress

    if mode == "push" then
        if silent then
            local remote = self:fetchRemote(ids.primary)
            if remote and compare(local_p, remote) == "synced" then return end
        end
        local ok, err = self:uploadProgress(ctx, ids, local_p)
        if not silent then
            self:notify(ok and T(_("Progress uploaded (%1)."), formatPercent(local_p.percentage))
                or T(_("Upload failed: %1"), tostring(err)))
        end
        return
    end

    local remote, err = self:fetchRemote(ids.primary)
    if err then
        if not silent then self:notify(T(_("Could not fetch progress: %1"), tostring(err))) end
        return
    end
    if ids.alt then
        local r2 = self:fetchRemote(ids.alt)
        if r2 and (not remote or (r2.percentage or 0) > (remote.percentage or 0)) then remote = r2 end
    end

    local title_mode = self:getSetting("title_match", "missing")
    if title_mode == "always" or (title_mode == "missing" and not remote) then
        local own = { [ids.primary] = true }
        if ids.alt then own[ids.alt] = true end
        local matches = self:findTitleMatches(ctx, own)
        self:rememberMatches(ctx, matches)
        for _i, m in ipairs(matches) do
            if not remote or (m.percentage or 0) > (remote.percentage or 0) then remote = m end
        end
    end

    if not remote then
        if mode == "pull" then
            if not silent then self:notify(_("No remote progress for this book.")) end
            return
        end
        self:uploadProgress(ctx, ids, local_p)
        if not silent then self:notify(T(_("No remote progress – uploaded local progress (%1)."), formatPercent(local_p.percentage))) end
        return
    end

    local result = compare(local_p, remote)
    local from = (remote.device and remote.device ~= "") and remote.device or _("another device")
    local same_device = remote.device_id and remote.device_id == self:getSetting("device_id")

    if result == "remote" and not (same_device and not remote.title_match) then
        local function apply()
            if self:applyRemote(remote) then
                self:notify(T(_("Applied progress from %1 (%2)."), from, formatPercent(remote.percentage)))
            else
                self:notify(_("Could not apply remote progress."))
            end
        end
        local pull_mode = self:getSetting("pull_mode", "prompt")
        if mode == "pull" or pull_mode == "silent" then
            apply()
        elseif pull_mode == "prompt" then
            local text = T(_("%1 is at %2, this device at %3.\n\nGo to the remote position?"),
                from, formatPercent(remote.percentage), formatPercent(local_p.percentage))
            if remote.title_match then
                text = _("Found this book under another file name.\n\n") .. text
            end
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_text = _("Apply remote"),
                cancel_text = _("Keep local"),
                ok_callback = apply,
                cancel_callback = function()
                    if mode == "smart" then
                        local fresh = self:readerContext()
                        if fresh then self:uploadProgress(fresh, ids, fresh.progress) end
                    end
                end,
            })
        end
        return
    end

    if mode == "pull" then
        if not silent then self:notify(_("Already in sync.")) end
        return
    end
    if result == "local" then
        local ok, e = self:uploadProgress(ctx, ids, local_p)
        if not silent then
            self:notify(ok and T(_("Uploaded local progress (%1)."), formatPercent(local_p.percentage))
                or T(_("Upload failed: %1"), tostring(e)))
        end
    elseif not silent then
        self:notify(T(_("Already in sync (%1)."), formatPercent(local_p.percentage)))
    end
end

function CrossPointSync:uploadDocumentInfo(ctx)
    local item = { document = ctx.hashes.filename, filename = ctx.filename }
    if ctx.props.title ~= "" then item.title = ctx.props.title end
    if ctx.props.authors ~= "" then item.author = ctx.props.authors end
    local size = lfs.attributes(ctx.file, "size")
    if size then item.filesize = size end
    local code, data, err = self:request("PUT", "/api/v1/documents", { items = { item } })
    if not httpOk(code) then return false, reqError(code, data, err) end
    return true
end

function CrossPointSync:chunked(path, items)
    for i = 1, #items, 20 do
        local chunk = {}
        for j = i, math.min(i + 19, #items) do chunk[#chunk + 1] = items[j] end
        local code, data, err = self:request("PUT", path, { items = chunk })
        if not httpOk(code) then return false, reqError(code, data, err) end
    end
    return true
end

function CrossPointSync:pagedAnnotations(ctx, annotations)
    local clippings, bookmarks = {}, {}
    local total = ctx.doc_pages
    if ctx.open then
        local ok, n = pcall(function() return self.ui.document:getPageCount() end)
        if ok then total = n end
    end
    total = tonumber(total)
    if not total or total <= 0 then return clippings, bookmarks end
    local function pageOf(v)
        if type(v) == "table" then return tonumber(v.page) end
        return tonumber(v)
    end
    for _i, a in ipairs(annotations) do
        local page = tonumber(a.pageno) or pageOf(a.page) or pageOf(a.pos0)
        if page and page >= 1 then
            local pct = clamp01(page / total)
            local quote = a.text and a.text:gsub("%s+", " ") or ""
            local summary = quote ~= "" and quote or (a.chapter or formatPercent(pct))
            local loc = tostring(math.floor(page))
            bookmarks[#bookmarks + 1] = {
                id = sha16("page:" .. loc .. ":" .. (a.datetime or "")),
                xpath = loc,
                percentage = pct,
                summary = truncateChars(summary, 256),
                si = 0, pc = total, pp = math.floor(page) - 1,
            }
            if a.drawer ~= nil and quote ~= "" then
                local end_page = pageOf(a.pos1) or page
                local created = parseDatetime(a.datetime)
                local text = formatPercent(pct) .. "\n\n" .. (a.text or "")
                if #text > 2048 then text = truncateUtf8(text, 2048) end
                local c = {
                    id = sha16(string.format("%d", created) .. text),
                    spine = 0,
                    start_page = math.floor(page) - 1,
                    end_page = math.max(math.floor(end_page), math.floor(page)) - 1,
                    pages = total,
                    start_word = 0, end_word = 0, words = 0,
                    text = text,
                    created_at = created,
                }
                if a.chapter and a.chapter ~= "" then c.chapter = truncateChars(a.chapter, 64) end
                if a.note and a.note ~= "" then c.note = truncateUtf8(a.note, 4096) end
                clippings[#clippings + 1] = c
            end
        end
    end
    return clippings, bookmarks
end

function CrossPointSync:sendAnnotations(ctx)
    local annotations = ctx.annotations
    if ctx.open and not annotations then
        return false, _("This KOReader version has no annotation list; please update.")
    end
    annotations = annotations or {}
    local doc = ctx.hashes.filename
    local clippings, bookmarks = {}, {}

    local paged = {}
    for _i, a in ipairs(annotations) do
        local xp = type(a.page) == "string" and a.page or a.pos0
        if not (type(xp) == "string" and xp:match("^/body")) then paged[#paged + 1] = a end
    end
    if #paged > 0 then
        clippings, bookmarks = self:pagedAnnotations(ctx, paged)
    end
    for _i, a in ipairs(annotations) do
        local xp = type(a.page) == "string" and a.page or a.pos0
        if type(xp) == "string" and xp:match("^/body") then
            local spine, page, pages = self:spineInfo(ctx, xp)
            local pct = self:percentOfAnnotation(ctx, a, xp) or 0
            local quote = a.text and a.text:gsub("%s+", " ") or ""
            local summary = quote ~= "" and quote or (a.chapter or formatPercent(pct))

            bookmarks[#bookmarks + 1] = {
                id = sha16(xp:sub(1, 512)),
                xpath = xp:sub(1, 512),
                percentage = pct,
                summary = truncateChars(summary, 256),
                si = spine, pc = pages, pp = page,
            }

            if a.pos0 and a.pos1 and quote ~= "" then
                local _sp, end_page = self:spineInfo(ctx, a.pos1)
                local created = parseDatetime(a.datetime)
                local text = formatPercent(pct) .. "\n\n" .. (a.text or "")
                if #text > 2048 then text = truncateUtf8(text, 2048) end  
                local c = {
                    id = sha16(string.format("%d", created) .. text),
                    spine = spine,
                    start_page = page,
                    end_page = math.max(end_page or page, page),
                    pages = pages,
                    start_word = 0, end_word = 0, words = 0,
                    text = text,
                    created_at = created,
                }
                if a.chapter and a.chapter ~= "" then c.chapter = truncateChars(a.chapter, 64) end
                if a.note and a.note ~= "" then c.note = truncateUtf8(a.note, 4096) end
                clippings[#clippings + 1] = c
            end
        end
    end

    if #clippings == 0 and #bookmarks == 0 then
        return true, _("No highlights or bookmarks in this book."), 0, 0
    end
    local ok, err = self:chunked("/api/v1/clippings/" .. doc, clippings)
    if not ok then return false, err end
    ok, err = self:chunked("/api/v1/bookmarks/" .. doc, bookmarks)
    if not ok then return false, err end
    return true, T(_("Sent %1 highlight(s) and %2 bookmark(s)."), #clippings, #bookmarks), #clippings, #bookmarks
end

function CrossPointSync:setReadingStatus(ctx, value) 
    local body = value and ('{"status":"' .. value .. '"}') or '{"status":null}'
    local code, data, err = self:request("PUT", "/api/v1/documents/" .. ctx.hashes.filename .. "/status", body)
    if not httpOk(code) then
        return false, reqError(code, data, err)
    end
    local b = self:statsRecord(ctx.hashes.filename, false)
    if b then
        if value == "finished" then
            b.completed, b.finished_date, b.finish_manual = true, statsDateSeconds(os.time()), true
        elseif value then
            b.completed, b.finished_date, b.finish_manual = false, 0, false
        end
    end
    return true
end

function CrossPointSync:syncKoreaderStatus(ctx)
    local map = { complete = "finished", abandoned = "paused" }
    local mapped = map[ctx.status]
    local key = ctx.hashes.filename
    local sent = self.status_sent[key]
    if mapped and sent ~= mapped then
        if self:setReadingStatus(ctx, mapped) then
            self.status_sent[key] = mapped
            self:setSetting("status_sent", self.status_sent)
        end
    elseif not mapped and sent then
        self.status_sent[key] = nil
        self:setSetting("status_sent", self.status_sent)
    end
end

function CrossPointSync:newStatsRecord()
    return {
        sessions = 0, seconds = 0, pages = 0,
        pace_n = 0, pace_seconds = 0, pace_pct = 0, pace_pct_n = 0,
        last_pct = nil, completed = false, finish_manual = false,
        start_date = 0, finished_date = 0,
        tod = { 0, 0, 0, 0 }, dow = { 0, 0, 0, 0, 0, 0, 0 },
    }
end

function CrossPointSync:statsRecord(hash, create)
    local b = self.stats.books[hash]
    if not b and create then
        b = self:newStatsRecord()
        self.stats.books[hash] = b
    end
    return b
end

function CrossPointSync:currentStatsBook()
    if not (self.ui and self.ui.document) then return nil end
    return self:statsRecord(self:hashesFor(self.ui.document.file).filename, true)
end

function CrossPointSync:statsAddTime(b, seconds, now)
    if not self.cur.session_counted then
        b.sessions = b.sessions + 1
        self.cur.session_counted = true
    end
    if b.start_date == 0 then b.start_date = statsDateSeconds(now) end
    local d = os.date("*t", now)
    b.seconds = b.seconds + seconds
    local t = timeOfDay(d.hour)
    b.tod[t] = b.tod[t] + seconds
    local w = (d.wday + 5) % 7 + 1      -- Monday = 1
    b.dow[w] = b.dow[w] + seconds
    local day = statsDay(now)
    local days = self.stats.days
    if days[#days] ~= day then
        local found = false
        for i = math.max(1, #days - 5), #days do
            if days[i] == day then found = true break end
        end
        if not found then days[#days + 1] = day end
    end
end

function CrossPointSync:statsOnPage(pageno)
    if not self.cur or type(pageno) ~= "number" then return end
    local b = self:currentStatsBook()
    if not b then return end
    local now = os.time()
    local c = self.cur
    local elapsed = c.last and (now - c.last) or nil
    local delta = c.last_page and (pageno - c.last_page) or 0

    if elapsed and elapsed <= self:tunable("stats_idle") then
        self:statsAddTime(b, elapsed, now)
    else
        c.session_counted = false
        elapsed = nil
    end
    c.last = now

    if c.last_page and delta ~= 0 and math.abs(delta) <= 3 then
        b.pages = b.pages + 1
        local pct = self:getLocalProgress().percentage
        if delta > 0 and elapsed and elapsed >= self:tunable("stats_min_page") then
            b.pace_n = b.pace_n + 1
            b.pace_seconds = b.pace_seconds + elapsed
            if b.last_pct and pct > b.last_pct then
                b.pace_pct = b.pace_pct + (pct - b.last_pct)
                b.pace_pct_n = b.pace_pct_n + 1
            end
        end
        local total = self.ui.document:getPageCount()
        if delta > 0 and total and pageno >= total and not b.completed then
            b.completed, b.finished_date, b.finish_manual = true, statsDateSeconds(now), false
        end
    end
    local ok, pct = pcall(function() return self:getLocalProgress().percentage end)
    if ok then b.last_pct = pct end
    c.last_page = pageno
end

function CrossPointSync:statsEnd()
    if self.cur then
        self.cur.last = nil
        self.cur.last_page = nil
        self.cur.session_counted = false
    end
end

function CrossPointSync:statsEta(b)
    if b.completed or b.pace_n == 0 or b.pace_pct_n == 0 or b.pace_pct == 0 or not b.last_pct then return 0 end
    local remaining_pages = math.max(1 - b.last_pct, 0) / (b.pace_pct / b.pace_pct_n)
    return math.floor(remaining_pages * b.pace_seconds / b.pace_n + 0.5)
end

local function roundAll(t)
    local r = {}
    for i, v in ipairs(t) do r[i] = math.floor(v + 0.5) end
    return r
end

function CrossPointSync:statsBookSnapshot(doc, b)
    return {
        document = doc, v = 5,
        sessions = b.sessions, seconds = math.floor(b.seconds + 0.5), pages = b.pages,
        completed = b.completed,
        avg_fwd = b.pace_n > 0 and math.floor(b.pace_seconds / b.pace_n + 0.5) or 0,
        pace_n = b.pace_n,
        eta = self:statsEta(b),
        start_manual = false, finish_manual = b.finish_manual,
        start_date = b.start_date, finished_date = b.finished_date,
        tod = roundAll(b.tod), dow = roundAll(b.dow),
    }
end

function CrossPointSync:statsGlobalSnapshot(snapshots)
    local g = {
        device_id = self:getSetting("device_id"),
        device = self:getSetting("device_name", "KOReader"),
        v = 5, sessions = 0, seconds = 0, pages = 0, completed = 0,
        tod = { 0, 0, 0, 0 }, dow = { 0, 0, 0, 0, 0, 0, 0 },
    }
    for _i, s in ipairs(snapshots) do
        g.sessions = g.sessions + s.sessions
        g.seconds = g.seconds + s.seconds
        g.pages = g.pages + s.pages
        if s.completed then g.completed = g.completed + 1 end
        for i, v in ipairs(s.tod) do g.tod[i] = g.tod[i] + v end
        for i, v in ipairs(s.dow) do g.dow[i] = g.dow[i] + v end
    end
    local days = {}
    for _i, d in ipairs(self.stats.days) do days[#days + 1] = d end
    table.sort(days)
    local anchor = statsDay(os.time())
    local history_days = self:tunable("stats_history_days")
    local bits = {}
    for i = 1, math.ceil(history_days / 8) do bits[i] = 0 end
    local streak, run = 0, 0
    for i, day in ipairs(days) do
        local n = anchor - day    
        if n >= 0 and n < history_days then
            local idx = math.floor(n / 8) + 1
            bits[idx] = bits[idx] + 2 ^ (n % 8) 
        end
        run = (i > 1 and day == days[i - 1] + 1) and run + 1 or 1
        if run > streak then streak = run end
    end
    local chars = {}
    for i, v in ipairs(bits) do chars[i] = string.char(math.floor(v)) end
    g.anchor_day = anchor
    g.history_b64 = mime.b64(table.concat(chars))
    g.streak = streak
    return g
end

function CrossPointSync:uploadStats(only_doc, only_md5)
    local ok, err, empty = self:uploadTrackedStats(only_doc)
    if self:getSetting("historical_stats", false) then
        local hok, herr, sent = self:uploadHistoricalStats(only_md5)
        if not hok then return false, T(_("Historical stats: %1"), tostring(herr)) end
        if empty and sent > 0 then return true end
    end
    return ok, err
end

function CrossPointSync:historyTimezone()
    local tz = self:getSetting("stats_timezone", "")
    if tz ~= "" then return tz end
    local function valid(v)
        v = v and v:match("^%s*(.-)%s*$")
        if v and (v == "UTC" or v:match("^%a+/[%w_+%-/]+$")) then return v end
    end
    tz = valid(os.getenv("TZ"))
    if tz then return tz end
    local f = io.open("/etc/timezone", "r")
    if f then
        tz = valid(f:read("*l"))
        f:close()
        if tz then return tz end
    end
    local ok, attr = pcall(lfs.symlinkattributes, "/etc/localtime")
    if ok and type(attr) == "table" and type(attr.target) == "string" then
        tz = valid(attr.target:match("zoneinfo/(.+)$"))
        if tz then return tz end
    end
    return "UTC"
end

function CrossPointSync:uploadHistoricalStats(only_md5)
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        if only_md5 then return true, nil, 0 end
        return false, _("No KOReader reading statistics found. Turn on Reading statistics in KOReader first."), 0
    end
    if only_md5 then
        only_md5 = only_md5:lower()
        if not only_md5:match("^[0-9a-f]+$") or #only_md5 ~= 32 then return true, nil, 0 end
    end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path)
    local function close() if conn then pcall(function() conn:close() end) conn = nil end end
    local ok, books = pcall(function()
        conn:exec("PRAGMA query_only=ON;")
        local rows = conn:exec([[SELECT COALESCE(lower(md5), '') AS md5, MAX(COALESCE(title, '')) AS title,
            MAX(COALESCE(authors, '')) AS authors FROM book
            WHERE EXISTS (SELECT 1 FROM page_stat_data p WHERE p.id_book = book.id AND p.total_pages > 0 AND p.duration > 0)]]
            .. (only_md5 and (" AND lower(md5) = '" .. only_md5 .. "'") or "")
            .. " GROUP BY lower(md5) ORDER BY lower(md5)")
        local list = {}
        if rows then
            for i, hash in ipairs(rows.md5) do
                if #hash == 32 and hash:match("^[0-9a-f]+$") then
                    list[#list + 1] = { md5 = hash, title = rows.title[i], authors = rows.authors[i] }
                end
            end
        end
        return list
    end)
    if not ok then close() return false, tostring(books), 0 end

    local hist_sent = self:getSetting("hist_sent", {})
    local timezone = self:historyTimezone()
    local sent = 0
    for _i, book in ipairs(books) do
        local pok, pages = pcall(function()
            local rows = conn:exec(string.format([[SELECT p.page, p.total_pages, p.start_time, MAX(p.duration) AS duration
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE lower(b.md5) = '%s' AND p.total_pages > 0 AND p.duration > 0
                GROUP BY p.page, p.total_pages, p.start_time ORDER BY p.start_time, p.page, p.total_pages LIMIT 20001]], book.md5))
            local list = {}
            if rows then
                for i = 1, #rows.page do
                    list[i] = { page = tonumber(rows.page[i]), total_pages = tonumber(rows.total_pages[i]),
                        start_time = tonumber(rows.start_time[i]), duration = tonumber(rows.duration[i]) }
                end
            end
            return list
        end)
        if not pok then close() return false, tostring(pages), sent end
        if #pages > 0 and #pages <= 20000 then
            local body = json.encode({ version = 1, book = book, timezone = timezone, pages = pages })
            local fingerprint = sha2.md5(body)
            if hist_sent[book.md5] ~= fingerprint then
                local code, data, err = self:request("POST", "/api/v1/stats/koreader", body)
                if code == 409 then
                    logger.info("CrossPointSync: history import conflict, skipped", book.title)
                elseif not httpOk(code) then
                    close()
                    self:setSetting("hist_sent", hist_sent)
                    return false, T(_("%1: %2"), book.title, reqError(code, data, err)), sent
                elseif type(data) == "table" and data.accepted == #pages then
                    hist_sent[book.md5] = fingerprint
                    sent = sent + 1
                else
                    close()
                    self:setSetting("hist_sent", hist_sent)
                    return false, _("The server did not accept the history. Update the CrossPoint Sync server."), sent
                end
            end
        end
    end
    close()
    self:setSetting("hist_sent", hist_sent)
    return true, nil, sent
end

function CrossPointSync:uploadTrackedStats(only_doc)
    local all, send = {}, {}
    for doc, b in pairs(self.stats.books) do
        if b.seconds > 0 or b.completed then
            local snap = self:statsBookSnapshot(doc, b)
            all[#all + 1] = snap
            if not only_doc or only_doc == doc then send[#send + 1] = snap end
        end
    end
    if only_doc and #send == 0 then
        return false, _("No reading stats tracked for this book yet."), true
    end
    local device_id = self:getSetting("device_id")
    for i = 1, #send, 20 do
        local chunk = {}
        for j = i, math.min(i + 19, #send) do chunk[#chunk + 1] = send[j] end
        local code, data, err = self:request("PUT", "/api/v1/stats/books", { device_id = device_id, items = chunk })
        if not httpOk(code) then return false, reqError(code, data, err) end
    end
    local code, data, err = self:request("PUT", "/api/v1/stats/global", self:statsGlobalSnapshot(all))
    if not httpOk(code) then return false, reqError(code, data, err) end
    return true
end

function CrossPointSync:flushStats()
    self.settings:saveSetting("stats", self.stats)
    self.settings:flush()
end

function CrossPointSync:syncAll()
    self:onlineOrAsk(function()
        local ctx = self:readerContext()
        if not ctx then return end
        local lines = {}
        local ok, err = pcall(function() self:syncProgress(ctx, "smart", true) end)
        lines[#lines + 1] = ok and _("Progress: done") or T(_("Progress: %1"), tostring(err))

        local r, e = self:uploadDocumentInfo(ctx)
        lines[#lines + 1] = r and _("Book info: sent") or T(_("Book info: %1"), tostring(e))

        local ok2, msg = self:sendAnnotations(ctx)
        lines[#lines + 1] = T(_("Highlights: %1"), tostring(msg))
        if not ok2 then logger.warn("CrossPointSync: annotations", msg) end
        pcall(function() self:syncKoreaderStatus(ctx) end)

        if self:getSetting("send_stats", true) then
            self:statsEnd()
            self:flushStats()
            local s, se = self:uploadStats()
            lines[#lines + 1] = s and _("Reading stats: sent") or T(_("Reading stats: %1"), tostring(se))
        end
        self:notify(table.concat(lines, "\n"), 6)
    end)
end

function CrossPointSync:wantsAutoPush()
    if not (self:getSetting("auto_push", true) and self:isConfigured() and self.ui.document) then return false end
    local ok, ctx = pcall(function() return self:readerContext() end)
    return not (ok and ctx) or self:ctxStatusEnabled(ctx)
end

function CrossPointSync:autoPush()
    if not self:wantsAutoPush() then return end
    if not NetworkMgr:isConnected() then return end
    pcall(function() self:syncProgress(self:readerContext(), "push", true) end)
end

function CrossPointSync:bookAction(file, what)
    self:onlineOrAsk(function()
        local ctx = self:contextFor(file)
        if not ctx then return end
        local ok, msg
        if what == "progress" then
            if not ctx.progress then
                self:notify(_("This book has no reading progress yet."))
                return
            end
            ok, msg = self:uploadProgress(ctx, self:idsFor(ctx), ctx.progress)
            if ok then msg = T(_("Progress uploaded (%1)."), formatPercent(ctx.progress.percentage)) end
        elseif what == "annotations" then
            ok, msg = self:sendAnnotations(ctx)
        elseif what == "info" then
            ok, msg = self:uploadDocumentInfo(ctx)
            if ok then msg = _("Book info sent.") end
        elseif what == "stats" then
            ok, msg = self:uploadStats(ctx.hashes.filename, ctx.hashes.binary)
            if ok then msg = _("Reading stats sent.") end
        end
        self:notify(ok and msg or T(_("Failed: %1"), tostring(msg)), ok and 3 or 5)
    end)
end

local function bookStarted(ctx)
    return ctx.progress ~= nil or ctx.status == "reading" or ctx.status == "complete" or ctx.status == "abandoned"
end

function CrossPointSync:pushStatusEnabled(status)
    local enabled = self:getSetting("push_statuses", {})
    return enabled[status] ~= false
end

function CrossPointSync:ctxStatusEnabled(ctx)
    local status = ctx.status
    if status ~= "abandoned" and status ~= "complete" then status = "reading" end
    return self:pushStatusEnabled(status)
end

function CrossPointSync:pushBookData(file, summary)
    local ctx = self:fileContext(file)
    if not bookStarted(ctx) then
        summary.unread = summary.unread + 1
        return
    end
    if not self:ctxStatusEnabled(ctx) then
        summary.filtered = summary.filtered + 1
        return
    end
    local ok_all, last_err = true, nil
    local function track(ok, err)
        if ok then
            summary.fail_streak = 0
        else
            ok_all, last_err = false, err
            summary.fail_streak = summary.fail_streak + 1
        end
    end

    if ctx.progress then
        local ids = self:idsFor(ctx)
        local remote = self:fetchRemote(ids.primary)
        local result = remote and compare(ctx.progress, remote)
        if result == "synced" then
            summary.same = summary.same + 1
        elseif result == "remote" and remote.device_id ~= self:getSetting("device_id") then
            summary.behind = summary.behind + 1
        else
            track(self:uploadProgress(ctx, ids, ctx.progress))
        end
    end
    track(self:uploadDocumentInfo(ctx))
    if ctx.annotations and #ctx.annotations > 0 then
        track(self:sendAnnotations(ctx))
    end
    pcall(function() self:syncKoreaderStatus(ctx) end)

    if ok_all then
        summary.pushed = summary.pushed + 1
    else
        summary.failed = summary.failed + 1
        logger.warn("CrossPointSync: push failed for", file, last_err)
    end
end

function CrossPointSync:pushAllBooks()
    self:onlineOrAsk(function(done)
        local ReadHistory = require("readhistory")
        local files, seen = {}, {}
        for _i, item in ipairs(ReadHistory.hist or {}) do
            local f = item.file
            if f and not seen[f] and lfs.attributes(f, "mode") == "file" then
                seen[f] = true
                files[#files + 1] = f
            end
        end
        if #files == 0 then
            self:notify(_("No books in the reading history."))
            return
        end

        local summary = { pushed = 0, unread = 0, filtered = 0, same = 0, behind = 0, failed = 0, fail_streak = 0 }
        local total, i, msg = #files, 0, nil
        local function show(text)
            if msg then UIManager:close(msg) end
            msg = InfoMessage:new{ text = text }
            UIManager:show(msg)
            UIManager:forceRePaint()
        end
        local function finish(aborted)
            local lines = {}
            if aborted then
                lines[#lines + 1] = _("Stopped: the server could not be reached.")
            elseif self:getSetting("send_stats", true) then
                show(_("CrossPoint sync: sending reading stats…"))
                local ok, err = self:uploadStats()
                if not ok then lines[#lines + 1] = T(_("Reading stats: %1"), tostring(err)) end
            end
            if msg then UIManager:close(msg) end
            table.insert(lines, 1, T(_("Pushed %1 book(s)."), summary.pushed))
            if summary.same > 0 then
                lines[#lines + 1] = T(_("%1 book(s): progress already up to date on the server."), summary.same)
            end
            if summary.behind > 0 then
                lines[#lines + 1] = T(_("%1 book(s): progress not sent, the server is further ahead."), summary.behind)
            end
            if summary.unread > 0 then lines[#lines + 1] = T(_("%1 unread book(s) skipped."), summary.unread) end
            if summary.filtered > 0 then
                lines[#lines + 1] = T(_("%1 book(s) skipped because of their status."), summary.filtered)
            end
            if summary.failed > 0 then lines[#lines + 1] = T(_("%1 book(s) failed."), summary.failed) end
            self:notify(table.concat(lines, "\n"), 8)
            done()
        end
        local function step()
            i = i + 1
            if i > total then return finish(false) end
            if summary.fail_streak >= 3 then return finish(true) end
            show(T(_("CrossPoint sync %1/%2\n%3"), i, total, basename(files[i])))
            UIManager:nextTick(function()
                local ok, err = pcall(function() self:pushBookData(files[i], summary) end)
                if not ok then
                    summary.failed = summary.failed + 1
                    logger.warn("CrossPointSync: push error", files[i], err)
                end
                step()
            end)
        end
        step()
        return true -- asynchronous
    end)
end

function CrossPointSync:syncAllAnnotations()
    self:onlineOrAsk(function(done)
        local ReadHistory = require("readhistory")
        local files, seen = {}, {}
        for _i, item in ipairs(ReadHistory.hist or {}) do
            local f = item.file
            if f and not seen[f] and lfs.attributes(f, "mode") == "file" then
                seen[f] = true
                files[#files + 1] = f
            end
        end
        if #files == 0 then
            self:notify(_("No books in the reading history."))
            return
        end
        local summary = { books = 0, clippings = 0, bookmarks = 0, none = 0, failed = 0, fail_streak = 0 }
        local total, i, msg = #files, 0, nil
        local function show(text)
            if msg then UIManager:close(msg) end
            msg = InfoMessage:new{ text = text }
            UIManager:show(msg)
            UIManager:forceRePaint()
        end
        local function finish(aborted)
            if msg then UIManager:close(msg) end
            local lines = {
                T(_("Sent highlights and bookmarks for %1 book(s): %2 highlight(s), %3 bookmark(s)."),
                    summary.books, summary.clippings, summary.bookmarks),
            }
            if aborted then table.insert(lines, 1, _("Stopped: the server could not be reached.")) end
            if summary.none > 0 then lines[#lines + 1] = T(_("%1 book(s) without highlights or bookmarks."), summary.none) end
            if summary.failed > 0 then lines[#lines + 1] = T(_("%1 book(s) failed."), summary.failed) end
            self:notify(table.concat(lines, "\n"), 8)
            done()
        end
        local function one(file)
            local ctx = self:contextFor(file)
            if not ctx or not ctx.annotations or #ctx.annotations == 0 then
                summary.none = summary.none + 1
                return
            end
            local ok, res, c, b = self:sendAnnotations(ctx)
            if not ok then
                summary.failed = summary.failed + 1
                summary.fail_streak = summary.fail_streak + 1
                logger.warn("CrossPointSync: annotations failed for", file, res)
                return
            end
            summary.fail_streak = 0
            if c and (c + b) > 0 then
                summary.books = summary.books + 1
                summary.clippings = summary.clippings + tonumber(c)
                summary.bookmarks = summary.bookmarks + tonumber(b)
            else
                summary.none = summary.none + 1
            end
        end
        local function step()
            i = i + 1
            if i > total then return finish(false) end
            if summary.fail_streak >= 3 then return finish(true) end
            show(T(_("CrossPoint highlights %1/%2\n%3"), i, total, basename(files[i])))
            UIManager:nextTick(function()
                local ok, err = pcall(one, files[i])
                if not ok then
                    summary.failed = summary.failed + 1
                    logger.warn("CrossPointSync: annotations error", files[i], err)
                end
                step()
            end)
        end
        step()
        return true
    end)
end

local function tzOffsetMinutes()
    local now = os.time()
    local utc = os.date("!*t", now)
    utc.isdst = os.date("*t", now).isdst
    return math.floor(os.difftime(os.time(utc), now) / 60 + 0.5)
end

local function groupThousands(n)
    local str = tostring(math.floor(tonumber(n) or 0))
    local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function formatDuration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds >= 3600 then return T(_("%1h"), math.floor(seconds / 3600)) end
    return T(_("%1m"), math.floor(seconds / 60))
end

local function timeAgo(ts)
    ts = tonumber(ts)
    if not ts then return "" end
    local d = os.time() - ts
    if d < 3600 then return T(_("%1m ago"), math.max(1, math.floor(d / 60))) end
    if d < 86400 then return T(_("%1h ago"), math.floor(d / 3600)) end
    if d < 30 * 86400 then return T(_("%1d ago"), math.floor(d / 86400)) end
    return os.date("%d %b %Y", ts)
end

function CrossPointSync:fetchLibrary()
    local items, cursor = {}, nil
    for _page = 1, 20 do
        local path = "/api/v1/progress?limit=500" .. (cursor and ("&cursor=" .. util.urlEncode(cursor)) or "")
        local code, data, err = self:request("GET", path)
        if not httpOk(code) or type(data) ~= "table" then return nil, reqError(code, data, err) end
        for _i, it in ipairs(data.items or {}) do items[#items + 1] = it end
        cursor = data.next
        if type(cursor) ~= "string" or cursor == "" then break end
    end
    local index
    local books = {}
    for _i, it in ipairs(items) do
        local title = type(it.title) == "string" and it.title ~= "" and it.title
            or type(it.filename) == "string" and it.filename ~= "" and it.filename:gsub("%.[^.]*$", "")
        if not title then
            index = index or self:localBookIndex()
            local f = index[it.document]
            if f then
                it._file = f
                title = basename(f):gsub("%.[^.]*$", "")
            else
                title = T(_("Unknown book (%1)"), tostring(it.document):sub(1, 8))
            end
        end
        it._title = title
        it._author = type(it.author) == "string" and it.author or ""
        it._named = (type(it.title) == "string" and it.title ~= "") or (type(it.filename) == "string" and it.filename ~= "")
        books[#books + 1] = it
    end
    books._items = items
    return books
end

function CrossPointSync:localBookIndex()
    local ReadHistory = require("readhistory")
    local index = {}
    for _i, item in ipairs(ReadHistory.hist or {}) do
        local f = item.file
        if f and lfs.attributes(f, "mode") == "file" then
            local h = self:hashesFor(f)
            index[h.filename] = index[h.filename] or f
            if h.binary then index[h.binary] = index[h.binary] or f end
        end
    end
    return index
end

function CrossPointSync:findLocalBook(book)
    if book._file then return book._file end
    local ReadHistory = require("readhistory")
    for _i, item in ipairs(ReadHistory.hist or {}) do
        local f = item.file
        if f and lfs.attributes(f, "mode") == "file" then
            local name = basename(f)
            if (type(book.filename) == "string" and name == book.filename) or sha2.md5(name) == book.document then
                return f
            end
        end
    end
end

function CrossPointSync:editReadingDates(document, title, started_at, finished_at, on_saved)
    local ButtonDialog = require("ui/widget/buttondialog")
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local function key(t) return t and os.date("%Y-%m-%d", t) or nil end
    local orig = { start = key(tonumber(started_at)), finish = key(tonumber(finished_at)) }
    local cur = { start = orig.start, finish = orig.finish }
    local dialog
    local function label(k) return k and os.date("%d %b %Y", os.time{ year = tonumber(k:sub(1, 4)), month = tonumber(k:sub(6, 7)), day = tonumber(k:sub(9, 10)), hour = 12 }) or _("not set") end
    local show
    local function pick(which)
        local base = cur[which] or os.date("%Y-%m-%d")
        UIManager:close(dialog)
        UIManager:show(DateTimeWidget:new{
            year = tonumber(base:sub(1, 4)),
            month = tonumber(base:sub(6, 7)),
            day = tonumber(base:sub(9, 10)),
            ok_text = _("Set"),
            title_text = which == "start" and _("Started") or _("Finished"),
            callback = function(t)
                cur[which] = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
                show()
            end,
            cancel_callback = function() show() end,
        })
    end
    local function save()
        if cur.start and cur.finish and cur.start > cur.finish then
            self:notify(_("The start date is after the finish date."))
            return
        end
        local parts = {}
        for _i, f in ipairs{ { "start", "start_date" }, { "finish", "finished_date" } } do
            if cur[f[1]] ~= orig[f[1]] then
                parts[#parts + 1] = string.format('"%s":%s', f[2], cur[f[1]] and ('"' .. cur[f[1]] .. '"') or "null")
            end
        end
        UIManager:close(dialog)
        if #parts == 0 then return end
        self:onlineOrAsk(function()
            local code, data, err = self:request("PUT", "/api/v1/documents/" .. document .. "/dates", "{" .. table.concat(parts, ",") .. "}")
            if not httpOk(code) then
                self:notify(T(_("Could not save the dates: %1"), reqError(code, data, err)))
                return
            end
            self:notify(_("Reading dates saved."))
            if on_saved then on_saved() end
        end)
    end
    show = function()
        dialog = ButtonDialog:new{
            title = T(_("Reading dates · %1\n\nDates you set here win over your reader's. Setting a finish date marks the book finished."), title),
            title_align = "left",
            buttons = {
                {
                    { text = T(_("Started: %1"), label(cur.start)), callback = function() pick("start") end },
                    { text = _("Clear"), enabled = cur.start ~= nil, callback = function() cur.start = nil; UIManager:close(dialog); show() end },
                },
                {
                    { text = T(_("Finished: %1"), label(cur.finish)), callback = function() pick("finish") end },
                    { text = _("Clear"), enabled = cur.finish ~= nil, callback = function() cur.finish = nil; UIManager:close(dialog); show() end },
                },
                {
                    { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                    { text = _("Save"), callback = save },
                },
            },
        }
        UIManager:show(dialog)
    end
    show()
end

function CrossPointSync:showMenuPage(title, items, on_closed)
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Menu = require("ui/widget/menu")
    local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
    local page = InputContainer:new{
        covers_fullscreen = true,
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
    }
    local menu = Menu:new{
        title = title,
        item_table = items,
        width = sw,
        height = sh,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        show_parent = page,
        onClose = function()
            UIManager:close(page)
            UIManager:setDirty("all", "ui")
            if on_closed then on_closed(page) end
            return true
        end,
    }
    page[1] = FrameContainer:new{
        width = sw,
        height = sh,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        menu,
    }
    UIManager:show(page)
    return page
end

local function normTitle(s)
    return (tostring(s or ""):lower():gsub("[%s%p]+", ""))
end

function CrossPointSync:showBookDetails(book, close_all, all_books)
    local TextViewer = require("ui/widget/textviewer")
    local lines = { book._title }
    if book._author ~= "" then lines[#lines + 1] = book._author end
    lines[#lines + 1] = ""
    lines[#lines + 1] = T(_("Status: %1"), STATUS_LABELS[book.status] or book.status or "-")
    lines[#lines + 1] = T(_("Progress: %1"), formatPercent(tonumber(book.percentage) or 0))
    if tonumber(book.page_count) then lines[#lines + 1] = T(_("Pages: %1"), book.page_count) end
    if type(book.series) == "string" and book.series ~= "" then
        lines[#lines + 1] = T(_("Series: %1"), book.series .. (book.series_position and (" #" .. tostring(book.series_position)) or ""))
    end
    if tonumber(book.rating) then lines[#lines + 1] = T(_("Rating: %1"), book.rating) end
    if tonumber(book.release_year) then lines[#lines + 1] = T(_("Released: %1"), book.release_year) end
    if type(book.genres) == "table" and #book.genres > 0 then
        lines[#lines + 1] = T(_("Genres: %1"), table.concat(book.genres, ", "))
    end
    local d = book._dates or {}
    if tonumber(d.started_at) then lines[#lines + 1] = T(_("Started: %1"), os.date("%d %b %Y", tonumber(d.started_at))) end
    if tonumber(d.finished_at) then lines[#lines + 1] = T(_("Finished: %1"), os.date("%d %b %Y", tonumber(d.finished_at))) end
    lines[#lines + 1] = T(_("Last sync: %1 (%2)"), timeAgo(book.timestamp), book.device or "?")
    if type(book.filename) == "string" then lines[#lines + 1] = T(_("File: %1"), book.filename) end
    if not book._named then lines[#lines + 1] = _("No title or file name on the server.") end
    local aliases = type(book.aliases) == "table" and book.aliases or {}
    if #aliases > 0 then lines[#lines + 1] = T(_("Merged copies: %1"), #aliases) end

    local file = self:findLocalBook(book)
    local viewer, picker
    local function finish(message)
        if picker then UIManager:close(picker) end
        if viewer then UIManager:close(viewer) end
        if close_all then close_all() end
        UIManager:setDirty("all", "ui")
        if message then self:notify(message) end
        self:showLibrary()
    end
    local function serverAction(calls, done_message, fail_message)
        self:onlineOrAsk(function()
            for _i, c in ipairs(calls) do
                local code, data, err = self:request(c[1], c[2], c[3])
                if not httpOk(code) and not (c[4] and code == 404) then
                    self:notify(T(fail_message, reqError(code, data, err)))
                    return
                end
            end
            finish(done_message)
        end)
    end

    local function mergePicker()
        local likely, rest = {}, {}
        local key = normTitle(book._title)
        for _i, b in ipairs(all_books or {}) do
            if b.document ~= book.document then
                local other = normTitle(b._title)
                local same = other == key
                    or (math.min(#other, #key) >= 6 and (other:find(key, 1, true) or key:find(other, 1, true)))
                if same or not b._named then likely[#likely + 1] = b else rest[#rest + 1] = b end
            end
        end
        table.sort(likely, function(a, b)
            if a._named ~= b._named then return a._named == true end
            return (tonumber(a.timestamp) or 0) > (tonumber(b.timestamp) or 0)
        end)
        table.sort(rest, function(a, b) return a._title:lower() < b._title:lower() end)
        local items = {}
        local function add(b)
            items[#items + 1] = {
                text = b._author ~= "" and (b._title .. " · " .. b._author) or b._title,
                mandatory = (b._named and "" or (_("No metadata") .. " · ")) .. formatPercent(tonumber(b.percentage) or 0),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Merge \"%1\" into \"%2\"?\n\nThe farthest-along reading position from either copy is kept. Highlights, bookmarks and reading stats are combined. Future syncs from either copy update this book."), b._title, book._title),
                        ok_text = _("Merge"),
                        ok_callback = function()
                            serverAction({
                                { "POST", "/api/v1/documents/merge", { document = b.document, into = book.document, stats = true } },
                            }, T(_("Merged \"%1\" into \"%2\"."), b._title, book._title), _("Could not merge: %1"))
                        end,
                    })
                end,
            }
        end
        for _i, b in ipairs(likely) do add(b) end
        if #likely > 0 and #rest > 0 then items[#items].separator = true end
        for _i, b in ipairs(rest) do add(b) end
        if #items == 0 then items[1] = { text = _("No other books"), select_enabled = false } end
        picker = self:showMenuPage(T(_("Merge into \"%1\""), book._title), items, function() picker = nil end)
    end

    local action_row = {
        { text = _("Merge a duplicate"), callback = mergePicker },
    }
    local dates = book._dates or {}
    local dates_row = {
        {
            text = _("Reading dates"),
            callback = function()
                self:editReadingDates(book.document, book._title, dates.started_at, dates.finished_at, function() finish() end)
            end,
        },
    }
    if #aliases > 0 then
        action_row[#action_row + 1] = {
            text = #aliases == 1 and _("Separate merged copy") or T(_("Separate %1 merged copies"), #aliases),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Separate the merged copies from this book?\n\nFuture syncs from the separated copies will show as their own books."),
                    ok_text = _("Separate"),
                    ok_callback = function()
                        local calls = {}
                        for _i, alias in ipairs(aliases) do
                            calls[#calls + 1] = { "DELETE", "/api/v1/documents/merge/" .. alias, nil, true }
                        end
                        serverAction(calls, _("Merged copies separated."), _("Could not separate: %1"))
                    end,
                })
            end,
        }
    end
    local buttons = {
        dates_row,
        action_row,
        {
            {
                text = _("Remove from library"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Remove \"%1\" from your CrossPoint library?\n\nThis deletes its progress, highlights, bookmarks and reading stats on the server for all devices. It cannot be undone."), book._title),
                        ok_text = _("Remove"),
                        ok_callback = function()
                            serverAction({ { "DELETE", "/api/v1/progress/" .. book.document, nil, true } },
                                T(_("Removed \"%1\" from your CrossPoint library."), book._title), _("Could not remove the book: %1"))
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("Open on this device"),
                enabled = file ~= nil,
                callback = function()
                    UIManager:close(viewer)
                    if close_all then close_all() end
                    UIManager:setDirty("all", "ui")
                    require("apps/reader/readerui"):showReader(file)
                end,
            },
            { text = _("Close"), callback = function() viewer:onClose() end },
        },
    }
    viewer = TextViewer:new{
        title = _("CrossPoint"),
        text = table.concat(lines, "\n"),
        buttons_table = buttons,
        add_default_buttons = false,
        close_callback = function() UIManager:setDirty("all", "ui") end,
    }
    UIManager:show(viewer)
end

function CrossPointSync:previewStartFix(books, titles, all)
    local sum_all, n_all, sum_rows = 0, 0, 0
    for _i, b in ipairs(all or {}) do
        sum_all = sum_all + (tonumber(b.days_to_finish) or 0)
        n_all = n_all + 1
    end
    for _i, b in ipairs(books) do sum_rows = sum_rows + (tonumber(b.days_to_finish) or 0) end
    local avg_now = n_all > 0 and math.floor(sum_all / n_all + 0.5) or 0
    local avg_new = n_all > 0 and math.floor((sum_all - sum_rows + #books) / n_all + 0.5) or 0
    local items = {
        {
            text = T(_("Days per book: %1 now, %2 after"), avg_now, avg_new),
            select_enabled = false,
            bold = true,
            separator = true,
        },
    }
    for _i, b in ipairs(books) do
        local book = titles[b.document]
        local title = book and (book._author ~= "" and (book._title .. " · " .. book._author) or book._title) or b.document
        local started, finished = tonumber(b.started_at), tonumber(b.finished_at)
        items[#items + 1] = {
            text = title,
            mandatory = T(_("%1 → 1 day"), b.days_to_finish),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("%1\n\nNow: %2 – %3 (%4 days)\nAfter: %3 – %3 (1 day)"), title,
                        started and os.date("%d %b %Y", started) or "-",
                        finished and os.date("%d %b %Y", finished) or "-",
                        b.days_to_finish),
                })
            end,
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text = T(_("Set start = finish date for these %1 books"), #books),
        bold = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Set the start date of %1 books to their finish date on the server?\n\nEach then counts as read in 1 day. Finish dates and status stay as they are. You can change any of them later with Reading dates on the website."), #books),
                ok_text = _("Set dates"),
                ok_callback = function()
                    self:onlineOrAsk(function()
                        local failed = 0
                        for _i, b in ipairs(books) do
                            local finished = tonumber(b.finished_at)
                            local code
                            if finished then
                                code = self:request("PUT", "/api/v1/documents/" .. b.document .. "/dates",
                                    { start_date = os.date("%Y-%m-%d", finished) })
                            end
                            if not httpOk(code) then failed = failed + 1 end
                        end
                        self:notify(failed == 0 and T(_("Updated %1 start dates."), #books)
                            or T(_("Updated %1 start dates, %2 failed."), #books - failed, failed))
                    end)
                end,
            })
        end,
    }
    self:showMenuPage(T(_("Preview (%1 books)"), #books), items)
end

function CrossPointSync:showLibrary()
    self:onlineOrAsk(function()
        local books, err = self:fetchLibrary()
        if not books then
            self:notify(T(_("Could not load the library: %1"), tostring(err)))
            return
        end
        local scode, summary = self:request("GET", "/api/v1/stats/summary")
        if not httpOk(scode) or type(summary) ~= "table" then summary = nil end
        local acode, activity = self:request("GET", "/api/v1/stats/activity?tz=" .. tzOffsetMinutes())
        if not httpOk(acode) or type(activity) ~= "table" then activity = nil end

        local groups = { reading = {}, paused = {}, finished = {}, dnf = {}, untitled = {} }
        for _i, b in ipairs(books) do
            local g = b._named and (groups[b.status] or groups.reading) or groups.untitled
            g[#g + 1] = b
        end
        local function ts(b) return tonumber(b.status_at) or tonumber(b.timestamp) or 0 end
        for _k, g in pairs(groups) do table.sort(g, function(a, b) return ts(a) > ts(b) end) end

        local view, list_menu
        local function closeAll()
            if list_menu then UIManager:close(list_menu) end
            if view then UIManager:close(view) end
        end
        local function showList(key)
            local out = {}
            for _i, b in ipairs(groups[key]) do
                out[#out + 1] = {
                    text = b._author ~= "" and (b._title .. " · " .. b._author) or b._title,
                    mandatory = key == "finished" and os.date("%d %b %Y", ts(b))
                        or key == "untitled" and ((STATUS_LABELS[b.status] or STATUS_LABELS.reading) .. " · " .. formatPercent(tonumber(b.percentage) or 0))
                        or formatPercent(tonumber(b.percentage) or 0),
                    callback = function() self:showBookDetails(b, closeAll, books) end,
                }
            end
            if #out == 0 then out[1] = { text = _("No books"), select_enabled = false } end
            list_menu = self:showMenuPage(
                T(_("%1 (%2)"), key == "untitled" and _("No metadata") or STATUS_LABELS[key], #groups[key]),
                out,
                function(page) if list_menu == page then list_menu = nil end end)
        end

        local dates_by_doc = {}
        for _i, b in ipairs(activity and activity.books or {}) do dates_by_doc[b.document] = b end
        for _i, b in ipairs(books) do b._dates = dates_by_doc[b.document] end
        local stats
        if summary or activity then
            local ok, res = pcall(function() return self:libraryStats(books, books._items or {}, summary, activity) end)
            if ok then stats = res else logger.warn("CrossPointSync: stats failed", res) end
        end
        local more_view, longest_page
        local function reloadAll()
            if longest_page then UIManager:close(longest_page) end
            if more_view then UIManager:close(more_view) end
            closeAll()
            UIManager:setDirty("all", "ui")
            self:showLibrary()
        end
        local function showMore()
            local titles = {}
            for _i, b in ipairs(books) do titles[b.document] = b end
            more_view = self:moreStatsView(stats, self:getSetting("dev_mode", false) and function()
                local list = {}
                for _i, b in ipairs(stats.longest or {}) do list[#list + 1] = b end
                table.sort(list, function(a, b) return tonumber(a.days_to_finish) > tonumber(b.days_to_finish) end)
                local out = {}
                for _i, b in ipairs(list) do
                    local book = titles[b.document]
                    local title = book and (book._author ~= "" and (book._title .. " · " .. book._author) or book._title) or b.document
                    local started, finished = tonumber(b.started_at), tonumber(b.finished_at)
                    out[#out + 1] = {
                        text = title,
                        mandatory = T(_("%1 days"), b.days_to_finish),
                        callback = function()
                            local ButtonDialog = require("ui/widget/buttondialog")
                            local info
                            info = ButtonDialog:new{
                                title = T(_("%1\n\nStarted: %2\nFinished: %3\n%4 days"), title,
                                    started and os.date("%d %b %Y", started) or "-",
                                    finished and os.date("%d %b %Y", finished) or "-",
                                    b.days_to_finish),
                                title_align = "left",
                                buttons = {
                                    {
                                        { text = _("Close"), callback = function() UIManager:close(info) end },
                                        {
                                            text = _("Reading dates"),
                                            callback = function()
                                                UIManager:close(info)
                                                self:editReadingDates(b.document, book and book._title or title, b.started_at, b.finished_at, reloadAll)
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(info)
                        end,
                    }
                end
                if #out == 0 then out[1] = { text = _("No books"), select_enabled = false } end
                local placeholders = {}
                for _i, b in ipairs(list) do
                    local started = tonumber(b.started_at)
                    if started and (os.date("%m-%d", started) == "01-01" or os.date("!%m-%d", started) == "01-01")
                            and (tonumber(b.days_to_finish) or 0) >= 60 then
                        placeholders[#placeholders + 1] = b
                    end
                end
                if #placeholders > 0 then
                    table.insert(out, 1, {
                        text = T(_("Preview: books starting 1 January (%1)"), #placeholders),
                        bold = true,
                        separator = true,
                        callback = function()
                            self:previewStartFix(placeholders, titles, list)
                        end,
                    })
                end
                longest_page = self:showMenuPage(T(_("Longest to finish (%1)"), #list), out)
            end or nil)
            UIManager:show(more_view)
        end
        view = self:libraryView(groups, stats, showList, showMore)
        UIManager:show(view)
    end)
end

local DAY = 86400

local function dayKey(t) return os.date("%Y-%m-%d", t) end

local function keyTime(key)
    local y, m, d = tostring(key):match("^(%d+)-(%d+)-(%d+)$")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

local function todayNoon()
    local t = os.date("*t")
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 12 }
end

local function formatHM(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return T(_("%1h %2m"), h, m) end
    return T(_("%1m"), m)
end

local function shadeLevels(map, fallback)
    local cutoff = dayKey(os.time() - 90 * DAY)
    local values = {}
    for key, v in pairs(map) do
        if key > cutoff and type(v) == "number" and v > 0 then values[#values + 1] = v end
    end
    table.sort(values)
    local n = #values
    local median = 0
    if n > 0 then
        median = n % 2 == 1 and values[(n + 1) / 2] or (values[n / 2] + values[n / 2 + 1]) / 2
    end
    local baseline = (14 * fallback + n * median) / (14 + n)
    return function(amount)
        if amount == nil then return 2 end
        local r = amount / baseline
        return r < 0.5 and 1 or r < 1.25 and 2 or r < 2 and 3 or 4
    end
end

function CrossPointSync:libraryStats(books, items, summary, activity)
    summary = type(summary) == "table" and summary or {}
    activity = type(activity) == "table" and activity or {}
    local known_docs = {}
    for _i, it in ipairs(items) do
        if (type(it.title) == "string" and it.title ~= "") or (type(it.filename) == "string" and it.filename ~= "") then
            known_docs[it.document] = true
        end
    end

    local shown = {}
    for _i, b in ipairs(activity.books or {}) do
        if known_docs[b.document] then shown[#shown + 1] = b end
    end
    local year = os.date("%Y")
    local pages_total, finished, finished_year, page_sum, page_known, spans = 0, 0, 0, 0, 0, {}
    local longest_list = {}
    for _i, b in ipairs(shown) do
        pages_total = pages_total + (tonumber(b.pages_read) or 0)
        if b.completed or tonumber(b.finished_at) then
            finished = finished + 1
            if tonumber(b.finished_at) and os.date("%Y", tonumber(b.finished_at)) == year then
                finished_year = finished_year + 1
            end
            if tonumber(b.days_to_finish) and tonumber(b.days_to_finish) > 0 then
                spans[#spans + 1] = tonumber(b.days_to_finish)
                longest_list[#longest_list + 1] = b
            end
        end
        if tonumber(b.page_count) and tonumber(b.page_count) > 0 then
            page_sum = page_sum + tonumber(b.page_count)
            page_known = page_known + 1
        end
    end
    local span_sum = 0
    for _i, v in ipairs(spans) do span_sum = span_sum + v end
    local reading_now, finished_status = 0, 0
    for _i, b in ipairs(books) do
        if b._named then
            if b.status == "reading" then reading_now = reading_now + 1 end
            if b.status == "finished" then finished_status = finished_status + 1 end
        end
    end

    local read = {}
    local bytes = summary.history_b64 and mime.unb64(summary.history_b64) or ""
    local anchor = tonumber(summary.anchor_day)
    if anchor and anchor > 0 and bytes and #bytes > 0 then
        local base = 946684800 + anchor * DAY + 12 * 3600
        for n = 0, #bytes * 8 - 1 do
            local byte = bytes:byte(math.floor(n / 8) + 1)
            if math.floor(byte / 2 ^ (n % 8)) % 2 == 1 then
                read[os.date("!%Y-%m-%d", base - n * DAY)] = true
            end
        end
    end
    for _i, day in ipairs(activity.reading_days or {}) do read[day] = true end

    local today = todayNoon()
    local today_key = dayKey(today)
    local t = read[today_key] and today or today - DAY
    local streak = 0
    while read[dayKey(t)] do
        streak = streak + 1
        t = t - DAY
    end
    local keys = {}
    for key in pairs(read) do if key <= today_key then keys[#keys + 1] = key end end
    table.sort(keys)
    local longest, run, prev = 0, 0, nil
    for _i, key in ipairs(keys) do
        local kt = keyTime(key)
        run = (prev and kt and math.floor((kt - prev) / DAY + 0.5) == 1) and run + 1 or 1
        if run > longest then longest = run end
        prev = kt
    end

    local pages_by_day = {}
    for _i, d in ipairs(activity.days or {}) do
        if (tonumber(d.syncs) or 0) > 0 or (tonumber(d.pages) or 0) > 0 then
            pages_by_day[d.day] = tonumber(d.pages) or 0
        end
    end
    local time_by_day = {}
    local daily = {}
    for _i, d in ipairs(summary.daily or {}) do daily[d.date] = tonumber(d.seconds) end
    for key in pairs(read) do time_by_day[key] = daily[key] or false end
    for key, s in pairs(daily) do if s and s > 0 then time_by_day[key] = s end end
    local page_level = shadeLevels(pages_by_day, 20)
    local plain_time = {}
    for key, s in pairs(time_by_day) do if s then plain_time[key] = s end end
    local time_level = shadeLevels(plain_time, 30 * 60)
    local function level(key)
        local p, s = pages_by_day[key], time_by_day[key]
        if p == nil and s == nil then return 0 end
        if p and p > 0 then return page_level(p) end
        if s then return time_level(s) end
        return 2
    end

    local monday = today - ((tonumber(os.date("%w", today)) + 6) % 7) * DAY
    local weekly = {}
    for i = 1, 12 do
        local start = monday - (12 - i) * 7 * DAY
        local pages = 0
        for d = 0, 6 do pages = pages + (pages_by_day[dayKey(start + d * DAY)] or 0) end
        weekly[i] = { start = start, pages = math.floor(pages + 0.5) }
    end

    local cal_first = monday - 52 * 7 * DAY
    local cal_days = 0
    for d = 0, 52 * 7 + 6 do
        local dt = cal_first + d * DAY
        if dt <= today and level(dayKey(dt)) > 0 then cal_days = cal_days + 1 end
    end

    local tod, dow = {}, {}
    for i = 1, 4 do tod[i] = tonumber((summary.tod or {})[i]) or 0 end
    for i = 1, 7 do dow[i] = tonumber((summary.dow or {})[i]) or 0 end

    return {
        pages = {
            { groupThousands(pages_total), _("Pages read") },
            { groupThousands(finished), _("Books finished") },
            { groupThousands(reading_now), _("Reading now") },
            { groupThousands(finished_year), _("Finished this year") },
            { page_known > 0 and groupThousands(page_sum / page_known + 0.5) or "-", _("Pages per book") },
            { #spans > 0 and groupThousands(span_sum / #spans + 0.5) or "-", _("Days per book") },
        },
        time = {
            { T(_("%1 days"), streak), _("Current streak") },
            { T(_("%1 days"), longest), _("Longest streak") },
            { formatHM(summary.seconds), _("Time read") },
            { groupThousands(summary.pages), _("Pages turned") },
            { groupThousands(summary.sessions), _("Sessions") },
            { groupThousands(finished_status), _("Books finished") },
        },
        weekly = weekly,
        longest = longest_list,
        calendar = { first = cal_first, today = today, level = level, days = cal_days },
        tod = tod,
        dow = dow,
    }
end

local function uiKit()
    return {
        Blitbuffer = require("ffi/blitbuffer"),
        ButtonTable = require("ui/widget/buttontable"),
        CenterContainer = require("ui/widget/container/centercontainer"),
        Font = require("ui/font"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        HorizontalGroup = require("ui/widget/horizontalgroup"),
        HorizontalSpan = require("ui/widget/horizontalspan"),
        InputContainer = require("ui/widget/container/inputcontainer"),
        LeftContainer = require("ui/widget/container/leftcontainer"),
        LineWidget = require("ui/widget/linewidget"),
        OverlapGroup = require("ui/widget/overlapgroup"),
        RightContainer = require("ui/widget/container/rightcontainer"),
        Size = require("ui/size"),
        TextWidget = require("ui/widget/textwidget"),
        TitleBar = require("ui/widget/titlebar"),
        VerticalGroup = require("ui/widget/verticalgroup"),
        VerticalSpan = require("ui/widget/verticalspan"),
    }
end

local function fullscreenPage(K, title, build)
    local Screen = Device.screen
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local view = K.InputContainer:new{ covers_fullscreen = true }
    if Device:hasKeys() then
        view.key_events.Close = { { Device.input.group.Back } }
    end
    function view:onClose()
        UIManager:close(self)
        UIManager:setDirty("all", "ui")
        return true
    end
    local title_bar = K.TitleBar:new{
        width = sw,
        title = title,
        with_bottom_line = true,
        close_callback = function() view:onClose() end,
        show_parent = view,
    }
    local content = K.VerticalGroup:new{ align = "center", title_bar }
    build(content, view, sw, sh - title_bar:getSize().h)
    view[1] = K.FrameContainer:new{
        width = sw,
        height = sh,
        padding = 0,
        bordersize = 0,
        background = K.Blitbuffer.COLOR_WHITE,
        content,
    }
    view.dimen = K.Geom:new{ x = 0, y = 0, w = sw, h = sh }
    return view
end

local function sectionHeader(K, text, width)
    return K.LeftContainer:new{
        dimen = K.Geom:new{ w = width, h = K.Font:getFace("tfont", 18).size * 1.6 },
        K.TextWidget:new{ text = text, face = K.Font:getFace("tfont", 18), bold = true },
    }
end

local function tileGrid(K, tiles, width, tile_h)
    local Screen = Device.screen
    local cols, gap = 3, Screen:scaleBySize(8)
    local tile_w = math.floor((width - (cols - 1) * gap) / cols)
    local value_face = K.Font:getFace("cfont", 22)
    local label_face = K.Font:getFace("xx_smallinfofont")
    local border = K.Size.border.thin
    local text_w = tile_w - 2 * (K.Size.padding.default + border)
    local grid = K.VerticalGroup:new{ align = "left" }
    for r = 1, math.ceil(#tiles / cols) do
        local row = K.HorizontalGroup:new{ align = "top" }
        for c = 1, cols do
            local t = tiles[(r - 1) * cols + c]
            if c > 1 then row[#row + 1] = K.HorizontalSpan:new{ width = gap } end
            if t then
                row[#row + 1] = K.FrameContainer:new{
                    bordersize = border,
                    radius = K.Size.radius.window,
                    padding = 0,
                    background = K.Blitbuffer.COLOR_WHITE,
                    K.CenterContainer:new{
                        dimen = K.Geom:new{ w = tile_w - 2 * border, h = tile_h - 2 * border },
                        K.VerticalGroup:new{
                            align = "center",
                            K.TextWidget:new{ text = t[1], face = value_face, bold = true, max_width = text_w },
                            K.TextWidget:new{ text = t[2], face = label_face, max_width = text_w,
                                fgcolor = K.Blitbuffer.COLOR_DARK_GRAY },
                        },
                    },
                }
            else
                row[#row + 1] = K.HorizontalSpan:new{ width = tile_w }
            end
        end
        if r > 1 then grid[#grid + 1] = K.VerticalSpan:new{ width = gap } end
        grid[#grid + 1] = row
    end
    return grid
end

function CrossPointSync:libraryView(groups, stats, on_status, on_more)
    local K = uiKit()
    local Screen = Device.screen
    return fullscreenPage(K, _("CrossPoint Library"), function(content, view, sw, avail)
        local pad = K.Size.padding.large
        local gap = Screen:scaleBySize(8)
        local section_gap = Screen:scaleBySize(24)
        local inner_w = sw - 2 * pad

        local function statusButton(key)
            return {
                text = T(_("%1  %2"), STATUS_LABELS[key], #groups[key]),
                callback = function() on_status(key) end,
            }
        end
        local rows = {
            { statusButton("reading"), statusButton("paused") },
            { statusButton("finished"), statusButton("dnf") },
        }
        local last = {}
        if #groups.untitled > 0 then
            last[#last + 1] = {
                text = T(_("No metadata  %1"), #groups.untitled),
                callback = function() on_status("untitled") end,
            }
        end
        if stats then last[#last + 1] = { text = _("More stats"), callback = on_more } end
        if #last > 0 then rows[#rows + 1] = last end
        local buttons = K.ButtonTable:new{ width = inner_w, buttons = rows, zero_sep = true, show_parent = view }

        if stats then
            local header_h = sectionHeader(K, "x", inner_w):getSize().h
            local used = 2 * header_h + buttons:getSize().h + section_gap * 2 + pad * 2 + 2 * gap
            local tile_w = math.floor((inner_w - 2 * gap) / 3)
            local tile_h = math.max(Screen:scaleBySize(50), math.min(math.floor(tile_w * 0.5), math.floor((avail - used) / 4)))
            content[#content + 1] = K.VerticalSpan:new{ width = pad }
            content[#content + 1] = sectionHeader(K, _("Pages & books"), inner_w)
            content[#content + 1] = tileGrid(K, stats.pages, inner_w, tile_h)
            content[#content + 1] = K.VerticalSpan:new{ width = section_gap }
            content[#content + 1] = sectionHeader(K, _("Reading time"), inner_w)
            content[#content + 1] = tileGrid(K, stats.time, inner_w, tile_h)
            content[#content + 1] = K.VerticalSpan:new{ width = section_gap }
        else
            content[#content + 1] = K.VerticalSpan:new{ width = pad }
        end
        content[#content + 1] = buttons
        content[#content + 1] = K.LineWidget:new{
            background = K.Blitbuffer.COLOR_GRAY,
            dimen = K.Geom:new{ w = inner_w, h = K.Size.line.medium },
        }
    end)
end

local SHADES = { 0xE6, 0xBB, 0x8C, 0x5A, 0x22 }

function CrossPointSync:moreStatsView(stats, on_longest)
    local K = uiKit()
    local Screen = Device.screen
    return fullscreenPage(K, _("More stats"), function(content, view, sw, avail)
        local pad = K.Size.padding.large
        local inner_w = sw - 2 * pad
        local small = K.Font:getFace("xx_smallinfofont")
        local tiny = K.Font:getFace("infont", 12)
        local gray = K.Blitbuffer.COLOR_DARK_GRAY
        local section_gap = Screen:scaleBySize(14)
        local function shade(v) return K.Blitbuffer.Color8(v) end
        local function box(w, h, v)
            return K.LineWidget:new{ dimen = K.Geom:new{ w = math.max(0, math.floor(w)), h = math.max(0, math.floor(h)) }, background = shade(v) }
        end
        local header_h = sectionHeader(K, "x", inner_w):getSize().h
        local text_h = K.TextWidget:new{ text = "0", face = small }:getSize().h
        local tiny_h = K.TextWidget:new{ text = "0", face = tiny }:getSize().h

        local cal_gap = math.max(1, Screen:scaleBySize(2))
        local label_w = K.TextWidget:new{ text = "M", face = tiny }:getSize().w + Screen:scaleBySize(6)
        local cell = math.floor((inner_w - label_w - 52 * cal_gap) / 53)
        local cal_h = 7 * cell + 6 * cal_gap + tiny_h + tiny_h
        local bar_row_h = math.max(text_h, Screen:scaleBySize(20))
        local bars_h = 7 * bar_row_h
        local fixed = pad + 4 * header_h + 3 * section_gap + cal_h + bars_h + pad
        local chart_h = math.max(Screen:scaleBySize(60), math.min(Screen:scaleBySize(220), avail - fixed - 2 * tiny_h))

        content[#content + 1] = K.VerticalSpan:new{ width = pad }

        content[#content + 1] = sectionHeader(K, _("Pages per week"), inner_w)
        local max_pages = 1
        for _i, w in ipairs(stats.weekly) do if w.pages > max_pages then max_pages = w.pages end end
        local wgap = Screen:scaleBySize(6)
        local col_w = math.floor((inner_w - 11 * wgap) / 12)
        local chart = K.HorizontalGroup:new{ align = "bottom" }
        local months = K.HorizontalGroup:new{ align = "top" }
        local prev_month
        for i, w in ipairs(stats.weekly) do
            if i > 1 then
                chart[#chart + 1] = K.HorizontalSpan:new{ width = wgap }
                months[#months + 1] = K.HorizontalSpan:new{ width = wgap }
            end
            local bar_h = w.pages > 0 and math.max(2, math.floor(w.pages / max_pages * (chart_h - tiny_h))) or 1
            chart[#chart + 1] = K.VerticalGroup:new{
                align = "center",
                w.pages > 0 and K.TextWidget:new{ text = tostring(w.pages), face = tiny, fgcolor = gray, max_width = col_w + wgap } or K.VerticalSpan:new{ width = 0 },
                K.CenterContainer:new{ dimen = K.Geom:new{ w = col_w, h = bar_h }, box(col_w, bar_h, w.pages > 0 and 0x55 or 0xCC) },
            }
            local month = os.date("%b", w.start)
            months[#months + 1] = K.LeftContainer:new{
                dimen = K.Geom:new{ w = col_w, h = tiny_h },
                month ~= prev_month and K.TextWidget:new{ text = month, face = tiny, fgcolor = gray } or K.VerticalSpan:new{ width = 0 },
            }
            prev_month = month
        end
        content[#content + 1] = K.VerticalGroup:new{
            align = "left",
            K.VerticalSpan:new{ width = math.max(0, chart_h - chart:getSize().h) },
            chart,
        }
        content[#content + 1] = months
        content[#content + 1] = K.VerticalSpan:new{ width = section_gap }

        local cal = stats.calendar
        content[#content + 1] = sectionHeader(K, T(_("Reading days · %1"), T(_("%1 days"), cal.days)), inner_w)
        local grid = K.HorizontalGroup:new{ align = "top" }
        local wd = { _("M"), "", _("W"), "", _("F"), "", _("S") }
        local labels = K.VerticalGroup:new{ align = "left" }
        for r = 1, 7 do
            if r > 1 then labels[#labels + 1] = K.VerticalSpan:new{ width = cal_gap } end
            labels[#labels + 1] = K.LeftContainer:new{ dimen = K.Geom:new{ w = label_w, h = cell },
                K.TextWidget:new{ text = wd[r], face = tiny, fgcolor = gray } }
        end
        grid[#grid + 1] = labels
        local cal_months = K.HorizontalGroup:new{ align = "top", K.HorizontalSpan:new{ width = label_w } }
        prev_month = nil
        local skip = 0
        for wk = 0, 52 do
            if wk > 0 then grid[#grid + 1] = K.HorizontalSpan:new{ width = cal_gap } end
            local col = K.VerticalGroup:new{ align = "left" }
            for r = 0, 6 do
                if r > 0 then col[#col + 1] = K.VerticalSpan:new{ width = cal_gap } end
                local dt = cal.first + (wk * 7 + r) * DAY
                if dt > cal.today then
                    col[#col + 1] = K.VerticalSpan:new{ width = cell }
                else
                    col[#col + 1] = box(cell, cell, SHADES[cal.level(dayKey(dt)) + 1])
                end
            end
            grid[#grid + 1] = col
            local month = os.date("%b", cal.first + wk * 7 * DAY)
            if wk > 0 then cal_months[#cal_months + 1] = K.HorizontalSpan:new{ width = cal_gap } end
            if wk > 0 and month ~= prev_month and skip <= 0 then
                local tw = K.TextWidget:new{ text = month, face = tiny, fgcolor = gray }
                local span = math.ceil(tw:getSize().w / (cell + cal_gap))
                cal_months[#cal_months + 1] = K.LeftContainer:new{ dimen = K.Geom:new{ w = cell, h = tiny_h }, tw }
                skip = span
            else
                cal_months[#cal_months + 1] = K.HorizontalSpan:new{ width = cell }
            end
            skip = skip - 1
            prev_month = month
        end
        content[#content + 1] = grid
        content[#content + 1] = K.VerticalSpan:new{ width = cal_gap * 2 }
        content[#content + 1] = K.LeftContainer:new{ dimen = K.Geom:new{ w = inner_w, h = tiny_h }, cal_months }
        content[#content + 1] = K.VerticalSpan:new{ width = section_gap }

        local half_gap = Screen:scaleBySize(16)
        local half_w = math.floor((inner_w - half_gap) / 2)
        local function bars(title, labels_, values)
            local max_v = 1
            for _i, v in ipairs(values) do if v > max_v then max_v = v end end
            local lw, vw = 0, 0
            for i, l in ipairs(labels_) do
                lw = math.max(lw, K.TextWidget:new{ text = l, face = small }:getSize().w)
                vw = math.max(vw, K.TextWidget:new{ text = formatHM(values[i]), face = small }:getSize().w)
            end
            lw, vw = lw + Screen:scaleBySize(8), vw + Screen:scaleBySize(6)
            local track_w = half_w - lw - vw
            local track_h = math.max(4, math.floor(bar_row_h * 0.4))
            local group = K.VerticalGroup:new{ align = "left", sectionHeader(K, title, half_w) }
            for i, l in ipairs(labels_) do
                local fill = math.floor(values[i] / max_v * track_w)
                group[#group + 1] = K.HorizontalGroup:new{
                    align = "center",
                    K.LeftContainer:new{ dimen = K.Geom:new{ w = lw, h = bar_row_h }, K.TextWidget:new{ text = l, face = small, fgcolor = gray } },
                    K.OverlapGroup:new{
                        dimen = K.Geom:new{ w = track_w, h = track_h },
                        box(track_w, track_h, 0xE0),
                        box(fill, track_h, 0x55),
                    },
                    K.RightContainer:new{ dimen = K.Geom:new{ w = vw, h = bar_row_h }, K.TextWidget:new{ text = formatHM(values[i]), face = small } },
                }
            end
            return group
        end
        content[#content + 1] = K.HorizontalGroup:new{
            align = "top",
            bars(_("Time of day"), { _("Morning"), _("Afternoon"), _("Evening"), _("Night") }, stats.tod),
            K.HorizontalSpan:new{ width = half_gap },
            bars(_("Day of week"), { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") }, stats.dow),
        }
        if on_longest then
            content[#content + 1] = K.VerticalSpan:new{ width = section_gap }
            content[#content + 1] = K.ButtonTable:new{
                width = inner_w,
                buttons = { { { text = _("Longest to finish"), callback = on_longest } } },
                zero_sep = true,
                show_parent = view,
            }
            content[#content + 1] = K.LineWidget:new{
                background = K.Blitbuffer.COLOR_GRAY,
                dimen = K.Geom:new{ w = inner_w, h = K.Size.line.medium },
            }
        end
    end)
end

function CrossPointSync:registerFileDialogButtons()
    if not self.ui or not self.ui.file_chooser then return end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or type(FileManager) ~= "table" or not FileManager.addFileDialogButtons then return end
    local DocumentRegistry = require("document/documentregistry")

    local function button(text, what)
        return {
            text = text,
            callback = function()
                local plugin = CrossPointSync.instance
                if not plugin then return end
                local fm = plugin.ui
                if fm and fm.file_dialog then UIManager:close(fm.file_dialog) end
                local file = plugin.dialog_file
                if file then plugin:bookAction(file, what) end
            end,
        }
    end
    local function row(id, first, second)
        FileManager:addFileDialogButtons(id, function(file, is_file)
            if not is_file or not DocumentRegistry:hasProvider(file) then return nil end
            local plugin = CrossPointSync.instance
            if plugin then plugin.dialog_file = file end
            return { button(first[1], first[2]), button(second[1], second[2]) }
        end)
    end
    pcall(row, "crosspointsync_1", { _("CrossPoint: progress"), "progress" }, { _("CrossPoint: highlights"), "annotations" })
    pcall(row, "crosspointsync_2", { _("CrossPoint: book info"), "info" }, { _("CrossPoint: reading stats"), "stats" })
end

function CrossPointSync:onReaderReady()
    self.cur = { last = os.time(), last_page = nil, session_counted = false }
    if self:getSetting("auto_pull", true) and self:isConfigured() and NetworkMgr:isConnected() then
        UIManager:scheduleIn(1.5, function()
            if self.ui.document then
                pcall(function() self:syncProgress(self:readerContext(), "smart", true) end)
            end
        end)
    end
end

function CrossPointSync:onPageUpdate(pageno)
    if not self.ui.document then return end
    pcall(function() self:statsOnPage(pageno) end)
    if self:getSetting("auto_push", true) and self:getSetting("push_while_reading", false) then
        if self.push_scheduled then UIManager:unschedule(self._push_fn) end
        self._push_fn = self._push_fn or function()
            self.push_scheduled = false
            self:autoPush()
        end
        self.push_scheduled = true
        UIManager:scheduleIn(self:tunable("push_delay"), self._push_fn)
    end
end

function CrossPointSync:onCloseDocument()
    if self.push_scheduled and self._push_fn then
        UIManager:unschedule(self._push_fn)
        self.push_scheduled = false
    end
    if not self.ui.document then return end
    pcall(function() self:statsEnd() end)
    pcall(function() self:flushStats() end)
    if not self:isConfigured() then return end
    local push = self:wantsAutoPush()
    local function work()
        if push then
            pcall(function() self:syncProgress(self:readerContext(), "push", true) end)
        end
        pcall(function()
            local ctx = self:readerContext()
            if ctx then self:syncKoreaderStatus(ctx) end
        end)
        if self:getSetting("send_stats", true) then
            pcall(function()
                local ctx = self:readerContext()
                self:uploadStats(nil, ctx and ctx.hashes.binary or "")
            end)
        end
    end
    if push then
        self:runOnlineBlocking(work)
    elseif NetworkMgr:isConnected() then
        work()
    end
end

function CrossPointSync:onSuspend()
    pcall(function() self:statsEnd() end)
    pcall(function() self:flushStats() end)
    if self:wantsAutoPush() then
        self:runOnlineBlocking(function()
            self:syncProgress(self:readerContext(), "push", true)
        end)
    end
end

function CrossPointSync:onResume()
    if self.cur then self.cur.last = os.time() end
end

function CrossPointSync:onCrossPointPush()
    self:onlineOrAsk(function() self:syncProgress(self:readerContext(), "push") end)
    return true
end

function CrossPointSync:onCrossPointPull()
    self:onlineOrAsk(function() self:syncProgress(self:readerContext(), "pull") end)
    return true
end

function CrossPointSync:onCrossPointSyncAll()
    self:syncAll()
    return true
end

function CrossPointSync:onCrossPointShowLibrary()
    self:showLibrary()
    return true
end

function CrossPointSync:onCrossPointSyncAllAnnotations()
    self:syncAllAnnotations()
    return true
end

function CrossPointSync:onCrossPointPushAllBooks()
    if self.ui.document then
        self:notify(_("Close the book first; \"push all books\" runs from the file manager."))
    else
        self:pushAllBooks()
    end
    return true
end

function CrossPointSync:editServer()
    local dialog
    local function normalizedUrl(raw)
        local url = util.trim(raw or "")
        if url == "" then return nil end
        if not url:match("^https?://") then url = "https://" .. url end
        return (url:gsub("/+$", ""))
    end
    dialog = MultiInputDialog:new{
        title = _("CrossPoint sync account"),
        fields = {
            { text = self:getSetting("server", ""), hint = _("Server URL (required)") },
            { text = self:getSetting("username", ""), hint = _("Username (required)") },
            { text = "", hint = self:getSetting("password_md5", "") ~= "" and _("Password (leave empty to keep)") or _("Password (required)"),
              text_type = "password" },
            { text = self:getSetting("device_name", "KOReader"), hint = _("Device name") },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Apply"), callback = function()
                    local f = dialog:getFields()
                    local url = normalizedUrl(f[1])
                    local user = util.trim(f[2] or "")
                    local have_pw = (f[3] and f[3] ~= "") or self:getSetting("password_md5", "") ~= ""
                    if not url or user == "" or not have_pw then
                        self:notify(_("Server, username and password are all required."))
                        return
                    end
                    self:setSetting("server", url)
                    self:setSetting("username", user)
                    if f[3] and f[3] ~= "" then self:setSetting("password_md5", sha2.md5(f[3])) end
                    local dn = util.trim(f[4] or "")
                    self:setSetting("device_name", dn ~= "" and dn or "KOReader")
                    UIManager:close(dialog)
                end },
            },
            {
                { text = _("Register"), callback = function()
                    local f = dialog:getFields()
                    local url = normalizedUrl(f[1])
                    local user, pw = util.trim(f[2] or ""), f[3] or ""
                    if not url or user == "" or pw == "" then
                        self:notify(_("Enter server, username and password first."))
                        return
                    end
                    self:setSetting("server", url)
                    self:withNetwork(function()
                        local code, data, err = self:request("POST", "/users/create",
                            { username = user, password = sha2.md5(pw) }, false)
                        if httpOk(code) then
                            self:notify(_("Account created. Press Apply to use it."))
                        else
                            self:notify(T(_("Registration failed: %1"),
                                err or (type(data) == "table" and data.message) or tostring(code)))
                        end
                    end)
                end },
                { text = _("Test login"), callback = function()
                    local f = dialog:getFields()
                    local url = normalizedUrl(f[1])
                    local user, pw = util.trim(f[2] or ""), f[3] or ""
                    local key = pw ~= "" and sha2.md5(pw) or self:getSetting("password_md5", "")
                    if not url or user == "" or key == "" then
                        self:notify(_("Enter server, username and password first."))
                        return
                    end
                    self:setSetting("server", url)
                    self:withNetwork(function()
                        local saved_u, saved_k = self:getSetting("username", ""), self:getSetting("password_md5", "")
                        self.settings:saveSetting("username", user)
                        self.settings:saveSetting("password_md5", key)
                        local code, _d, err = self:request("GET", "/users/auth")
                        self.settings:saveSetting("username", saved_u)
                        self.settings:saveSetting("password_md5", saved_k)
                        self:notify(httpOk(code) and _("Login OK.") or T(_("Login failed: %1"), err or tostring(code)))
                    end)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CrossPointSync:toggleItem(text, key, default, help)
    return {
        text = text,
        help_text = help,
        checked_func = function() return self:getSetting(key, default) end,
        callback = function() self:setSetting(key, not self:getSetting(key, default)) end,
    }
end

function CrossPointSync:numberItem(text, key, unit, help)
    local t = TUNABLES[key]
    return {
        text_func = function() return T(_("%1: %2 %3"), text, self:tunable(key), unit) end,
        help_text = help,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = text,
                info_text = help,
                value = self:tunable(key),
                value_min = t.min,
                value_max = t.max,
                value_step = t.step,
                value_hold_step = t.step * 5,
                default_value = t.default,
                unit = unit,
                ok_text = _("Set"),
                callback = function(spin)
                    self:setSetting(key, spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

function CrossPointSync:radioItems(key, default, options)
    local items = {}
    for _i, o in ipairs(options) do
        items[#items + 1] = {
            text = o[2],
            checked_func = function() return self:getSetting(key, default) == o[1] end,
            callback = function() self:setSetting(key, o[1]) end,
        }
    end
    return items
end

function CrossPointSync:statusMenu()
    local items = {}
    local function item(label, value)
        items[#items + 1] = {
            text = label,
            callback = function()
                self:onlineOrAsk(function()
                    local ctx = self:readerContext()
                    local ok, err = self:setReadingStatus(ctx, value)
                    self:notify(ok and (value and T(_("Status set to %1."), STATUS_LABELS[value])
                        or _("Status is derived from the progress again."))
                        or T(_("Failed: %1"), tostring(err)))
                end)
            end,
        }
    end
    item(_("Automatic"), nil)
    for _i, key in ipairs{ "reading", "paused", "finished", "dnf" } do item(STATUS_LABELS[key], key) end
    return items
end

function CrossPointSync:pushStatusMenu()
    local items = {}
    for _i, o in ipairs(PUSH_STATUSES) do
        local key = o[1]
        items[#items + 1] = {
            text = o[2],
            keep_menu_open = true,
            checked_func = function() return self:pushStatusEnabled(key) end,
            callback = function()
                local enabled = util.tableDeepCopy(self:getSetting("push_statuses", {}))
                enabled[key] = not self:pushStatusEnabled(key)
                self:setSetting("push_statuses", enabled)
            end,
        }
    end
    return items
end

function CrossPointSync:settingsMenu()
    return {
        {
            text = _("Account & server"),
            keep_menu_open = true,
            callback = function() self:editServer() end,
            separator = true,
        },
        {
            text = _("Document match method"),
            sub_item_table = self:radioItems("match", "filename", {
                { "filename", _("Filename (CrossPoint default)") },
                { "binary", _("Binary (partial MD5)") },
            }),
        },
        {
            text = _("Same title and author under another file name"),
            sub_item_table = self:radioItems("title_match", "missing", {
                { "missing", _("Look for it when there is no progress") },
                { "always", _("Always look for it") },
                { "off", _("Off") },
            }),
        },
        {
            text = _("When remote is ahead"),
            sub_item_table = self:radioItems("pull_mode", "prompt", {
                { "prompt", _("Ask") },
                { "silent", _("Go there automatically") },
                { "never", _("Do nothing") },
            }),
        },
        {
            text = _("Push only books with status"),
            help_text = _("Automatic pushes and \"Push all books\" only send books whose KOReader status is checked here. Started books without a status count as Reading."),
            sub_item_table_func = function() return self:pushStatusMenu() end,
        },
        self:toggleItem(_("Check progress when opening a book"), "auto_pull", true),
        self:toggleItem(_("Push progress on close / suspend"), "auto_push", true),
        self:toggleItem(_("Also push while reading"), "push_while_reading", false,
            _("Uploads about 20 seconds after the last page turn, if Wi-Fi is already on.")),
        self:toggleItem(_("Also store progress under the other document id"), "write_alias", true,
            _("Lets devices that match by binary hash and devices that match by filename see the same progress.")),
        self:toggleItem(_("Track and send reading stats"), "send_stats", true),
        self:toggleItem(_("Sync historical stats (sync stats from before installation)"), "historical_stats", false,
            _("Also uploads KOReader's own reading statistics (every recorded page and session, including reading done before this plugin was installed). Needs KOReader's Reading statistics plugin. Books already sent are skipped; the server ignores records it already has.")),
        {
            text_func = function() return T(_("Historical stats time zone: %1"), self:historyTimezone()) end,
            enabled_func = function() return self:getSetting("historical_stats", false) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("Time zone (e.g. Europe/Berlin or UTC)"),
                    input = self:getSetting("stats_timezone", ""),
                    input_hint = self:historyTimezone(),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local v = dialog:getInputText():match("^%s*(.-)%s*$")
                                self:setSetting("stats_timezone", v)
                                self:setSetting("hist_sent", {})
                                UIManager:close(dialog)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
        {
            text = _("Timing"),
            sub_item_table = {
                self:numberItem(_("Stats: idle timeout"), "stats_idle", _("seconds"),
                    _("No page turn for this long ends the reading session; time after it is not counted.")),
                self:numberItem(_("Stats: shortest page time for pace"), "stats_min_page", _("seconds"),
                    _("Page turns quicker than this count as skimming and are left out of the pace and ETA. 0 counts every page.")),
                self:numberItem(_("Stats: reading history length"), "stats_history_days", _("days"),
                    _("How many days of reading streak history are sent.")),
                self:numberItem(_("Push delay while reading"), "push_delay", _("seconds"),
                    _("Seconds after the last page turn before progress is uploaded (needs \"Also push while reading\").")),
            },
        },
        self:toggleItem(_("Dev settings"), "dev_mode", false,
            _("Turns on developer tools, such as \"Longest to finish\" in More stats for finding books with wrong start or finish dates.")),
    }
end

function CrossPointSync:buildMenu()
    local items = {
        { text = _("CrossPoint Library"), callback = function() self:showLibrary() end, separator = true },
    }
    local function add(item) items[#items + 1] = item end

    if self.ui.document then
        add{ text = _("Sync everything (this book)"), callback = function() self:syncAll() end }
        add{ text = _("Push progress"), callback = function() self:onCrossPointPush() end }
        add{ text = _("Pull progress"), callback = function() self:onCrossPointPull() end }
        add{
            text = _("Send highlights and bookmarks"),
            callback = function()
                self:onlineOrAsk(function()
                    local ok, msg = self:sendAnnotations(self:readerContext())
                    self:notify(ok and msg or T(_("Failed: %1"), tostring(msg)))
                end)
            end,
        }
        add{
            text = _("Send book info"),
            callback = function()
                self:onlineOrAsk(function()
                    local ok, err = self:uploadDocumentInfo(self:readerContext())
                    self:notify(ok and _("Book info sent.") or T(_("Failed: %1"), tostring(err)))
                end)
            end,
        }
        add{ text = _("Reading status"), sub_item_table_func = function() return self:statusMenu() end }
    else
        add{
            text = _("Push all books"),
            help_text = _("Sends progress, book info, highlights and status of every book in the reading history that has been started. Progress is skipped when the server is further ahead."),
            callback = function() self:pushAllBooks() end,
        }
    end
    add{
        text = _("Sync all highlights and bookmarks"),
        help_text = _("Sends the highlights, notes and bookmarks of every book in the reading history, EPUB and PDF, without opening them."),
        callback = function() self:syncAllAnnotations() end,
    }
    add{
        text = _("Send reading stats"),
        callback = function()
            self:onlineOrAsk(function()
                self:statsEnd()
                self:flushStats()
                local ok, err = self:uploadStats()
                self:notify(ok and _("Reading stats sent.") or T(_("Failed: %1"), tostring(err)))
            end)
        end,
        separator = true,
    }
    add{ text = _("Settings"), sub_item_table_func = function() return self:settingsMenu() end }
    return items
end

function CrossPointSync:addToMainMenu(menu_items)
    menu_items.crosspoint_sync = {
        text = _("CrossPoint Sync"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:buildMenu() end,
    }
end

return CrossPointSync
