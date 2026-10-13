-- /usr/local/freeswitch/scripts/whatsappmsg.lua
--
-- POWERLOOK :: Trigger WhatsApp promo template on IVR keypress "1"
-- Ref: Implementation request from Abhay Singh (Triotech).
--      Updated 2026-07-28: switched to "buy1get1_offer" template which uses
--      a dynamic customer name ({{1}} = field_1) fetched from the
--      lead_management MongoDB collection by phone + tenant_uuid.
--
-- How it is invoked:
--   The broadcast IVR sub-menu 36f5b0bd (entered when the customer presses "1"
--   in the main menu 972a1220) has no digit entries, so it exits on
--   max-failures / max-timeouts and runs:
--       exec-on-max-timeouts="lua whatsappmsg.lua"
--       exec-on-max-failures="lua whatsappmsg.lua"
--   i.e. reaching this branch == the customer chose option "1" (interested).
--
-- What it does:
--   1. Resolves the customer's phone number from the live channel.
--   2. Resolves tenant_uuid from the live channel.
--   3. Looks up the customer's first name in lead_management (MongoDB).
--   4. Sends the "buy1get1_offer" WhatsApp template (with the customer's name
--      as field_1 / {{1}}) via the JustTawk Omni API.
--   5. Plays a "Thank you" prompt and hangs up cleanly.

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local API_URL   = "https://omni.justtawk.com/api/e046cb95-5978-48ed-bd6f-2577a2200c79/whatsapp/messages/template"
local API_TOKEN = "xfJccnCni8y0ZJEARXIcvozDVlBP2SL5T0mDNFCG9fqmMDlFOnz9ZceKuA74uJam"

local TEMPLATE_NAME = "buy1get1_offer"

local LOG_FILE = "/usr/local/freeswitch/log/whatsappmsg.log"

-- "Thank you" prompt played to the caller before the call is hung up.
local THANKYOU_FILE = "/opt/caching/upload/c480637f-349a-41d2-a1fd-7d49e16fb318.wav"

-- Fallback name used when no lead record is found in the database.
local DEFAULT_NAME = "Sir/Ma'am"

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function log(level, msg)
  freeswitch.consoleLog(level, "[whatsappmsg.lua] " .. tostring(msg) .. "\n")
end

local function getvar(name)
  if not session then return "" end
  local v = session:getVariable(name)
  if v == nil then return "" end
  return tostring(v)
end

local function end_call()
  if session and session:ready() then
    session:streamFile(THANKYOU_FILE)
  end
  if session and session:ready() then
    session:hangup("NORMAL_CLEARING")
  end
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

-- Escape a string for safe embedding inside a JSON double-quoted value.
local function json_escape(s)
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"',  '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

----------------------------------------------------------------------
-- Guard: session must exist
----------------------------------------------------------------------
if not session then
  log("err", "No session object available. Aborting.")
  return
end


----------------------------------------------------------------------
-- capture pressed digit, same logic as feedback.lua
----------------------------------------------------------------------
local score = argv[1]
if score == nil or score == "" then
  score = session:getVariable("ivr_menu_terminator")
end
if score == nil or score == "" then score = "N/A" end
session:setVariable("ivr_feedback_score", score)


----------------------------------------------------------------------
-- Step 1 — Resolve customer phone number
----------------------------------------------------------------------
local raw_phone = first_non_empty(
  getvar("destination_number"),
  getvar("Caller-Destination-Number"),
  getvar("sip_to_user"),
  getvar("sip_req_user"),
  getvar("Caller-Callee-ID-Number")
)

local phone = raw_phone:gsub("%D", "")   -- digits only

if phone == "" then
  log("err", "Could not determine customer phone number (raw='" .. tostring(raw_phone) .. "'). Aborting.")
  return
end

-- DB stores numbers without country code (10 digits); strip leading 91 if present
local phone_db = phone
if #phone == 12 and phone:sub(1,2) == "91" then
  phone_db = phone:sub(3)
end

----------------------------------------------------------------------
-- Dedup guard: send only once per call
----------------------------------------------------------------------
if getvar("whatsapp_promo_sent") == "true" then
  log("notice", "Promo already sent for this call (" .. phone .. "); skipping duplicate, hanging up.")
  end_call()
  return
end
session:setVariable("whatsapp_promo_sent", "true")

----------------------------------------------------------------------
-- Step 2 — Resolve tenant_uuid (needed for lead lookup)
----------------------------------------------------------------------
local tenant_uuid = first_non_empty(
  getvar("sip_h_P-tenant_uuid"),
  getvar("sip_h_p-tenant_uuid"),
  getvar("tenant_uuid"),
  getvar("variable_tenant_uuid"),
  getvar("domain_uuid")
)

log("notice", "phone=" .. phone .. "  tenant_uuid=" .. tenant_uuid)

----------------------------------------------------------------------
-- Step 3 — Look up customer name from lead_management (MongoDB)
----------------------------------------------------------------------
local customer_name = DEFAULT_NAME

if tenant_uuid ~= "" then
  local ok, err = pcall(function()
    dofile("/usr/local/freeswitch/scripts/common/db.lua")

    local lead_coll = mongo_collection_name:getCollection("lead_management")

    -- Lookup by phone + tenant_uuid only (no cross-tenant fallback)
    -- phone_db is the 10-digit number (DB stores without country code)
    local cursor = lead_coll:find(
      { custom_phone_number = phone_db, tenant_uuid = tenant_uuid }
    )
    local lead = nil
    for row in cursor:iterator() do
      lead = row
    end

    if lead ~= nil then
      local fname = tostring(lead.first_name or "")
      if fname ~= "" and fname ~= "nil" then
        customer_name = fname
        log("notice", "Lead found: name='" .. customer_name .. "'")
      else
        log("notice", "Lead found but first_name is empty; using fallback '" .. DEFAULT_NAME .. "'")
      end
    else
      log("notice", "No lead record found for phone=" .. phone_db .. "; using fallback '" .. DEFAULT_NAME .. "'")
    end
  end)

  if not ok then
    log("err", "DB lookup failed: " .. tostring(err) .. ". Using fallback name '" .. DEFAULT_NAME .. "'.")
  end
else
  log("notice", "tenant_uuid not available; skipping DB lookup, using fallback '" .. DEFAULT_NAME .. "'.")
end

----------------------------------------------------------------------
-- Step 4 — Build JSON payload
-- field_1 and body.inputs drive the {{1}} substitution in the template.
----------------------------------------------------------------------
local safe_name  = json_escape(customer_name)
local safe_phone = json_escape(phone)

local payload = string.format([[{
    "phone_number": "%s",
    "template_uid": "b0ef8594-c792-4b52-b1df-72880f267865",
    "template_id": "915966244889557",
    "template_name": "buy1get1_offer",
    "template_language": "en",
    "language": "en",
    "category": "MARKETING",
    "status": "APPROVED",
    "field_1": "%s",
    "header": {
        "format": null,
        "text": null,
        "inputs": [],
        "media_key": null,
        "requires_document_name": false,
        "requires_location": false
    },
    "body": {
        "text": "Hello {{1}},\r\n\r\nThank you for choosing Powerlook.\r\n\r\nHere's an exclusive offer waiting for you! 🎉\r\n\r\n*Enjoy a  Buy 1 Get 1 FREE on any one product.*\r\n\r\nShow this message in-store to unlock your exclusive discount.  \r\n\r\nVisit your nearest *Powerlook store before 31st August* to shop the latest styles.\r\n\r\nT&C apply.\r\n\r\n*Team Powerlook*",
        "inputs": [
            "field_1"
        ]
    },
    "buttons": [],
    "template_type": null
}]], safe_phone, safe_name)

log("notice", "Customer pressed 1 -> sending WhatsApp '" .. TEMPLATE_NAME
  .. "' to " .. phone .. " (name='" .. customer_name .. "')")

----------------------------------------------------------------------
-- Step 5 — Write payload to temp file and POST via curl (background)
----------------------------------------------------------------------
local uuid = first_non_empty(getvar("uuid"), phone)
local payload_file = "/tmp/whatsappmsg_" .. uuid .. ".json"

local fh, ferr = io.open(payload_file, "w")
if not fh then
  log("err", "Could not open payload file '" .. payload_file .. "': " .. tostring(ferr) .. ". Aborting send.")
  end_call()
  return
end
fh:write(payload)
fh:close()

local shell_cmd = string.format(
  "{ echo \"==== $(date '+%%Y-%%m-%%d %%H:%%M:%%S') to=%s name=%s ====\"; " ..
  "curl --silent --show-error --max-time 20 --location '%s' " ..
  "--header 'Content-Type: application/json' " ..
  "--header 'Authorization: Bearer %s' " ..
  "--data @'%s'; echo; rm -f '%s'; } >> '%s' 2>&1 &",
  phone, customer_name, API_URL, API_TOKEN, payload_file, payload_file, LOG_FILE
)

os.execute(shell_cmd)

log("notice", "WhatsApp promo dispatched for " .. phone .. " (see " .. LOG_FILE .. " for API response).")

end_call()
log("notice", "Call hung up after sending promo to " .. phone .. ".")
