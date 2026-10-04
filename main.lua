--[[
CrossPoint Sync for KOReader
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
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
    stats_idle = { default = 30, min = 5, max = 600, step = 5 },         -- timeout without a page turn - maybe fell asleep lol
    stats_min_page = { default = 2, min = 0, max = 30, step = 1 },       -- don't push skimmed pages
    stats_history_days = { default = 730, min = 30, max = 730, step = 30 },
    push_delay = { default = 20, min = 5, max = 300, step = 5 },         -- seconds after the last page turn
}

local STATUS_LABELS = {
    reading = _("Reading"), paused = _("Paused"),
    finished = _("Finished"), dnf = _("Did not finish"),
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
    NetworkMgr:runWhenOnline(callback)
end

function CrossPointSync:onlineOrAsk(callback)
    if not self:isConfigured() then
        self:notify(_("Set the server, username and password first (Tools → CrossPoint Sync → Account & server)."))
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
        if not silent then self:notify(_("Set the server, username and password first (Tools → CrossPoint Sync → Account & server).")) end
        return
    end
    local ids = self:idsFor(ctx)
    local local_p = ctx.progress

    if mode == "push" then
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
    if result == "local" or not same_device then
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

function CrossPointSync:sendAnnotations(ctx)
    if not ctx.rolling then
        return false, _("Highlights can only be sent for reflowable books (EPUB).")
    end
    local annotations = ctx.annotations
    if ctx.open and not annotations then
        return false, _("This KOReader version has no annotation list; please update.")
    end
    annotations = annotations or {}
    local doc = ctx.hashes.filename
    local clippings, bookmarks = {}, {}

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
        return true, _("No highlights or bookmarks in this book.")
    end
    local ok, err = self:chunked("/api/v1/clippings/" .. doc, clippings)
    if not ok then return false, err end
    ok, err = self:chunked("/api/v1/bookmarks/" .. doc, bookmarks)
    if not ok then return false, err end
    return true, T(_("Sent %1 highlight(s) and %2 bookmark(s)."), #clippings, #bookmarks)
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

function CrossPointSync:uploadStats(only_doc)
    local all, send = {}, {}
    for doc, b in pairs(self.stats.books) do
        if b.seconds > 0 or b.completed then
            local snap = self:statsBookSnapshot(doc, b)
            all[#all + 1] = snap
            if not only_doc or only_doc == doc then send[#send + 1] = snap end
        end
    end
    if only_doc and #send == 0 then
        return false, _("No reading stats tracked for this book yet.")
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

        if ctx.rolling then
            local ok2, msg = self:sendAnnotations(ctx)
            lines[#lines + 1] = T(_("Highlights: %1"), tostring(msg))
            if not ok2 then logger.warn("CrossPointSync: annotations", msg) end
        end
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

function CrossPointSync:autoPush()
    if not (self:getSetting("auto_push", true) and self:isConfigured() and self.ui.document) then return end
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
            ok, msg = self:uploadStats(ctx.hashes.filename)
            if ok then msg = _("Reading stats sent.") end
        end
        self:notify(ok and msg or T(_("Failed: %1"), tostring(msg)), ok and 3 or 5)
    end)
end

local function bookStarted(ctx)
    return ctx.progress ~= nil or ctx.status == "reading" or ctx.status == "complete" or ctx.status == "abandoned"
end

function CrossPointSync:pushBookData(file, summary)
    local ctx = self:fileContext(file)
    if not bookStarted(ctx) then
        summary.unread = summary.unread + 1
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
        if remote and (remote.percentage or 0) > ctx.progress.percentage + 0.001
                and remote.device_id ~= self:getSetting("device_id") then
            summary.behind = summary.behind + 1
        else
            track(self:uploadProgress(ctx, ids, ctx.progress))
        end
    end
    track(self:uploadDocumentInfo(ctx))
    if ctx.rolling and ctx.annotations and #ctx.annotations > 0 then
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
    self:onlineOrAsk(function()
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

        local summary = { pushed = 0, unread = 0, behind = 0, failed = 0, fail_streak = 0 }
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
            if summary.behind > 0 then
                lines[#lines + 1] = T(_("%1 book(s): progress not sent, the server is further ahead."), summary.behind)
            end
            if summary.unread > 0 then lines[#lines + 1] = T(_("%1 unread book(s) skipped."), summary.unread) end
            if summary.failed > 0 then lines[#lines + 1] = T(_("%1 book(s) failed."), summary.failed) end
            self:notify(table.concat(lines, "\n"), 8)
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
    self:autoPush()
    if self:isConfigured() and NetworkMgr:isConnected() then
        pcall(function()
            local ctx = self:readerContext()
            if ctx then self:syncKoreaderStatus(ctx) end
        end)
        if self:getSetting("send_stats", true) then pcall(function() self:uploadStats() end) end
    end
end

function CrossPointSync:onSuspend()
    pcall(function() self:statsEnd() end)
    pcall(function() self:flushStats() end)
    if self.ui.document then self:autoPush() end
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

function CrossPointSync:settingsMenu()
    return {
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
        self:toggleItem(_("Check progress when opening a book"), "auto_pull", true),
        self:toggleItem(_("Push progress on close / suspend"), "auto_push", true),
        self:toggleItem(_("Also push while reading"), "push_while_reading", false,
            _("Uploads about 20 seconds after the last page turn, if Wi-Fi is already on.")),
        self:toggleItem(_("Also store progress under the other document id"), "write_alias", true,
            _("Lets devices that match by binary hash and devices that match by filename see the same progress.")),
        self:toggleItem(_("Track and send reading stats"), "send_stats", true),
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
    }
end

function CrossPointSync:buildMenu()
    local items = {
        {
            text = _("Account & server"),
            keep_menu_open = true,
            callback = function() self:editServer() end,
            separator = true,
        },
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
