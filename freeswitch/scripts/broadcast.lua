-- /usr/local/freeswitch/scripts/broadcast.lua
-- FIXED:
-- 1) Recording starts immediately (uuid_record) so it works even if call already answered
-- 2) Dynamic folder per tenant_domain (with safe domain resolution)
-- 3) recording_follow_transfer=true supported
-- 4) NIL-safe everywhere, does not break existing broadcast flow

local json = dofile("/usr/local/freeswitch/scripts/dkjson.lua")

dofile("/usr/local/freeswitch/scripts/config.lua")
caching_path = '/opt/caching/'
dofile(scripts_dir .. "common/db.lua")
dofile(scripts_dir .. "common/custom.lua")

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function safe(v)
  if v == nil then return "" end
  return tostring(v)
end

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v ~= nil then
      v = tostring(v)
      if v ~= "" and v ~= "nil" then return v end
    end
  end
  return ""
end

local function getvar(name)
  if not session then return "" end
  local v = session:getVariable(name)
  if v == nil then return "" end
  return tostring(v)
end

local function log_notice(msg) fs_logger("notice", msg) end
local function log_warn(msg)   fs_logger("warning", msg) end
local function log_err(msg)    fs_logger("err", msg) end

local function is_ip(s)
  s = safe(s)
  return s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function sanitize_domain(d)
  d = safe(d)
  if d == "" then return "" end
  d = d:gsub("[^%w%.%-%_]", "_")
  return d
end

local function ensure_dir(path)
  path = safe(path)
  if path == "" then return false end
  freeswitch.API():execute("system", "mkdir -p '" .. path .. "'")
  return true
end

-- keeps your existing meaning: recording == '0' => enabled
local function recording_enabled(v)
  v = safe(v)
  return (v == "0")
end

-- Try to resolve real domain if header missing / looks like IP
local function resolve_tenant_domain(current_domain, tenant_uuid)
  current_domain = safe(current_domain)
  tenant_uuid = safe(tenant_uuid)

  -- Prefer explicit variables if present
  local direct = first_non_empty(
    current_domain,
    getvar("tenant_domain"),
    getvar("domain"),
    getvar("domain_name"),
    getvar("sip_h_P-tenant_domain"),
    getvar("sip_h_p-tenant_domain"),
    getvar("sip_h_P-tenant-domain"),
    getvar("sip_h_p-tenant-domain"),
    getvar("sip_i_P-tenant_domain"),
    getvar("sip_i_P-tenant-domain")
  )

  if direct ~= "" and not is_ip(direct) then
    return sanitize_domain(direct)
  end

  -- If it still looks like IP/empty, try Mongo lookup by tenant_uuid (SAFE, only when needed)
  if tenant_uuid ~= "" then
    local ok, result = pcall(function()
      local candidates = { "tenants", "tenant", "tenant_details", "companies", "company" }
      local fields = { "domain", "domain_name", "tenant_domain", "tenantDomain", "server_domain" }

      for _, col in ipairs(candidates) do
        local c = mongo_collection_name:getCollection(col)
        local cur = c:find({ uuid = tenant_uuid })
        for doc in cur:iterator() do
          if doc then
            for _, f in ipairs(fields) do
              if doc[f] and tostring(doc[f]) ~= "" then
                return tostring(doc[f])
              end
            end
          end
        end
      end
      return ""
    end)

    if ok and result and result ~= "" and not is_ip(result) then
      return sanitize_domain(result)
    end
  end

  -- last resort: keep whatever we got (even if IP), but sanitize
  direct = sanitize_domain(direct)
  if direct == "" then direct = "unknown_tenant" end
  return direct
end

---------------------------------------------------------------------
-- Start
---------------------------------------------------------------------
log_notice("[broadcast.lua] execution start of voice broadcast")

local broadcast_uuid = first_non_empty(
  getvar("sip_h_P-campaign_uuid"),
  getvar("sip_h_p-campaign_uuid"),
  getvar("sip_h_P-campaign-uuid"),
  getvar("sip_h_p-campaign-uuid")
)

local tenant_uuid = first_non_empty(
  getvar("sip_h_P-tenant_uuid"),
  getvar("sip_h_p-tenant_uuid"),
  getvar("sip_h_P-tenant-uuid"),
  getvar("sip_h_p-tenant-uuid")
)

local lead_uuid = first_non_empty(
  getvar("sip_h_p-lead_uuid"),
  getvar("sip_h_P-lead_uuid"),
  getvar("sip_h_p-lead-uuid"),
  getvar("sip_h_P-lead-uuid")
)

local phone_number = first_non_empty(
  getvar("Caller-Destination-Number"),
  getvar("destination_number"),
  getvar("sip_to_user"),
  getvar("sip_req_user")
)

local tenant_domain_raw = first_non_empty(
  getvar("sip_h_P-tenant_domain"),
  getvar("sip_h_p-tenant_domain"),
  getvar("sip_h_P-tenant-domain"),
  getvar("sip_h_p-tenant-domain"),
  getvar("sip_i_P-tenant_domain"),
  getvar("sip_i_P-tenant-domain"),
  getvar("domain_name"),
  getvar("sip_from_host"),
  getvar("sip_req_host"),
  getvar("context")
)

local record_date = os.date("%Y-%m-%d")
local record_ts   = os.date("%Y-%m-%d_%H:%M:%S")
local call_uuid   = first_non_empty(getvar("uuid"), getvar("unique-id"))

log_notice("[broadcast.lua] broadcast_uuid  " .. safe(broadcast_uuid))
log_notice("[broadcast.lua] tenant_uuid     " .. safe(tenant_uuid))
log_notice("[broadcast.lua] lead_uuid       " .. safe(lead_uuid))
log_notice("[broadcast.lua] phone_number    " .. safe(phone_number))
log_notice("[broadcast.lua] tenant_domain   " .. safe(tenant_domain_raw))
log_notice("[broadcast.lua] record_date     " .. safe(record_date))

---------------------------------------------------------------------
-- Mongo collections (as-is)
---------------------------------------------------------------------
local voice_broadcast_collection = mongo_collection_name:getCollection "voice_broadcast"
local dnc_collection = mongo_collection_name:getCollection "dnc"
local survey_details_collection = mongo_collection_name:getCollection "survey_details"

local voice_broadcast_query = { uuid = broadcast_uuid }
local cursor = voice_broadcast_collection:find(voice_broadcast_query)

local voice_broadcast_array = ""
for voice_broadcast_details in cursor:iterator() do
  voice_broadcast_array = voice_broadcast_details
end

if voice_broadcast_array == "" then
  log_warn("[broadcast.lua] :: Voicebroadcast Not available ::")
  return true
end

log_warn("[broadcast.lua] :: Voicebroadcast is available ::")

---------------------------------------------------------------------
-- ✅ Recording block (FIXED)
-- Uses uuid_record start so it records even if call is already answered
-- and it will not be broken by execute_on_answer overrides later.
---------------------------------------------------------------------
local do_record = recording_enabled(voice_broadcast_array.recording)

if do_record then
  local tenant_domain = resolve_tenant_domain(tenant_domain_raw, tenant_uuid)

  -- build phone format
  local phone_for_file = safe(phone_number):gsub("%s+", "")
  if phone_for_file == "" then
    phone_for_file = "+unknown"
  elseif phone_for_file:match("^%d+$") then
    phone_for_file = "+" .. phone_for_file
  end

  local recordings_base = first_non_empty(getvar("recordings_dir"), "/usr/local/freeswitch/recordings")
  local record_dir = recordings_base .. "/" .. tenant_domain .. "/" .. record_date
  ensure_dir(record_dir)

  --local record_file = record_dir .. "/" .. phone_for_file .. "_" .. record_ts .. "_" .. call_uuid .. ".wav"
  local record_file = record_dir .. "/" .. call_uuid .. ".wav" -- ::yaksh::

  -- important for transfer
  session:execute("set", "recording_follow_transfer=true")
  session:execute("set", "recording_directory=" .. record_file)

  -- prevent duplicate start
  if getvar("xeny_voicebroadcast_recording_started") ~= "true" then
    session:execute("set", "xeny_voicebroadcast_recording_started=true")

    -- Start immediately (works even if answered already)
    local api = freeswitch.API()
    local res = api:execute("uuid_record", call_uuid .. " start " .. record_file)

    log_notice("[broadcast.lua] uuid_record start -> " .. record_file .. " | result=" .. safe(res))
  else
    log_notice("[broadcast.lua] Recording already started earlier, skipping.")
  end
else
  log_notice("[broadcast.lua] Recording disabled by campaign setting (recording != '0').")
end

---------------------------------------------------------------------
-- Keep your current behavior
---------------------------------------------------------------------
session:execute("set", "sip_h_P-voicebroadcast=true")

---------------------------------------------------------------------
-- Welcome prompt details (as-is)
---------------------------------------------------------------------
local welcome_details = {}
local welcome_prompt_data = voice_broadcast_array.welcome_prompt_selected_value or {}

local idx1 = 1
local idx0 = 0
for _, entry in ipairs(welcome_prompt_data) do
  local val = entry and entry.value or ""
  welcome_details[idx1] = val
  welcome_details[idx0] = val
  idx1 = idx1 + 1
  idx0 = idx0 + 1
end

---------------------------------------------------------------------
-- Digit flow (as-is)
---------------------------------------------------------------------
local allowed_digits = "[0-2]"
local welcome_prompt_digit = ""

if (voice_broadcast_array and voice_broadcast_array.skip == 'false') then
  welcome_prompt_digit = session:playAndGetDigits(
    0, 1,
    voice_broadcast_array.playfile_time,
    10000, "#",
    upload_file_path .. "/" .. voice_broadcast_array.welcome_prompt_uuid .. ".wav",
    "",
    allowed_digits
  )
elseif (voice_broadcast_array and voice_broadcast_array.skip == 'true') then
  welcome_prompt_digit = 0
end

log_warn("[broadcast.lua] ::pressed digits::" .. safe(welcome_prompt_digit))

if (welcome_prompt_digit == "") then
  log_warn("[broadcast.lua] ::pressed in digits::" .. safe(welcome_prompt_digit))
  session:execute("playback", upload_file_path .. "/" .. voice_broadcast_array.exit_prompt_uuid .. ".wav")
  session:hangup()
  return true
end

if (tonumber(welcome_prompt_digit) == 0) then
  log_warn("[broadcast.lua] :: user has pressed the 0 and continue the call")

  if tonumber(voice_broadcast_array.broadcast_type) == 0 then
    log_warn("[broadcast.lua] :: broadcast have survey in their additional setting")
    session:execute("set", "sip_h_P-voicebroadcast_type=0")

    local survey_data = voice_broadcast_array.survey_value or {}
    local survey_details = {}
    local survey_key = 1

    for _, entry in ipairs(survey_data) do
      log_warn("[broadcast.lua] :: survey prompt uuid" .. safe(entry.prompt_uuid))
      log_warn("[broadcast.lua] :: survey from digit" .. safe(entry.from))
      log_warn("[broadcast.lua] :: survey to digit" .. safe(entry.to))

      survey_details[survey_key] = {}

      local survey_allowed_digits = "[" .. safe(entry.from) .. "-" .. safe(entry.to) .. "]"
      log_warn("[broadcast.lua] :: allowed survey digit" .. safe(survey_allowed_digits))

      local survey_digit = session:playAndGetDigits(
        1, 1,
        1,
        10000, "#",
        upload_file_path .. "/" .. safe(entry.prompt_uuid) .. ".wav",
        "",
        survey_allowed_digits
      )

      log_warn("[broadcast.lua] :: pressed survey digit" .. safe(survey_digit))

      survey_details[survey_key]["greeting_name"] = entry.prompt_name
      survey_details[survey_key]["greeting_uuid"] = entry.prompt_uuid
      survey_details[survey_key]["pressed_survey_digit"] = survey_digit
      survey_key = survey_key + 1
    end

    local survey_string = json.encode(survey_details)
    log_warn("[broadcast.lua] :: survey stored data" .. safe(survey_string))
    session:execute("set", "sip_h-p_survey_string=" .. safe(survey_string))

  else
    log_warn("[broadcast.lua] :: broadcast have Ivr in their additional setting")
    session:execute("set", "sip_h_P-voicebroadcast_type=1")
    session:execute("ivr", voice_broadcast_array.ivr_uuid)
  end

  session:execute("playback", upload_file_path .. "/" .. voice_broadcast_array.exit_prompt_uuid .. ".wav")

elseif (tonumber(welcome_prompt_digit) == 1) then
  log_warn("[broadcast.lua] :: user has pressed the 1 and call go to Not interested")
  session:execute("playback", safe(welcome_details[1]))
  session:execute("set", "sip_h_P-voicebroadcast_type=2")
  session:hangup()

elseif (tonumber(welcome_prompt_digit) == 2) then
  log_warn("[broadcast.lua] :: user has pressed the 2 and call go to Dnc")
  session:execute("playback", safe(welcome_details[2]))
  session:execute("set", "sip_h_P-voicebroadcast_type=3")
  session:hangup()

  local dnc_uuid = generateUUIDv4()
  local datatoinsert = {
    voicebroadcast_uuid = broadcast_uuid,
    tenant_uuid = tenant_uuid,
    lead_uuid = lead_uuid,
    phone_number = phone_number,
    status = '0',
    global_status = '0',
    uuid = dnc_uuid
  }
  dnc_collection:insert(datatoinsert)
end

return true

