assert(session, "No session object!")

session:answer()
session:flushDigits()

local json = dofile("/usr/local/freeswitch/scripts/dkjson.lua")
local prompt = "/usr/local/freeswitch/sounds/en/us/callie/ivr/8000/ivr-enter_source_telephone_number.wav"
local invalid = "/usr/local/freeswitch/sounds/en/us/callie/ivr/8000/ivr-invalid_number_format.wav"

local account_number = session:playAndGetDigits(
    2,          -- min
    10,         -- max
    3,          -- tries
    8000,       -- timeout
    "#",        -- terminator
    prompt,     -- initial prompt
    invalid,    -- invalid response
    ".*"
    --"^%d+$"     -- regex for digits only (MULTIPLE)
)

if account_number == nil or account_number == "" then
    freeswitch.consoleLog("ERR", "[CRM IVR] No account number entered.\n")
    session:streamFile("/usr/local/freeswitch/sounds/en/us/callie/ivr/8000/ivr-exit_sound_prompt.wav")
    return
end


freeswitch.consoleLog("INFO", "[CRM IVR] Customer Account Entered: " .. account_number .. "\n")
--session:sayPhrase("say:digits", account_number)
--session:setVariable("customer_account", account_number)

----------------------------------------------------
-- 2. Prepare JSON BODY using dkjson
----------------------------------------------------
local request_body = {
    lr = {
        ["shipper-id"] = "",
        ["service-provider-id"] = "",
        ["shipper-company-code"] = "",
        ["service-provider-company-code"] = "VT",
        ["consignor-company-id"] = "",
        ["consignee-company-id"] = "",
        ["shipper-company-group"] = "",
        ["invoice-number"] = "",
        ["number"] = account_number,   -- << Inject account number here
        ["state"] = "",
        ["ref1"] = "",
        ["from-delivered-at"] = "",
        ["to-delivered-at"] = "",
        ["delivery-order-number"] = "",
        ["from-last-event-at"] = "",
        ["to-last-event-at"] = "",
        ["show-trip-details"] = "",
        ["draft"] = "",
        ["show-consignment-invoice"] = "",
        ["include-canceled-lrs"] = "",
        ["show_child_lrs"] = "",
        ["skip-events"] = ""
    }
}

local request_json = json.encode(request_body)


----------------------------------------------------
-- 3. Call CURL command (POST) and save response
----------------------------------------------------
local tmpfile = "/tmp/ivr_response.json"

local curl_cmd =
        "curl -s -X POST " ..
        " -H 'X-ShipX-API-Key: pFM8hlTxu4eO62SRK9AOJfzy3iOVy8qceAMRwkfqxs36sLE6CoocxuWMv2gz' " ..
        " -H 'Content-Type: application/json' " ..
        " --data '" .. request_json .. "' " ..
        " 'https://vtrans.vijayant.in/integration/consignments/list.json' " ..
        " > " .. tmpfile

os.execute(curl_cmd)

----------------------------------------------------
-- 4. Read cURL response
----------------------------------------------------
local f = io.open(tmpfile, "r")
local content = f:read("*a")
f:close()

freeswitch.consoleLog("INFO", "[CRM API Response Raw] " .. content .. "\n")


----------------------------------------------------
-- 5. Decode JSON using dkjson
----------------------------------------------------
local data, pos, err = json.decode(content)

if err then
    freeswitch.consoleLog("ERR", "[CRM JSON] Decode error: " .. err .. "\n")
    session:streamFile("/usr/local/freeswitch/sounds/en/us/callie/ivr/error.wav")
    return
end

----------------------------------------------------
-- 6. Extract readable_status
----------------------------------------------------
local status = "Unknown"

if data and data.lrs and data.lrs[1] and data.lrs[1].lr and data.lrs[1].lr.readable_status then
    status = data.lrs[1].lr.readable_status
end

freeswitch.consoleLog("INFO", "[CRM] Status = " .. tostring(status) .. "\n")

----------------------------------------------------
-- 7. Speak STATUS dynamically using mod_say (English)
----------------------------------------------------
if status == "Delivered" then
	session:streamFile("/usr/local/freeswitch/sounds/en/us/callie/conference/8000/conf-is-locked.wav")
else 
	session:streamFile("/usr/local/freeswitch/sounds/en/us/callie/conference/8000/conf-is-unlocked.wav")
end
session:sleep(1000)
session:hangup()

