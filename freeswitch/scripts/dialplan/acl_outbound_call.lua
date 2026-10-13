fs_logger("notice","[dialplan/acl_outbound_call.lua][XML_STRING] IN PSTN")
dofile(scripts_dir .. "common/cli_route.lua");

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
local outgoing_rules_collection = mongo_collection_name:getCollection "outgoing_rules"
local query = { tenant_uuid = caller_tenant_uuid, status = '0' }
local projection = { rules = true, uuid = true, route_type = true, no_cli_mode = true, _id = false }
local cursor = outgoing_rules_collection:find(query, { projection = projection })
-- iterate over the results
outgoing_rules_array = {}
local outgoing_rules_key=1;
for  outgoing_rules_details in cursor:iterator() do
    -- do something with the document
    outgoing_rules_array[outgoing_rules_key] = outgoing_rules_details;
outgoing_rules_key = outgoing_rules_key+1
end
local destination_length = string.len(destination_number);
if((outgoing_rules_array == '' or outgoing_rules_array[1] == nil) and tenant_info.outgoing_rule_uuid ~= '')then
	fs_logger("notice","[index/acl_outbound_call.lua:: Tenant Out going ID::"..tenant_info.outgoing_rule_uuid)
	local query = { uuid = tenant_info.outgoing_rule_uuid, status = '0' }
	local projection = { rules = true, uuid = true, route_type = true, no_cli_mode = true, _id = false }
	local cursor = outgoing_rules_collection:find(query, { projection = projection })
	-- iterate over the results
	outgoing_rules_array = {}
	local outgoing_rules_key=1;
	for  outgoing_rules_details in cursor:iterator() do
	    -- do something with the document
	    outgoing_rules_array[outgoing_rules_key] = outgoing_rules_details;
	outgoing_rules_key = outgoing_rules_key+1
	end

end
if(outgoing_rules_array == '' or outgoing_rules_array[1] == nil)then
	hangup_cause = "NO_ROUTE_DESTINATION";
	fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
	fs_logger("warning","[index/acl_outbound_call.lua:: User Group Not Found/ Outgoing rules Not Set3")
	dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
	return true;
end
local original_destination_number = destination_number
local custom_destination_number = destination_number
if(pstn_destination_number ~= nil)then
	fs_logger("warning","[index/acl_outbound_call.lua:: pstn_destination_number"..pstn_destination_number)
	destination_length = string.len(pstn_destination_number);
	custom_destination_number = pstn_destination_number
else
	destination_length = string.len(destination_number);
end
local loop_break = 0;
local updated_destination_number = '';
local trunk_uuid = '';
local failover_trunk_1_uuid = '';
local failover_trunk_2_uuid = '';
local failover_trunk_1_call_id = '';
local failover_trunk_2_call_id = '';
-- To number per failover leg (CLI route can format it differently), defaults to updated_destination_number
local failover_1_destination_number = '';
local failover_2_destination_number = '';
-- CLI based route (outgoing_rules.route_type = "cli") : CLI = agent selected caller id, else first route
local cli_route = nil
local acl_route_cli = nil
for outgoing_rules_param_key, outgoing_rules_param_value in ipairs( outgoing_rules_array ) do
	if(tostring(outgoing_rules_param_value.route_type or "") == "cli")then
		if(acl_route_cli == nil)then
			acl_route_cli = resolve_manual_caller_id("[dialplan/acl_outbound_call.lua]")
		end
		local route = cli_route_resolve(outgoing_rules_param_value, acl_route_cli, custom_destination_number, "[dialplan/acl_outbound_call.lua]")
		if(route.ok)then
			cli_route = route
			updated_destination_number = route.primary.to
			trunk_uuid = route.primary.trunk_uuid
			if(route.failovers[1] ~= nil)then
				failover_trunk_1_uuid = route.failovers[1].trunk_uuid
				failover_trunk_1_call_id = route.failovers[1].cli
				failover_1_destination_number = route.failovers[1].to
			end
			if(route.failovers[2] ~= nil)then
				failover_trunk_2_uuid = route.failovers[2].trunk_uuid
				failover_trunk_2_call_id = route.failovers[2].cli
				failover_2_destination_number = route.failovers[2].to
			end
			loop_break = 1;
			break;
		end
	elseif(outgoing_rules_param_value.rules ~= nil and outgoing_rules_param_value.rules ~= '')then
		for param_key, param_value in ipairs( outgoing_rules_param_value.rules ) do
			fs_logger("notice","[dialplan/acl_outbound_call.lua] param_key "..param_key.."\n")			
			fs_logger("notice","[dialplan/acl_outbound_call.lua]destination_length "..destination_length.."\n")
			fs_logger("notice","[dialplan/acl_outbound_call.lua]destination_length "..param_value['prepend'].."\n")	
			if((param_value.prefix ~= '' or param_value.prefix == '*') and param_value.trunk_uuid ~= '' and (tonumber(destination_length) == tonumber(param_value.length) or tonumber(param_value.length) == 0))then
				local prefix_length = string.len(param_value.prefix);
				local destination_prefix = string.sub(custom_destination_number, 1, tonumber(prefix_length))
				fs_logger("notice","[dialplan/acl_outbound_call.lua] length: "..param_value.length.." -- prefix: "..param_value.prefix.." -- strip: "..param_value.strip.." -- prepend: "..param_value.prepend.." -- prefix_length: "..prefix_length.." --  destination_prefix: "..destination_prefix.."\n")
				if(destination_prefix == param_value.prefix or param_value.prefix == '*')then
					fs_logger("notice","[dialplan/acl_outbound_call.lua] destination_prefix Matched\n")
					fs_logger("notice","[dialplan/acl_outbound_call.lua] custom_destination_number:"..custom_destination_number.."\n")
					updated_destination_number = do_number_translation(param_value.strip,custom_destination_number)
					trunk_uuid = param_value.trunk_uuid;
					failover_trunk_1_uuid = param_value.failover_trunk_1_uuid;
					failover_trunk_2_uuid = param_value.failover_trunk_2_uuid;
					failover_trunk_1_call_id = param_value.failover_trunk_1_call_id;
					failover_trunk_2_call_id = param_value.failover_trunk_2_call_id;
					fs_logger("notice","[dialplan/acl_outbound_call.lua] updated_destination_number:"..updated_destination_number.."\n")
					updated_destination_number = param_value.prepend..updated_destination_number
					fs_logger("notice","[dialplan/acl_outbound_call.lua] updated_destination_number:"..updated_destination_number.."\n")
					loop_break = 1;					
					break;				
				end
			end
		end
		if(tonumber(loop_break) == 1)then
			break;		
		end
	end	
end
destination_number = updated_destination_number
if(failover_1_destination_number == '')then failover_1_destination_number = updated_destination_number end
if(failover_2_destination_number == '')then failover_2_destination_number = updated_destination_number end
if(updated_destination_number == '' or trunk_uuid == '')then
	hangup_cause = "NO_ROUTE_DESTINATION";
	fail_audio_file = sounds_dir..'/pbx/badnumber.wav';
	fs_logger("warning","[index/acl_outbound_call.lua:: Outgoing rules Not Set")
	dofile(scripts_dir .. "dialplan/fail_xml_dialplan.lua");
	return true;
else
	fs_logger("notice","[index/acl_outbound_call.lua::updated_destination_number"..updated_destination_number.."\n")
	fs_logger("notice","[index/acl_outbound_call.lua::trunk_uuid"..trunk_uuid.."\n")
	local trunk_name = get_trunk_info(trunk_uuid)
	display_trunk_name =  trunk_name

	header_xml();
	callerid_xml();
	local leg_time_out = 30
	selectedcampaignuuid = params:getHeader("sip_h_X-selectedcampaignuuid");
	if(selectedcampaignuuid ~= '' and selectedcampaignuuid ~= nil)then
		local outbound_campaign_info = get_campaign_details(selectedcampaignuuid)
		if(outbound_campaign_info ~= nil and outbound_campaign_info ~= '' and outbound_campaign_info.timeout ~= '' )then
			leg_time_out = outbound_campaign_info.timeout
			fs_logger("notice","[index/outbound_call.lua::Outbound campaign Time-out"..leg_time_out.."\n")
		end
	end
	time_out_str = "leg_timeout="..leg_time_out
	if(tonumber(is_did_number) == 0 and tonumber(did_as_cid) == 0)then
		if(did_number == nil or did_number == '' )then
                        did_number = params:getHeader("variable_forward_did_number");
                        original_destination_number =  params:getHeader("variable_forward_did_number");
                end	
		fs_logger("notice","[index/acl_outbound_call.lua::DID number As Caller ID"..did_number.."\n")
		table.insert(xml, [[<action application="set" data="effective_caller_id_name=]]..did_number..[["/>]]);
		table.insert(xml, [[<action application="set" data="effective_caller_id_number=]]..did_number..[["/>]]);
	end

	-- Multi Caller IDs for Manual Calls : agent selected caller id overrides caller id set above
	local manual_final_cid = ""
	if(cli_route ~= nil)then
		-- CLI route : caller id already decided & formatted by matched route
		manual_final_cid = cli_route.primary.cli
	else
		manual_final_cid = resolve_manual_caller_id("[dialplan/acl_outbound_call.lua]")
	end
	if(manual_final_cid ~= "")then
		fs_logger("notice","[dialplan/acl_outbound_call.lua][MultiCID] Final caller id set on call : "..manual_final_cid)
		table.insert(xml, [[<action application="set" data="effective_caller_id_name=]]..manual_final_cid..[["/>]]);
		table.insert(xml, [[<action application="set" data="effective_caller_id_number=]]..manual_final_cid..[["/>]]);
	end
	table.insert(xml, [[<action application="set" data="hangup_after_bridge=true"/>]]);
	table.insert(xml, [[<action application="set" data="continue_on_fail=TRUE"/>]]);
	
	--if(tonumber(sip_destination_array.recording) == 0)then
	if(tonumber(custom_record_flag) == 0)then
		table.insert(xml, [[<action application="export" data="custom_recording=0"/>]]);	
		table.insert(xml, [[<action application="export" data="execute_on_answer=record_session $${recordings_dir}/${uuid}.wav"/>]]);
	end
	table.insert(xml, [[<action application="set" data="did_pstn=0"/>]]);		
	--else
	--	table.insert(xml, [[<action application="export" data="custom_recording=1"/>]]);
	--end

	if(trunk_name ~= '' and trunk_name ~= nil)then
		table.insert(xml, [[<action application="bridge" data="[]]..time_out_str..[[]sofia/gateway/]]..trunk_name..[[/]]..updated_destination_number..[["/>]])	
	end
	if(failover_trunk_1_uuid ~= '' and failover_trunk_1_uuid ~= nil)then
		local trunk_name1 = get_trunk_info(failover_trunk_1_uuid)
		if(trunk_name1~= '' and trunk_name1 ~= nil)then
			local failover1_cid_xml = '';
			if(failover_trunk_1_call_id ~= nil and failover_trunk_1_call_id ~= '')then
				failover1_cid_xml = [[effective_caller_id_number=]]..failover_trunk_1_call_id..[[,effective_caller_id_name=]]..failover_trunk_1_call_id..[[,origination_caller_id_number=]]..failover_trunk_1_call_id..[[,]]
			end
			table.insert(xml, [[<action application="bridge" data="[]]..failover1_cid_xml..time_out_str..[[]sofia/gateway/]]..trunk_name1..[[/]]..failover_1_destination_number..[["/>]])
		end
	end
	if(failover_trunk_2_uuid ~= '' and failover_trunk_2_uuid ~= nil)then
		local trunk_name2 = get_trunk_info(failover_trunk_2_uuid)
		if(trunk_name2~= '' and trunk_name2 ~= nil)then
			local failover2_cid_xml = '';
			if(failover_trunk_2_call_id ~= nil and failover_trunk_2_call_id ~= '')then
				failover2_cid_xml = [[effective_caller_id_number=]]..failover_trunk_2_call_id..[[,effective_caller_id_name=]]..failover_trunk_2_call_id..[[,origination_caller_id_number=]]..failover_trunk_2_call_id..[[,]]
			end
			table.insert(xml, [[<action application="bridge" data="[]]..failover2_cid_xml..time_out_str..[[]sofia/gateway/]]..trunk_name2..[[/]]..failover_2_destination_number..[["/>]])
		end
	end
	footer_xml();
end

