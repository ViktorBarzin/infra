-- ot-recorder Lua hook: forward every location publish to Dawarich.
-- Loaded by ot-recorder via `--lua-script`. The hook() function is invoked
-- synchronously per publish; we fork curl with `&` to keep it fire-and-forget.
-- Dawarich's points table has UNIQUE (lonlat, timestamp, user_id) — duplicates
-- are safely dropped. The .rec file is always written regardless of hook result,
-- so a Dawarich 5xx loses nothing long-term (re-playable via backfill Job).

local function escape_shell_single(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function json_escape_string(s)
  return (s:gsub("\\", "\\\\")
           :gsub('"', '\\"')
           :gsub("\n", "\\n")
           :gsub("\r", "\\r")
           :gsub("\t", "\\t"))
end

-- Minimal JSON serializer — scalars, arrays, maps. Owntracks payloads are
-- all primitive/flat; no bignum or cyclic-ref concerns.
local function to_json(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "number" then return tostring(v) end
  if t == "boolean" then return tostring(v) end
  if t == "string" then return '"' .. json_escape_string(v) .. '"' end
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i, x in ipairs(v) do parts[i] = to_json(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, x in pairs(v) do
      parts[#parts + 1] = '"' .. json_escape_string(tostring(k)) .. '":' .. to_json(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

function otr_init()
  otr.log("dawarich-bridge: init")
  if not os.getenv("DAWARICH_API_KEY") then
    otr.log("dawarich-bridge: WARN DAWARICH_API_KEY unset — hook will skip")
  end
end

function otr_exit()
  otr.log("dawarich-bridge: exit")
end

function otr_hook(topic, _type, data)
  if _type ~= "location" then return end
  local api_key = os.getenv("DAWARICH_API_KEY")
  if not api_key or api_key == "" then
    otr.log("dawarich-bridge: DAWARICH_API_KEY missing — dropping point")
    return
  end
  -- Strip the base64 user avatar: ot-recorder appends a ~120KB `face` field
  -- to enriched payloads which pushes the curl command past ARG_MAX (code=7
  -- "Argument list too long"). Dawarich doesn't need it.
  data.face = nil
  local url = "https://dawarich.viktorbarzin.me/api/v1/owntracks/points?api_key=" .. api_key
  local payload = to_json(data)
  local cmd = table.concat({
    "curl -sS -o /dev/null --max-time 5 -X POST",
    "-H 'Content-Type: application/json'",
    "-d", escape_shell_single(payload),
    escape_shell_single(url),
    "&",
  }, " ")
  local ok, reason, code = os.execute(cmd)
  if not ok then
    otr.log("dawarich-bridge: FAIL tst=" .. tostring(data.tst) ..
            " reason=" .. tostring(reason) .. " code=" .. tostring(code) ..
            " cmd=" .. cmd)
  else
    otr.log("dawarich-bridge: ok tst=" .. tostring(data.tst))
  end
end
