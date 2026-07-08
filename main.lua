--[[
    notesnook.koplugin/main.lua

    Sends book metadata, cover, stats (from SQLite), and highlights to Notesnook.
    Triggers: 
      - Long-press a book in the File Manager → "Send to Notesnook".
      - Assignable gesture in Reader view.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local UIManager       = require("ui/uimanager")
local DocSettings     = require("docsettings")
local DataStorage     = require("datastorage")
local NetworkMgr      = require("ui/network/manager")
local Dispatcher      = require("dispatcher")
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local SQ3             = require("lua-ljsqlite3/init")
local util            = require("util")
local _               = require("gettext")
local T               = require("ffi/util").template

-- ---------------------------------------------------------------------------
-- Module-level constants
-- ---------------------------------------------------------------------------

local BOOK_EXTENSIONS = {
    epub=true, pdf=true, mobi=true, azw=true, azw3=true, fb2=true,
    cbz=true, cbr=true, djvu=true, txt=true, html=true, htm=true, docx=true,
}

local COLOR_MAP = {
    yellow = "#ffd700",
    green  = "#32cd32",
    blue   = "#1e90ff",
    red    = "#ff4500",
    pink   = "#ff69b4",
    purple = "#da70d6",
    orange = "#ffa500",
}

-- ---------------------------------------------------------------------------
-- Load user config
-- ---------------------------------------------------------------------------

local config_path = DataStorage.getDataDir()
    .. "/plugins/notesnook.koplugin/notesnook_config.lua"
local ok, cfg = pcall(dofile, config_path)
if not ok then
    local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
    ok, cfg = pcall(dofile, plugin_dir .. "notesnook_config.lua")
end
if not ok or type(cfg) ~= "table" then
    cfg = { api_key = "", notebook_id = "", tag_ids = {},
            confirm_before_send = true, favorite = false, readonly = false }
    logger.warn("Notesnook: config not found or invalid; using defaults.")
end

-- ---------------------------------------------------------------------------
-- Plugin class
-- ---------------------------------------------------------------------------

local Notesnook = WidgetContainer:extend{
    name = "notesnook",
}

-- ---------------------------------------------------------------------------
-- Utilities & Extraction
-- ---------------------------------------------------------------------------

local function htmlEscape(s)
    if not s then return "" end
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function stripHtml(s)
    if not s then return "" end
    return (s:gsub("<[^>]+>", ""))
end

local function shellEscape(str)
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

local function formatDuration(seconds)
    if not seconds or seconds == 0 then return "0m" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

local function formatDurationCompact(seconds)
    if not seconds or seconds <= 0 then return "0m" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    else
        return string.format("%dm", minutes)
    end
end

local function formatAvgPageTime(seconds)
     if not seconds or seconds == 0 then return "0s" end
     local m = math.floor(seconds / 60)
     local s = math.floor(seconds % 60)
     if m > 0 then return string.format("%dm %ds", m, s) end
     return string.format("%ds", s)
end

local function formatDate(iso_date)
    local year, month, day = iso_date:match("(%d+)-(%d+)-(%d+)")
    if year and month and day then
        -- Convert to a time table to leverage os.date's locale-aware or standard formatting
        local time_table = {
            year = tonumber(year),
            month = tonumber(month),
            day = tonumber(day),
            hour = 12 -- midday to avoid any potential timezone/DST shifting issues
        }
        local ts = os.time(time_table)
        if ts then
            return os.date("%d %b %Y", ts) -- e.g., "03 Jun 2026"
        end
    end
    return iso_date
end

local function formatProgressDelta(delta)
    local value = tonumber(delta) or 0
    return string.format("%+.1f%%", value * 100)
end

local function formatProgressTotal(progress)
    local value = tonumber(progress) or 0
    return string.format("%.1f%%", value * 100)
end

local function formatSpeed(pages, duration)
    if not pages or pages < 3 or not duration or duration < 120 then
        return "-"
    end
    local pph = (pages * 3600) / duration
    return string.format("%.0f", pph)
end

local function formatRange(first_page, last_page, max_page)
    if first_page == nil and last_page == nil then return "-" end
    first_page = tonumber(first_page)
    last_page = tonumber(last_page)
    max_page = tonumber(max_page)
    if max_page and max_page > 0 then
        if first_page then first_page = math.min(first_page, max_page) end
        if last_page then last_page = math.min(last_page, max_page) end
    end
    if first_page and last_page then
        if first_page == last_page then return tostring(first_page) end
        return string.format("%d-%d", first_page, last_page)
    elseif first_page then return tostring(first_page)
    elseif last_page then return tostring(last_page) end
    return "-"
end

local function extractEpubCover(epub_path)
    if not epub_path:lower():match("%.epub$") then return nil end
    local safe_epub = shellEscape(epub_path)
    
    local p = io.popen('unzip -l ' .. safe_epub .. ' 2>/dev/null')
    if not p then return nil end
    
    local opf_path
    local image_files = {}
    
    for line in p:lines() do
        local file = line:match("%d%d:%d%d%s+(.+)$")
        if file then
            local lf = file:lower()
            if lf:match("%.opf$") then
                opf_path = file
            elseif lf:match("%.jpg$") or lf:match("%.jpeg$") or lf:match("%.png$") then
                image_files[file] = true
            end
        end
    end
    p:close()
    
    local target_cover_file
    
    if opf_path then
        local safe_opf = shellEscape(opf_path)
        local p2 = io.popen('unzip -p ' .. safe_epub .. ' ' .. safe_opf .. ' 2>/dev/null')
        if p2 then
            local opf_content = p2:read("*a")
            p2:close()
            
            local cover_href
            cover_href = opf_content:match('<item[^>]+properties="[^"]*cover-image[^"]*"[^>]+href="([^"]+)"')
            if not cover_href then
                cover_href = opf_content:match('<item[^>]+href="([^"]+)"[^>]+properties="[^"]*cover-image[^"]*"')
            end
            
            if not cover_href then
                local cover_id = opf_content:match('<meta[^>]+name="cover"[^>]+content="([^"]+)"')
                if not cover_id then
                    cover_id = opf_content:match('<meta[^>]+content="([^"]+)"[^>]+name="cover"')
                end
                if cover_id then
                    local escaped_id = cover_id:gsub("[%^%$%%%.%*%+%-%?%[%]]", "%%%1")
                    cover_href = opf_content:match('<item[^>]+id="' .. escaped_id .. '"[^>]+href="([^"]+)"')
                    if not cover_href then
                        cover_href = opf_content:match('<item[^>]+href="([^"]+)"[^>]+id="' .. escaped_id .. '"')
                    end
                end
            end
            
            if cover_href then
                cover_href = cover_href:gsub("%%20", " ")
                local opf_dir = opf_path:match("(.*/)") or ""
                local resolved_path = opf_dir .. cover_href
                
                resolved_path = resolved_path:gsub("%./", "")
                while resolved_path:match("/[^/]+/%.%./") do
                    resolved_path = resolved_path:gsub("/[^/]+/%.%./", "/")
                end
                
                if image_files[resolved_path] then
                    target_cover_file = resolved_path
                else
                    local target_lower = resolved_path:lower()
                    for original_path in pairs(image_files) do
                        if original_path:lower() == target_lower then
                            target_cover_file = original_path
                            break
                        end
                    end
                end
            end
        end
    end
    
    if not target_cover_file then
        local best_score = -1
        for file in pairs(image_files) do
            local lf = file:lower()
            local filename = lf:match("[^/]+$") or lf
            local score = 0
            
            if filename:match("^cover%.") then
                score = 100
            elseif filename:match("cover") then
                if filename:match("[%-_]cover") or filename:match("cover[%-_]") then
                    score = 80
                elseif filename:match("^cover") or filename:match("cover$") then
                    score = 70
                else
                    score = 35
                end
            elseif filename:match("front") or filename:match("titlepage") or filename:match("jacket") then
                score = 60
            elseif filename:match("poster") or filename:match("folder") then
                score = 20
            else
                score = 5
            end
            
            local _, depth = lf:gsub("/", "")
            score = score - (depth * 0.1)
            
            if score > best_score then
                best_score = score
                target_cover_file = file
            end
        end
    end
    
    if target_cover_file then
        local safe_cover = shellEscape(target_cover_file)
        local p3 = io.popen('unzip -p ' .. safe_epub .. ' ' .. safe_cover .. ' 2>/dev/null')
        if p3 then
            local content = p3:read("*a")
            p3:close()
            
            if content and #content > 0 then
                local ok_mime, mime = pcall(require, "mime")
                if ok_mime and mime.b64 then
                    local b64 = mime.b64(content)
                    content = nil 
                    local mime_type = target_cover_file:lower():match("%.png$") and "image/png" or "image/jpeg"
                    return string.format('<img src="data:%s;base64,%s" />', mime_type, b64)
                end
            end
        end
    end
    return nil
end

local function getBookDbStats(book_path, ds, title)
    local md5 = ds and ds:readSetting("partial_md5_checksum")
    if not md5 then md5 = util.partialMD5(book_path) end

    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end

    local conn = SQ3.open(db_path)
    if not conn then return nil end

    local stats = nil
    local success, err = pcall(function()
        local stmt = conn:prepare("SELECT id, total_read_time, total_read_pages FROM book WHERE (title = ? AND md5 = ?) OR md5 = ? LIMIT 1")
        local res = stmt:reset():bind(title or "", md5, md5):step()

        if not res then
            stmt:close()
            return
        end

        local id_book = res[1]
        local db_read_time = tonumber(res[2]) or 0
        local db_read_pages = tonumber(res[3]) or 0
        stmt:close()

        local dates_sql = string.format([[
            SELECT
                min(start_time),
                max(start_time),
                count(DISTINCT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'))
            FROM page_stat
            WHERE id_book = %d
        ]], tonumber(id_book))

        local first_open, last_open, active_days = conn:rowexec(dates_sql)

        local actual_sql = string.format([[
            SELECT COALESCE(sum(durations), 0)
            FROM (
                SELECT min(sum(duration), 120) AS durations
                FROM page_stat
                WHERE id_book = %d
                GROUP BY page
            );
        ]], tonumber(id_book))
        local actual_reading_time = conn:rowexec(actual_sql)

        local timeline_sql = string.format([[
            SELECT
                date(ps.start_time, 'unixepoch', 'localtime') AS dates,
                count(DISTINCT ps.page) AS pages,
                sum(ps.duration) AS durations,
                (SELECT ps2.page FROM page_stat_data ps2 WHERE ps2.id_book = ps.id_book AND date(ps2.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime') ORDER BY ps2.start_time ASC LIMIT 1) AS first_page,
                (SELECT ps3.page FROM page_stat_data ps3 WHERE ps3.id_book = ps.id_book AND date(ps3.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime') ORDER BY ps3.start_time DESC LIMIT 1) AS last_page,
                (SELECT (ps4.page * 1.0 / ps4.total_pages) FROM page_stat_data ps4 WHERE ps4.id_book = ps.id_book AND date(ps4.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime') ORDER BY ps4.start_time DESC LIMIT 1) AS total_percentage,
                (SELECT ps5.total_pages FROM page_stat_data ps5 WHERE ps5.id_book = ps.id_book AND date(ps5.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime') ORDER BY ps5.total_pages DESC LIMIT 1) AS day_total_pages
            FROM page_stat_data ps
            WHERE ps.id_book = %d
            GROUP BY date(ps.start_time, 'unixepoch', 'localtime')
            ORDER BY dates DESC;
        ]], tonumber(id_book))

        local timeline_results = conn:exec(timeline_sql)
        local daily_timeline = {}

        if timeline_results and timeline_results.dates then
            for i = 1, #timeline_results.dates do
                table.insert(daily_timeline, {
                    date = timeline_results.dates[i],
                    pages = tonumber(timeline_results.pages[i]) or 0,
                    duration = tonumber(timeline_results.durations[i]) or 0,
                    first_page = tonumber(timeline_results.first_page[i]),
                    last_page = tonumber(timeline_results.last_page[i]),
                    total_pages = tonumber(timeline_results.day_total_pages[i]) or 0,
                    progress = tonumber(timeline_results.total_percentage[i]) or 0,
                    delta_progress = 0
                })
            end
        end

        for i = #daily_timeline, 1, -1 do
            local older = daily_timeline[i + 1]
            if older then
                daily_timeline[i].delta_progress = (daily_timeline[i].progress or 0) - (older.progress or 0)
            else
                daily_timeline[i].delta_progress = daily_timeline[i].progress or 0
            end
        end

        table.sort(daily_timeline, function(a, b) return a.date > b.date end)

        local raw_rows_sql = string.format([[
            SELECT ps.start_time, date(ps.start_time, 'unixepoch', 'localtime') AS dates, ps.page, ps.duration
            FROM page_stat_data ps WHERE ps.id_book = %d ORDER BY ps.start_time ASC;
        ]], tonumber(id_book))
        local raw_res = conn:exec(raw_rows_sql)

        local sessions = {}
        if raw_res and raw_res.start_time and #raw_res.start_time > 0 then
            local current = nil
            for i = 1, #raw_res.start_time do
                local r_time = tonumber(raw_res.start_time[i])
                local r_date = raw_res.dates[i]
                local r_page = tonumber(raw_res.page[i])
                local r_dur  = tonumber(raw_res.duration[i]) or 0

                local split = false
                if not current then split = true
                else
                    local gap = r_time - current.last_time
                    if r_date ~= current.date or gap > 1800 then split = true end
                end

                if split then
                    if current then table.insert(sessions, current) end
                    current = { date = r_date, duration = 0, pages = 0, last_time = r_time, seen = {} }
                end
                current.last_time = r_time
                current.duration = current.duration + r_dur
                if not current.seen[r_page] then
                    current.seen[r_page] = true
                    current.pages = current.pages + 1
                end
            end
            if current then table.insert(sessions, current) end
        end

        local valid_durations = {}
        local total_sess_pages = 0
        local total_sess_count = 0
        for _, s in ipairs(sessions) do
            if s.pages > 1 and s.duration >= 60 then
                table.insert(valid_durations, s.duration)
                total_sess_pages = total_sess_pages + s.pages
                total_sess_count = total_sess_count + 1
            end
        end

        local med_session = 0
        if #valid_durations > 0 then
            table.sort(valid_durations)
            local mid = #valid_durations
            if mid % 2 == 1 then med_session = valid_durations[(mid+1)/2]
            else med_session = (valid_durations[mid/2] + valid_durations[mid/2+1]) / 2 end
        end

        stats = {
            start_ts = tonumber(first_open),
            finish_ts = tonumber(last_open),
            active_days = tonumber(active_days) or 0,
            read_time = db_read_time,
            read_pages = db_read_pages,
            actual_reading_time = tonumber(actual_reading_time) or 0,
            med_session_seconds = med_session,
            avg_session_pages = total_sess_count > 0 and (total_sess_pages / total_sess_count) or 0,
            timeline = daily_timeline
        }
    end)

    conn:close()
    if not success then
        logger.error("Notesnook: SQLite operation failed: " .. tostring(err))
        return nil
    end

    return stats
end

-- ---------------------------------------------------------------------------
-- HTML note builder
-- ---------------------------------------------------------------------------

local function buildNoteHtml(props, annotations, rating_stars, cover_html, stats)
    local title  = htmlEscape(props.title   or "Unknown Title")
    local author = htmlEscape(props.authors or props.author or "Unknown Author")
    
    local series_block = ""
    if props.series and props.series ~= "" then
        local s_idx = props.series_index and tonumber(props.series_index)
        if s_idx then
            series_block = string.format("<li><strong>Series:</strong> %s (#%g)</li>", htmlEscape(props.series), s_idx)
        else
            series_block = string.format("<li><strong>Series:</strong> %s</li>", htmlEscape(props.series))
        end
    end
    
    local publisher_block = ""
    if props.publisher and props.publisher ~= "" then
        publisher_block = string.format("<li><strong>Publisher:</strong> %s</li>", htmlEscape(props.publisher))
    end

    local start_str = stats and stats.start_ts and os.date("%d %b %Y", stats.start_ts) or "Unknown"
    local finish_str = stats and stats.finish_ts and os.date("%d %b %Y", stats.finish_ts) or "Unknown"
    local active_days = stats and stats.active_days or 0
    
    local span_days = 0
    if stats and stats.start_ts and stats.finish_ts then
        span_days = math.floor((stats.finish_ts - stats.start_ts) / 86400) + 1
    end

    local read_time = stats and stats.read_time or 0
    local read_pages = stats and stats.read_pages or 0
    local actual_time = stats and stats.actual_reading_time or 0
    
    local speed_str = "N/A"
    local avg_page_str = "N/A"
    local progress_efficiency = "0.00"
    if read_time > 0 and read_pages > 0 then
        local pph = (read_pages * 3600) / read_time
        speed_str = string.format("%d pages/hour", math.floor(pph))
        avg_page_str = formatAvgPageTime(read_time / read_pages)
        
        local total_prog = (stats.timeline and stats.timeline[1] and stats.timeline[1].progress) or 0
        progress_efficiency = string.format("%.2f", (total_prog * 100) / (read_time / 3600))
    end

    local daily_avg_time_str = "N/A"
    local daily_avg_pages_str = "N/A"
    if active_days > 0 then
        daily_avg_time_str = formatDuration(read_time / active_days)
        daily_avg_pages_str = string.format("%.1f pages", read_pages / active_days)
    end

    local med_session_str = (stats and stats.med_session_seconds and stats.med_session_seconds > 0) 
                            and formatDuration(stats.med_session_seconds) or "N/A"
    local avg_sess_pg_str = (stats and stats.avg_session_pages and stats.avg_session_pages > 0)
                            and string.format("%.1f pages", stats.avg_session_pages) or "N/A"

    local cover_block = cover_html and (cover_html .. "\n<br />\n") or ""
    
    local desc_block = ""
    if props.description and props.description ~= "" then
        local cleaned_desc = stripHtml(props.description)
        desc_block = string.format([[
            <details style="margin: 15px 0; padding: 10px; border: 1px solid #ddd; border-radius: 4px;">
                <summary style="cursor: pointer; font-weight: bold; color: #555;">Book Description</summary>
                <div style="margin-top: 10px; font-style: italic; color: #444;">%s</div>
            </details>
        ]], htmlEscape(cleaned_desc))
    end
    
    local card_html = string.format([[
        <h2>Reading Dashboard</h2>
        <ul>
            <li><strong>Rating:</strong> %s</li>
            %s
            %s
            <li><strong>Dates:</strong> %s &ndash; %s (%d days total)</li>
            <li><strong>Active Reading Days:</strong> %d days spent reading</li>
            <li><strong>Daily Averages:</strong> %s &bull; %s/day</li>
            <li><strong>Median Session Length:</strong> %s &nbsp;|&nbsp; <strong>Avg Pages/Session:</strong> %s</li>
            <li><strong>Total Duration:</strong> %s &nbsp;|&nbsp; <strong>Actual Reading Time:</strong> %s</li>
            <li><strong>Pace Speed:</strong> %s (&bull; %s per page)</li>
            <li><strong>Progress Efficiency:</strong> %s%% progress / hour</li>
        </ul>
    ]], rating_stars, series_block, publisher_block, start_str, finish_str, span_days, active_days, 
        daily_avg_time_str, daily_avg_pages_str, med_session_str, avg_sess_pg_str, 
        formatDuration(read_time), formatDuration(actual_time), speed_str, avg_page_str, progress_efficiency)

    local timeline_rows = {}
    if stats and stats.timeline and #stats.timeline > 0 then
        for _, item in ipairs(stats.timeline) do
            local day_speed = formatSpeed(item.pages, item.duration)
            day_speed = (day_speed ~= "-") and (day_speed .. " pg/h") or "-"
            
            table.insert(timeline_rows, string.format([[
                <tr>
                    <td style="padding: 6px; border: 1px solid #ddd;">%s</td>
                    <td style="padding: 6px; border: 1px solid #ddd; text-align: center;">%s</td>
                    <td style="padding: 6px; border: 1px solid #ddd; text-align: center;">%d</td>
                    <td style="padding: 6px; border: 1px solid #ddd; text-align: center;">%s</td>
                    <td style="padding: 6px; border: 1px solid #ddd; text-align: center; color: green;">%s</td>
                    <td style="padding: 6px; border: 1px solid #ddd; text-align: center;">%s</td>
                    <td style="padding: 6px; border: 1px solid #ddd; text-align: center;">%s</td>
                </tr>
            ]], formatDate(item.date), formatDurationCompact(item.duration), item.pages, day_speed,
                formatProgressDelta(item.delta_progress), formatProgressTotal(item.progress),
                formatRange(item.first_page, item.last_page, item.total_pages)))
        end
    end

    local timeline_block = ""
    if #timeline_rows > 0 then
        timeline_block = string.format([[
            <hr />
            <h2>Reading Timeline</h2>
            <table style="width: 100%%; border-collapse: collapse; font-size: 0.9em; margin-top: 10px;">
                <thead>
                    <tr style="background-color: #f2f2f2;">
                        <th style="padding: 8px; border: 1px solid #ddd; text-align: left;">DATE</th>
                        <th style="padding: 8px; border: 1px solid #ddd;">TIME</th>
                        <th style="padding: 8px; border: 1px solid #ddd;">PAGES</th>
                        <th style="padding: 8px; border: 1px solid #ddd;">SPEED</th>
                        <th style="padding: 8px; border: 1px solid #ddd;">ΔPROG</th>
                        <th style="padding: 8px; border: 1px solid #ddd;">TOTAL</th>
                        <th style="padding: 8px; border: 1px solid #ddd;">RANGE</th>
                    </tr>
                </thead>
                <tbody>
                    %s
                </tbody>
            </table>
        ]], table.concat(timeline_rows, "\n"))
    end

    local hl_lines = {}
    for _, ann in ipairs(annotations or {}) do
        local txt = ann.text or ann.highlighted_text or ""
        if txt ~= "" then
            local loc = ann.pageno and (" | Page " .. ann.pageno) or ""
            local chapter = (ann.chapter and ann.chapter ~= "") and (" | " .. htmlEscape(ann.chapter)) or ""
            local note_html = (ann.notes and ann.notes ~= "") and
                ("<div style='margin-top: 5px; color: #555; font-style: italic;'><em>" .. htmlEscape(ann.notes) .. "</em></div>") or ""

            local border_color = "#ccc"
            if ann.color and COLOR_MAP[ann.color:lower()] then
                border_color = COLOR_MAP[ann.color:lower()]
            end

            table.insert(hl_lines, string.format(
                "<blockquote style='border-left: 3px solid %s; padding-left: 10px; margin: 15px 0;'>"
                .. "<div>%s</div>"
                .. "<div style='font-size: 0.8em; color: #888; margin-top: 5px;'>%s</div>"
                .. "%s</blockquote>",
                border_color, htmlEscape(txt), (loc .. chapter):gsub("^ %| ", ""), note_html
            ))
        end
    end

    local highlights_compiled = #hl_lines > 0 and table.concat(hl_lines, "\n") or "<p><em>No highlights recorded.</em></p>"

    return string.format("<h1>%s</h1><p><em>by %s</em></p>\n%s\n%s\n%s\n%s<hr /><h2>Highlights & Notes</h2>\n%s", 
        title, author, cover_block, card_html, desc_block, timeline_block, highlights_compiled)
end

-- ---------------------------------------------------------------------------
-- Notesnook Inbox API
-- ---------------------------------------------------------------------------

local function sendToNotesnook(note_title, html_body, on_success, on_error)
    if cfg.api_key == "" then
        if on_error then on_error("API key not configured.") end
        return
    end

    NetworkMgr:runWhenOnline(function()
        local http  = require("socket.http")
        local ltn12 = require("ltn12")
        
        local json_engine
        local ok_rapid, rapidjson = pcall(require, "rapidjson")
        if ok_rapid and rapidjson.encode then
            json_engine = rapidjson
        else
            json_engine = require("json")
        end

        local req_payload = {
            title = note_title,
            type = "note",
            source = "koreader-notesnook",
            version = 1,
            content = {
                type = "html",
                data = html_body
            },
            notebookIds = (cfg.notebook_id and cfg.notebook_id ~= "") and { cfg.notebook_id } or {},
            tagIds = cfg.tag_ids or {},
            favorite = cfg.favorite or false,
            readonly = cfg.readonly or false
        }

        local success, payload = pcall(json_engine.encode, req_payload)
        if not success or not payload then
            if on_error then on_error("JSON generation failed structure limits.") end
            return
        end

        local response_body = {}
        local ok2, code = http.request{
            url    = "https://inbox.notesnook.com/",
            method = "POST",
            headers = {
                ["Content-Type"]   = "application/json",
                ["Authorization"]  = cfg.api_key,
                ["Content-Length"] = tostring(#payload),
            },
            source = ltn12.source.string(payload),
            sink   = ltn12.sink.table(response_body),
        }

        local body = table.concat(response_body)
        logger.dbg("Notesnook: HTTP", code, body)

        if ok2 and code == 200 then
            if on_success then on_success() end
        else
            local msg = "HTTP " .. tostring(code or "error")
            if body ~= "" then msg = msg .. ": " .. body end
            if on_error then on_error(msg) end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Core send logic
-- ---------------------------------------------------------------------------

function Notesnook:sendBook(book_path, doc_settings)
    if not book_path then return end

    if not cfg.api_key or cfg.api_key == "" then
        UIManager:show(InfoMessage:new{
            text = _("Notesnook Sync Error:\nYour API key is empty.\n\nPlease edit your configuration file under:\nnotesnook.koplugin/notesnook_config.lua"),
            timeout = 10
        })
        return
    end

    local ds = doc_settings
    if not ds and lfs.attributes(book_path, "mode") == "file" then
        ds = DocSettings:open(book_path)
    end

    local props       = (ds and ds:readSetting("doc_props"))   or {}
    local annotations = (ds and ds:readSetting("annotations"))
                     or (ds and ds:readSetting("bookmarks"))
                     or {}
                     
    local title      = props.title   or book_path:match("[^/\\]+$") or "Unknown"
    local author     = props.authors or props.author or "Unknown Author"
    local note_title = title .. " - " .. author

    local function processAndSend()
        local sending_msg = InfoMessage:new{ text = _("Processing & Sending...") }
        UIManager:show(sending_msg)
        UIManager:forceRePaint()

        UIManager:scheduleIn(0, function()
            local summary      = ds and ds:readSetting("summary")
            local rating_val   = summary and tonumber(summary.rating) or 0
            local rating_stars = rating_val > 0 and string.rep("★", math.floor(rating_val)) or "Unrated"

            local db_stats = getBookDbStats(book_path, ds, props.title)
            local cover_html = extractEpubCover(book_path)
            local html_body  = buildNoteHtml(props, annotations, rating_stars, cover_html, db_stats)

            sendToNotesnook(note_title, html_body,
                function()
                    UIManager:close(sending_msg)
                    UIManager:show(InfoMessage:new{
                        text    = T(_("Sent to Notesnook:\n%1"), note_title),
                        timeout = 7,
                    })
                    html_body = nil
                    cover_html = nil
                    collectgarbage("step")
                end,
                function(err)
                    UIManager:close(sending_msg)
                    UIManager:show(InfoMessage:new{
                        text    = T(_("Notesnook error:\n%1"), tostring(err)),
                        timeout = 7,
                    })
                    html_body = nil
                    cover_html = nil
                    collectgarbage("step")
                end
            )
        end)
    end

    if cfg.confirm_before_send then
        local summary      = ds and ds:readSetting("summary")
        local rating_val   = summary and tonumber(summary.rating) or 0
        local rating_stars = rating_val > 0 and string.rep("★", math.floor(rating_val)) or "Unrated"
        
        local db_stats = getBookDbStats(book_path, ds, props.title)
        local start_str = db_stats and db_stats.start_ts and os.date("%d %b %Y", db_stats.start_ts) or "Unknown"
        local finish_str = db_stats and db_stats.finish_ts and os.date("%d %b %Y", db_stats.finish_ts) or "Unknown"
        
        local span_days = 0
        if db_stats and db_stats.start_ts and db_stats.finish_ts then
            span_days = math.floor((db_stats.finish_ts - db_stats.start_ts) / 86400) + 1
        end
        
        local dates_val = "Unknown"
        if db_stats and db_stats.start_ts and db_stats.finish_ts then
            dates_val = string.format("%s - %s (%d days)", start_str, finish_str, span_days)
        end

        -- Standard fully compatible dingbats: ❑ (Shadowed Square), ❖ (Diamond), ★ (Star), ‣ (Triangle bullet)
        UIManager:show(ConfirmBox:new{
            text = T(
                _("Send book note to Notesnook?\n\n"
                    .. "❑ Title: %1\n"
                    .. "❖ Highlights: %2\n"
                    .. "★ Rating: %3\n"
                    .. "‣ Dates: %4"),
                note_title, tostring(#annotations), rating_stars, dates_val
            ),
            ok_text     = _("Send"),
            ok_callback = processAndSend,
            cancel_text = _("Cancel"),
        })
    else
        processAndSend()
    end
end

-- ---------------------------------------------------------------------------
-- Dispatcher / Gestures
-- ---------------------------------------------------------------------------

function Notesnook:onDispatcherRegisterActions()
    Dispatcher:registerAction("notesnook_sync_action", {
        category = "none",
        event = "NotesnookSync",
        title = _("Send to Notesnook"),
        general = true,
    })
end

function Notesnook:onNotesnookSync()
    if self.ui and self.ui.document and self.ui.document.file then
        local file = self.ui.document.file
        local doc_settings = self.ui.doc_settings
        self:sendBook(file, doc_settings)
    else
        UIManager:show(InfoMessage:new{
            text = _("Please open a book first to sync it to Notesnook."),
        })
    end
end

-- ---------------------------------------------------------------------------
-- Initialization & File Manager
-- ---------------------------------------------------------------------------

function Notesnook:init()
    if self.onDispatcherRegisterActions then
        self:onDispatcherRegisterActions()
    end

    if not cfg.api_key or cfg.api_key == "" then
        logger.warn("Notesnook: API Key missing in user configuration profiles.")
    end

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not (ok_fm and FileManager and FileManager.addFileDialogButtons) then
        logger.info("Notesnook: addFileDialogButtons not available.")
        return
    end

    FileManager:addFileDialogButtons("notesnook_sync",
        function(file, is_file, _bookinfo)
            if not is_file then return end
            local ext = file:match("%.([^%.]+)$")
            if not (ext and BOOK_EXTENSIONS[ext:lower()]) then return end
            return {
                {
                    text = _("Send to Notesnook"),
                    callback = function()
                        self:sendBook(file, DocSettings:open(file))
                    end,
                },
            }
        end
    )
end

-- ---------------------------------------------------------------------------
-- Tools menu
-- ---------------------------------------------------------------------------

function Notesnook:addToMainMenu(menu_items)
    menu_items.notesnook = {
        text = _("Notesnook Sync"),
        sub_item_table = {
            {
                text = _("About"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _(
                            "Notesnook Sync\n\n"
                            .. "Long-press any book in the library\n"
                            .. "and tap 'Send to Notesnook' to create\n"
                            .. "a note with metadata and highlights.\n\n"
                            .. "Requires KOReader 2025.01 or newer.\n\n"
                            .. "Config file:\n"
                            .. "notesnook.koplugin/notesnook_config.lua"
                        ),
                    })
                end,
            },
        },
    }
end

return Notesnook