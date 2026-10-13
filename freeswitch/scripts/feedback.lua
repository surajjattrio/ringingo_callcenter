-- feedback.lua

-- 1. DEFINE VARIABLES
local caller_id = "UNKNOWN"
local agent = "UNKNOWN"
local score = "N/A"
local uuid = "UNKNOWN"
local call_date = os.date("%Y-%m-%d %H:%M:%S")

-- 2. CHECK IF RUNNING IN A REAL CALL
if session then
    -- === REAL CALL MODE ===
    if session:ready() then
        session:answer()

        -- Get variables from the live call
        caller_id = session:getVariable("caller_id_number") or "Unknown_Caller"
        uuid = session:getVariable("uuid")

        -- Try to get the Agent Name (from CC_AGENT or previous variables)
        agent = session:getVariable("cc_agent")
        if (agent == nil) then agent = session:getVariable("bridge_to_agent_id") end
        if (agent == nil) then agent = "Unknown_Agent" end

        -- GET THE SCORE (DIGIT PRESSED)
        -- Priority 1: Argument passed from IVR (e.g. "lua feedback.lua 9")
        score = argv[1]

        -- Priority 2: If no argument, check last DTMF (Fallback)
        if (score == nil or score == "") then
            score = session:getVariable("ivr_menu_terminator")
        end

        if (score == nil) then score = "N/A" end
        session:setVariable("ivr_feedback_score", score)
        -- Save to CSV
        local log_file_path = "/usr/local/freeswitch/log/agent_feedback.csv"
        local file = io.open(log_file_path, "a")
        if file then
            file:write(string.format("%s,%s,%s,%s,%s\n", call_date, caller_id, agent, score, uuid))
            file:close()
            freeswitch.consoleLog("info", "FEEDBACK SAVED: Agent="..agent.." Score="..score.."\n")
        else
            freeswitch.consoleLog("err", "Failed to write to feedback CSV.\n")
        end

        -- Play Thank You
        session:execute("playback", "ivr/ivr-thank_you.wav")
        session:sleep(500)
        session:hangup()
    end
else
    -- === CLI TEST MODE (Simulated) ===
    freeswitch.consoleLog("info", "--- RUNNING IN CLI TEST MODE ---\n")

    -- Mock variables since we aren't in a call
    caller_id = "CLI_TEST_CALLER"
    agent = "CLI_TEST_AGENT"
    uuid = "CLI_TEST_UUID"
    score = argv[1] or "5" -- Use the number you typed, or default to 5

    -- Test writing to file
    local log_file_path = "/usr/local/freeswitch/log/agent_feedback.csv"
    local file = io.open(log_file_path, "a")
    if file then
        file:write(string.format("%s,%s,%s,%s,%s\n", call_date, caller_id, agent, score, uuid))
        file:close()
        freeswitch.consoleLog("info", "CLI TEST SUCCESS: Data written to " .. log_file_path .. "\n")
    else
        freeswitch.consoleLog("err", "CLI TEST FAILED: Could not write to file. Check permissions.\n")
    end
end
