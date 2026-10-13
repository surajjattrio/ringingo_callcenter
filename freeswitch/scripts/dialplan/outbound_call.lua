fs_logger("notice","[dialplan/outbound_call.lua][XML_STRING] IN PSTN : "..caller_user_uuid)
dofile(scripts_dir .. "common/cli_route.lua");
local user_array = get_userinfo(caller_user_uuid)
if(user_array == nil or user_array == '' or user_array.user_group_uuid == '')then
	hangup_cause = "NO_ROUTE_DESTINATION";
	fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
	fs_logger("warning","[index/outbound_call.lua:: Outgoing rules Not Set1")
	dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
	return true;
end

-- ::yaksh:: Fetching Extension(SIP device) Details.
local ext_array = get_caller_info(user_array.default_extension)

local user_group_collection = mongo_collection_name:getCollection "user_group"
local query = { uuid = user_array.user_group_uuid, status = '0' }
local projection = { outbound_rule = true, _id = false }
local cursor = user_group_collection:find(query, { projection = projection })
-- iterate over the results
user_group_array = ""
for  user_group_details in cursor:iterator() do
    -- do something with the document
    user_group_array = user_group_details;
end
local destination_length = string.len(destination_number);
if(user_group_array == nil or user_group_array == '' or user_group_array.outbound_rule == '')then
	hangup_cause = "NO_ROUTE_DESTINATION";
	fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
	fs_logger("warning","[index/outbound_call.lua:: User Group Not Found/ Outgoing rules Not Set2")
	dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
	return true;
end

local selected_campaign_uuid =  params:getHeader("variable_sip_h_X-selectedcampaignuuid");
local campaign_flag = params:getHeader("variable_sip_h_X-campaign_flag")

local lead_management_uuid = params:getHeader("variable_sip_h_X-Leaduuid") or ""

local campaign_outgoing_rule_uuid = ""
-- CLI route : campaign Caller ID (type Manual) used when agent has not selected a CLI
local campaign_manual_cli = ""

----------------------------------------------------------
-- Multi Caller IDs for Manual Calls
-- Caller id selected by agent (INVITE header X-manual_caller_id) is used only if
-- it is configured in agent's campaign (outbound / blended) with option enabled.
----------------------------------------------------------
local function resolve_manual_caller_id(log_tag)
	local manual_cid = params:getHeader("variable_sip_h_X-manual_caller_id") or params:getHeader("sip_h_X-manual_caller_id") or ""
	local manual_campaign_uuid = params:getHeader("variable_sip_h_X-selectedcampaignuuid") or params:getHeader("sip_h_X-selectedcampaignuuid") or ""
	fs_logger("notice", log_tag.."[MultiCID] Header X-manual_caller_id : '"..manual_cid.."' | campaign_uuid : '"..manual_campaign_uuid.."'")
	if(manual_cid == "")then
		fs_logger("notice", log_tag.."[MultiCID] No manual caller id in INVITE, default caller id logic will be used")
		return ""
	end
	if(manual_campaign_uuid == "")then
		fs_logger("warning", log_tag.."[MultiCID] Manual caller id "..manual_cid.." ignored : campaign uuid header missing")
		return ""
	end
	local campaign_doc = nil
	local campaign_coll = ""
	local query = { uuid = manual_campaign_uuid, status = '0' }
	local projection = { manual_multi_caller_id = true, manual_caller_ids = true, _id = false }
	for _, coll_name in ipairs({ "outbound_campaign", "blended_campaign" }) do
		local cursor = mongo_collection_name:getCollection(coll_name):find(query, { projection = projection })
		for campaign_details in cursor:iterator() do
			campaign_doc = campaign_details
			campaign_coll = coll_name
		end
		if(campaign_doc ~= nil)then break end
	end
	if(campaign_doc == nil)then
		fs_logger("warning", log_tag.."[MultiCID] Manual caller id "..manual_cid.." ignored : campaign "..manual_campaign_uuid.." not found / inactive")
		return ""
	end
	fs_logger("notice", log_tag.."[MultiCID] Campaign found in "..campaign_coll.." | manual_multi_caller_id : "..tostring(campaign_doc.manual_multi_caller_id))
	if(tostring(campaign_doc.manual_multi_caller_id) ~= "0")then
		fs_logger("warning", log_tag.."[MultiCID] Manual caller id "..manual_cid.." ignored : Multi Caller IDs for Manual Calls is disabled in campaign")
		return ""
	end
	local allowed_list = {}
	if(type(campaign_doc.manual_caller_ids) == "table")then
		for _, allowed_cid in pairs(campaign_doc.manual_caller_ids) do
			table.insert(allowed_list, tostring(allowed_cid))
			if(tostring(allowed_cid) == manual_cid)then
				fs_logger("notice", log_tag.." Using Agent Selected Manual Caller ID : "..manual_cid)
				return manual_cid
			end
		end
	end
	fs_logger("warning", log_tag.."[MultiCID] Agent Selected Caller ID not allowed in campaign : "..manual_cid.." | allowed : "..table.concat(allowed_list, ","))
	return ""
end
-- local campaign_caller_id = ""; -- ::yaksh::
if(selected_campaign_uuid ~= nil and selected_campaign_uuid ~= '')then
	local campaign_array = ""
        local outbound_campaign_collection = mongo_collection_name:getCollection "outbound_campaign"
        local blended_campaign_collection = mongo_collection_name:getCollection "blended_campaign"
        local query = {uuid = selected_campaign_uuid,status='0'}
        local projection = {call_id_value = true, call_id_type = true, outgoing_rule_uuid = true,threeway_outgoing_rule_uuid=true,manual_outgoing_rule_uuid=true,uuid=true,_id=false}
        if(campaign_flag ~= nil and campaign_flag ~= "" and campaign_flag == "blended")then
                local cursor = blended_campaign_collection:find(query,{projection=projection})
                for blended_campaign_details in cursor:iterator() do
                        campaign_array = blended_campaign_details;
                end
        else
                local cursor = outbound_campaign_collection:find(query, { projection = projection })
                for  outbound_campaign_details in cursor:iterator() do
                        -- do something with the document
                        campaign_array = outbound_campaign_details;
                end
    	end

	-- campaign_caller_id = campaign_array.call_id_value;
	if(campaign_array ~= nil and campaign_array ~= '' and tostring(campaign_array.call_id_type) == "0" and campaign_array.call_id_value ~= nil)then
		campaign_manual_cli = tostring(campaign_array.call_id_value)
	end
	if(campaign_array ~= nil and campaign_array.outgoing_rule_uuid ~= nil and campaign_array.outgoing_rule_uuid ~= '')then
		if(campaign_array ~= nil and campaign_array.threeway_outgoing_rule_uuid ~= nil and campaign_array.threeway_outgoing_rule_uuid ~= "" and threeway_transfer_flag == 0)then
			campaign_outgoing_rule_uuid = campaign_array.threeway_outgoing_rule_uuid;
			fs_logger("warning","[index/outbound_call.lua:: campaign_three_way_outgoing_rule_uuid::"..campaign_outgoing_rule_uuid)
		elseif(campaign_array ~= nil and campaign_array.manual_outgoing_rule_uuid ~= nil and campaign_array.manual_outgoing_rule_uuid ~= "")then
			campaign_outgoing_rule_uuid = campaign_array.manual_outgoing_rule_uuid;
			fs_logger("warning","[index/outbound_call.lua:: campaign_manual_outgoing_rule_uuid::"..campaign_outgoing_rule_uuid)
		else
			campaign_outgoing_rule_uuid = campaign_array.outgoing_rule_uuid;
			fs_logger("warning","[index/outbound_call.lua:: campaign_outgoing_rule_uuid::"..campaign_outgoing_rule_uuid)
		end
	fs_logger("warning","[index/outbound_call.lua:: campaign_outgoing_rule_uuid::"..campaign_outgoing_rule_uuid)
	end
end

local outgoing_rules_collection = mongo_collection_name:getCollection "outgoing_rules"
local query = { uuid = user_group_array.outbound_rule, status = '0' }
if(campaign_outgoing_rule_uuid ~= nil and campaign_outgoing_rule_uuid ~= '' )then
	query = { uuid = campaign_outgoing_rule_uuid, status = '0' }
end
local projection = { rules = true,uuid= true, route_type = true, no_cli_mode = true, _id = false }
local cursor = outgoing_rules_collection:find(query, { projection = projection })
-- iterate over the results
outgoing_rules_array = ""
for  outgoing_rules_details in cursor:iterator() do
    -- do something with the document
    outgoing_rules_array = outgoing_rules_details;
end
local original_destination_number = destination_number
local custom_destination_number = destination_number
if(pstn_destination_number ~= nil)then
	fs_logger("warning","[index/outbound_call.lua:: pstn_destination_number"..pstn_destination_number)
	destination_length = string.len(pstn_destination_number);
	custom_destination_number = pstn_destination_number
else
	destination_length = string.len(destination_number);
end
if(outgoing_rules_array == '')then
	hangup_cause = "NO_ROUTE_DESTINATION";
	fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
	fs_logger("warning","[index/outbound_call.lua:: User Group Not Found/ Outgoing rules Not Set3")
	dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
	return true;
end
local loop_break = 0;
local updated_destination_number = '';
local trunk_uuid = '';
local outgoing_rule_caller_id = "";
local failover_trunk_1_uuid = '';
local failover_trunk_2_uuid = '';
local failover_trunk_1_call_id = '';
local failover_trunk_2_call_id = '';
-- To number per failover leg (CLI route can format it differently), defaults to updated_destination_number
local failover_1_destination_number = '';
local failover_2_destination_number = '';

----------------------------------------------------------
-- CLI based route (outgoing_rules.route_type = "cli")
-- Route, CLI and To number are selected by caller id instead of prefix rows
----------------------------------------------------------
local cli_route_mode = (tostring(outgoing_rules_array.route_type or "") == "cli")
local cli_route = nil
local prefix_rules = outgoing_rules_array.rules
if(cli_route_mode)then
	prefix_rules = {}
	local route_cli = resolve_manual_caller_id("[dialplan/outbound_call.lua]")
	if(route_cli == "" and campaign_manual_cli ~= "")then
		route_cli = campaign_manual_cli
		fs_logger("notice","[dialplan/outbound_call.lua][CLIRoute] Using campaign caller id : "..route_cli)
	end
	cli_route = cli_route_resolve(outgoing_rules_array, route_cli, custom_destination_number, "[dialplan/outbound_call.lua]")
	if(not cli_route.ok)then
		hangup_cause = "NO_ROUTE_DESTINATION";
		fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
		fs_logger("warning","[dialplan/outbound_call.lua][CLIRoute] Call failed : "..tostring(cli_route.reason))
		dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
		return true;
	end
	updated_destination_number = cli_route.primary.to
	trunk_uuid = cli_route.primary.trunk_uuid
	if(cli_route.failovers[1] ~= nil)then
		failover_trunk_1_uuid = cli_route.failovers[1].trunk_uuid
		failover_trunk_1_call_id = cli_route.failovers[1].cli
		failover_1_destination_number = cli_route.failovers[1].to
	end
	if(cli_route.failovers[2] ~= nil)then
		failover_trunk_2_uuid = cli_route.failovers[2].trunk_uuid
		failover_trunk_2_call_id = cli_route.failovers[2].cli
		failover_2_destination_number = cli_route.failovers[2].to
	end
end
-- Updated (5th Sep 2025)
for param_key, param_value in ipairs(prefix_rules) do

    fs_logger("notice","[outbound_call.lua] Checking Rule : "..param_key)

    ----------------------------------------------------------
    -- Condition 1 : Prefix / Strip / Prepend
    ----------------------------------------------------------
    if ((param_value.prefix ~= '' or param_value.prefix == '*')
        and param_value.trunk_uuid ~= ''
        and (tonumber(destination_length) == tonumber(param_value.length)
        or tonumber(param_value.length) == 0)) then

        local prefix_length = string.len(param_value.prefix)
        local destination_prefix = string.sub(custom_destination_number,1,prefix_length)

        if(destination_prefix == param_value.prefix
            or param_value.prefix == '*') then

            if(param_value.strip ~= '' and param_value.strip ~= nil) then
                updated_destination_number = 
                    do_number_translation(
                        param_value.strip,
                        custom_destination_number
                    )
            else
                updated_destination_number = custom_destination_number
            end

            updated_destination_number = param_value.prepend .. updated_destination_number
            trunk_uuid = param_value.trunk_uuid
            failover_trunk_1_uuid = param_value.failover_trunk_1_uuid
            failover_trunk_2_uuid = param_value.failover_trunk_2_uuid
            failover_trunk_1_call_id = param_value.failover_trunk_1_call_id
            failover_trunk_2_call_id = param_value.failover_trunk_2_call_id

            --------------------------------------------------
            -- Caller ID from Outgoing Rule
            --------------------------------------------------
            if(param_value.call_id_value ~= nil
                and param_value.call_id_value ~= "") then

                outgoing_rule_caller_id =
                    param_value.call_id_value

                fs_logger(
                    "notice",
                    "[outbound_call.lua] Outgoing Rule DID : "
                    .. outgoing_rule_caller_id
                )
            end
            break
        end
    end

    ----------------------------------------------------------
    -- Condition 2 : Prepend Only
    ----------------------------------------------------------
    if ((param_value.prefix == '' or param_value.prefix == nil)
        and (param_value.strip == '' or param_value.strip == nil)
        and (param_value.prepend ~= '' and param_value.prepend ~= nil)
        and param_value.trunk_uuid ~= '') then

        updated_destination_number = param_value.prepend .. custom_destination_number
        trunk_uuid = param_value.trunk_uuid
        failover_trunk_1_uuid = param_value.failover_trunk_1_uuid
        failover_trunk_2_uuid = param_value.failover_trunk_2_uuid
        failover_trunk_1_call_id = param_value.failover_trunk_1_call_id
        failover_trunk_2_call_id = param_value.failover_trunk_2_call_id

        --------------------------------------------------
        -- Caller ID from Outgoing Rule
        --------------------------------------------------
        if(param_value.call_id_value ~= nil
            and param_value.call_id_value ~= "") then

            outgoing_rule_caller_id =
                param_value.call_id_value

            fs_logger(
                "notice",
                "[outbound_call.lua] Outgoing Rule DID : "
                .. outgoing_rule_caller_id
            )
        end
        break
    end
end

if(failover_1_destination_number == '')then failover_1_destination_number = updated_destination_number end
if(failover_2_destination_number == '')then failover_2_destination_number = updated_destination_number end
if(updated_destination_number == '' or trunk_uuid == '')then
	hangup_cause = "NO_ROUTE_DESTINATION";
	fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
	fs_logger("warning","[index/outbound_call.lua:: Outgoing rules Not Set2")
	dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
	return true;
else
	fs_logger("notice","[index/outbound_call.lua::updated_destination_number"..updated_destination_number.."\n")
	fs_logger("notice","[index/outbound_call.lua::trunk_uuid"..trunk_uuid.."\n")
	local trunk_name = get_trunk_info(trunk_uuid)
	display_trunk_name =  trunk_name
	header_xml();
	table.insert(xml, [[<action application="set" data="hangup_after_bridge=true"/>]]);
	table.insert(xml, [[<action application="set" data="continue_on_fail=TRUE"/>]]);
	--if(user_array ~= nil and user_array ~= "" and user_array.account_code ~= undefined and user_array.account_code ~= nil)then
	if(tenant_account_code ~= nil and tenant_account_code ~= "" and tenant_account_code ~= undefined)then
		fs_logger("notice","[index/outbound_call.lua::accountcode"..tenant_account_code.."\n");
		table.insert(xml, [[<action application="set" data="sip_h_P-accountcode=]]..tenant_account_code..[["/>]]);
	end
	--if(tonumber(sip_destination_array.recording) == 0)then
	if(tonumber(custom_record_flag) == 0)then
		table.insert(xml, [[<action application="export" data="custom_recording=0"/>]]);	
		table.insert(xml, [[<action application="export" data="execute_on_answer=record_session $${recordings_dir}/${uuid}.wav"/>]]);
	end
	--else
	--	table.insert(xml, [[<action application="export" data="custom_recording=1"/>]]);
	--end
	callerid_xml();
	table.insert(xml, [[<action application="set" data="trunk_uuid=]]..trunk_uuid..[["/>]]);
	local leg_time_out = 30
	selectedcampaignuuid = params:getHeader("sip_h_X-selectedcampaignuuid");
	campaign_flag = params:getHeader("variable_sip_h_X-campaign_flag")
	if(selectedcampaignuuid ~= '' and selectedcampaignuuid ~= nil)then
		local campaign_info = get_campaign_details(selectedcampaignuuid,campaign_flag)
		if(campaign_info ~= nil and campaign_info ~= '' and campaign_info.timeout ~= '' )then
			leg_time_out = campaign_info.timeout
			fs_logger("notice","[index/outbound_call.lua::Outbound campaign Time-out"..leg_time_out.."\n")
		end
	end
	time_out_str = ",leg_timeout="..leg_time_out
	-- ::yaksh::
	local final_caller_id = ""

	----------------------------------------------------------
	-- Priority 0 : Caller ID selected by agent for manual call
	-- Only allowed if it is configured in campaign (Multi Caller IDs for Manual Calls)
	----------------------------------------------------------
	if(cli_route_mode)then
		-- CLI route : caller id already decided & formatted by matched route
		final_caller_id = cli_route.primary.cli
	else
		final_caller_id = resolve_manual_caller_id("[dialplan/outbound_call.lua]")
	end

	----------------------------------------------------------
	-- Priority 1 : Extension DID
	----------------------------------------------------------
	if(final_caller_id ~= "") then
		-- already resolved from agent selected manual caller id
	elseif(user_array ~= nil and ext_array ~= nil and ext_array.caller_id_number ~= nil	and ext_array.caller_id_number ~= "") then
		final_caller_id = ext_array.caller_id_number
		fs_logger("notice","[outbound_call.lua] Using User DID : "	.. final_caller_id)

	----------------------------------------------------------
	-- Priority 2 : Outgoing Rule DID
	----------------------------------------------------------
	elseif(outgoing_rule_caller_id ~= nil and outgoing_rule_caller_id ~= "") then
		final_caller_id = outgoing_rule_caller_id
		fs_logger("notice",	"[outbound_call.lua] Using Outgoing Rule DID : ".. final_caller_id)
	end

	-- INJECT: Set the resolved DID into the FreeSWITCH XML
	if (final_caller_id ~= "") then
			fs_logger("notice","[dialplan/outbound_call.lua][MultiCID] Final caller id set on call : "..final_caller_id)
			table.insert(xml, [[<action application="set" data="effective_caller_id_name=]]..final_caller_id..[["/>]]);
			table.insert(xml, [[<action application="set" data="effective_caller_id_number=]]..final_caller_id..[["/>]]);

	-- PRIORITY 3: Existing fallback logic (if neither User nor Campaign have a caller ID)
	elseif(tonumber(is_did_number) == 0 and tonumber(did_as_cid) == 0)then
			if(did_number == nil or did_number == '' )then
					did_number = params:getHeader("variable_forward_did_number");
					original_destination_number =  params:getHeader("variable_forward_did_number");
			end
			fs_logger("notice","[index/outbound_call.lua::DID number As Caller ID"..did_number.."\n")
			table.insert(xml, [[<action application="set" data="effective_caller_id_name=]]..did_number..[["/>]]);
			table.insert(xml, [[<action application="set" data="effective_caller_id_number=]]..did_number..[["/>]]);
	end

	--  UPDATED PRESENCE DATA WITH LEAD GROUP UUID
        table.insert(xml, [[<action application="set" data="presence_data=uuid=${uuid},tenant=]]..caller_tenant_uuid..[[,trunk=${trunk_uuid},user=]]..caller_user_uuid..[[,lead_management_uuid=]]..lead_management_uuid..[["/>]])
        table.insert(xml, [[<action application="export" data="presence_data=uuid=${uuid},tenant=]]..caller_tenant_uuid..[[,trunk=${trunk_uuid},user=]]..caller_user_uuid..[[,lead_management_uuid=]]..lead_management_uuid..[["/>]])

	-- END 
	-- === UAE G.711 codec override (added 2026-09-05, widened 2026-09-05) ===
	-- WebRTC A-leg negotiates OPUS on the 'external' profile. The B-leg inherits it via
	-- originator_codec, which outranks the profile's outbound-codec-prefs=PCMA,PCMU, so the
	-- UAE trunks receive an OPUS-only offer and reply 488 Not Acceptable Here.
	-- absolute_codec_string outranks originator_codec, so force G.711 on the UAE trunks only.
	-- Scoped by the gateway's proxy IP (10.180.38.x) and resolved live per call rather than
	-- hardcoded, because the portal rewrites the gateway list frequently.
	-- To revert: restore /root/outbound_call.lua.bak-allUAE-*  (.bak-codecfix-* = pre-fix)
	local g711_net = "Proxy%s+sip:10%.180%.38%."
	local g711_cache = {}
	local function codec_for(tn)
		if(tn == nil or tn == '')then return '' end
		if(g711_cache[tn] ~= nil)then return g711_cache[tn] end
		local result = ''
		-- only plain gateway names are passed to the API call
		if(tn:match("^[%w%._%-]+$"))then
			local ok, info = pcall(function()
				return freeswitch.API():execute("sofia", "status gateway "..tn)
			end)
			if(ok and info ~= nil and info:match(g711_net))then
				result = [[absolute_codec_string=^^:PCMA:PCMU,]]
			end
		end
		g711_cache[tn] = result
		return result
	end
	-- === end UAE G.711 codec override ===
	if(trunk_name ~= '' and trunk_name ~= nil)then
		table.insert(xml, [[<action application="bridge" data="{destination_number_harsh=]]..original_destination_number..[[}[]]..codec_for(trunk_name)..[[destination_number_harsh=]]..original_destination_number..[[,sip_h_P-tenant_uuid=]]..caller_tenant_uuid..[[,sip_h_P-user_uuid=]]..caller_user_uuid..[[,sip_h_P-extension_uuid=]]..caller_uuid..[[]]..time_out_str..[[]sofia/gateway/]]..trunk_name..[[/]]..updated_destination_number..[["/>]])	
	end
	if(failover_trunk_1_uuid ~= '' and failover_trunk_1_uuid ~= nil)then
		local trunk_name1 = get_trunk_info(failover_trunk_1_uuid)
		if(trunk_name1~= '' and trunk_name1 ~= nil)then
			local failover1_cid_xml = '';
			if(failover_trunk_1_call_id ~= nil and failover_trunk_1_call_id ~= '')then
				failover1_cid_xml = [[,effective_caller_id_number=]]..failover_trunk_1_call_id..[[,effective_caller_id_name=]]..failover_trunk_1_call_id..[[,origination_caller_id_number=]]..failover_trunk_1_call_id
			end
			table.insert(xml, [[<action application="bridge" data="[]]..codec_for(trunk_name1)..[[sip_h_P-original_destination_number=]]..original_destination_number..[[,sip_h_P-tenant_uuid=]]..caller_tenant_uuid..[[,sip_h_P-user_uuid=]]..caller_user_uuid..[[,sip_h_P-extension_uuid=]]..caller_uuid..[[]]..failover1_cid_xml..[[]]..time_out_str..[[]sofia/gateway/]]..trunk_name1..[[/]]..failover_1_destination_number..[["/>]])
		end
	end
	if(failover_trunk_2_uuid ~= '' and failover_trunk_2_uuid ~= nil)then
		local trunk_name2 = get_trunk_info(failover_trunk_2_uuid)
		if(trunk_name2~= '' and trunk_name2 ~= nil)then
			local failover2_cid_xml = '';
			if(failover_trunk_2_call_id ~= nil and failover_trunk_2_call_id ~= '')then
				failover2_cid_xml = [[,effective_caller_id_number=]]..failover_trunk_2_call_id..[[,effective_caller_id_name=]]..failover_trunk_2_call_id..[[,origination_caller_id_number=]]..failover_trunk_2_call_id
			end
			table.insert(xml, [[<action application="bridge" data="[]]..codec_for(trunk_name2)..[[sip_h_P-original_destination_number=]]..original_destination_number..[[,sip_h_P-tenant_uuid=]]..caller_tenant_uuid..[[,sip_h_P-user_uuid=]]..caller_user_uuid..[[,sip_h_P-extension_uuid=]]..caller_uuid..[[]]..failover2_cid_xml..[[]]..time_out_str..[[]sofia/gateway/]]..trunk_name2..[[/]]..failover_2_destination_number..[["/>]])
		end
	end
	footer_xml();
end
