fs_logger("notice","[dialplan/call_queue.lua][XML_STRING] IN CALL QUEUE")
local call_queue_collection = mongo_collection_name:getCollection "call_queue"
local call_queue_agent_collection = mongo_collection_name:getCollection "call_queue_agent"
local user_collection = mongo_collection_name:getCollection "user"
local extension_collection = mongo_collection_name:getCollection "extensions"
-- local sticky_agent = mongo_collection_name:getCollection "sticky_agent"

local query = { uuid = did_routing_uuid, status = '0' }
local projection = { uuid = true,call_welcome_greeting_uuid=true,for_pbx=true, _id = false, fail_over_routing_name=true, failover_routing_options=true, failover_routing_type=true}
local cursor = call_queue_collection:find(query, { projection = projection })
-- iterate over the results
call_queuearray = ''
for  call_queue_details in cursor:iterator() do
    call_queuearray = call_queue_details
end

if(call_queuearray == '')then
	fs_logger("warning","[dialplan/call_queue.lua:: Call Queue: NIL::")
	return true;
end
	call_queue_uuid = call_queuearray.uuid
	

	

header_xml();
callerid_xml();
	if(call_queuearray.for_pbx ~= nil and tonumber(call_queuearray.for_pbx) == 0) then
		fs_logger("warning","[dialplan/call_queue.lua:: pbx call queue::")
		local query = {call_queue_uuid = did_routing_uuid}
		local call_agent_cursor = call_queue_agent_collection:find(query)
		call_queue_agent_array = {}
		call_queue_agent_key = 1
		for  call_queue_agent_details in call_agent_cursor:iterator() do
    			call_queue_agent_array[call_queue_agent_key] = call_queue_agent_details
    			call_queue_agent_key = call_queue_agent_key + 1
		end
		if call_queue_agent_array == "" then
			fs_logger("warning","[dialplan/call_queue.lua:: call queue agent not found::")
		else
			for _,param_value in ipairs(call_queue_agent_array) do
				fs_logger("warning","[dialplan/call_queue.lua:: call queue agent not found::"..param_value['user_uuid'])
				--if param_value['user_uuid'] ~= "" then
					local user_query = {uuid = param_value['user_uuid']}
					local user_cursor = user_collection:find(user_query)
					user_array = ""
					for user_details in user_cursor:iterator() do
						user_array = user_details
					end
					if user_array == "" then
						fs_logger("warning","[dialplan/call_queue.lua:: user array empty::")
					end
				
					if (user_array ~= "" and type(user_array.callkit_token) ~= "table" and user_array.callkit_token ~= nil and user_array.callkit_token ~= "" and user_array.callkit_token ~= "null" and user_array.mobile_type ~= nil and user_array.mobile_type ~= "" and user_array.mobile_type ~= "null")then
						fs_logger("warning","[dialplan/call_queue.lua:: call queue agent not found::"..user_array.uuid)
						local extension_query = {uuid = user_array.default_extension}
						local extension_cursor = extension_collection:find(extension_query)
						extension_array = ""
						for extension_details in extension_cursor:iterator() do
							extension_array = extension_details
						end
						if extension_array ~= "" then
							if notify then
								local notify_call_type = "call_queue"
							notify(xml,user_array.uuid,user_array.callkit_token,user_array.mobile_type,callerid_name,callerid_number,extension_array.username,from_domain,notify_call_type)
							end
						end
					end
				--end			
			end
		end
	end

table.insert(xml, [[<action application="answer"/>]])
if(call_queuearray.call_welcome_greeting_uuid ~= '') then
	table.insert(xml, [[<action application="playback" data="]]..upload_file_path..[[/]]..call_queuearray.call_welcome_greeting_uuid..[[.wav"/>]]);
end
--if(tonumber(destination_number) == 123456)then

if(call_queuearray.for_pbx ~= nil and tonumber(call_queuearray.for_pbx) == 1) then

	if callerid_number == nil or callerid_number == '' then
		callerid_number = params:getHeader("Caller-Caller-ID-Number")
	end
		fs_logger("warning","[dialplan/call_queue.lua:: callerid_number::"..callerid_number)
	local callerid = skip_special_char(callerid_number)
		fs_logger("warning","[dialplan/call_queue.lua:: callerid::"..callerid)
	local lead_info = get_lead_info_for_queue(callerid)
	local lead_name = ""
	local lead_uuid = ""
	if(lead_info ~= nil and lead_info ~= "")then
		if(lead_array.last_name ~= nil and lead_array.last_name ~= "")then
			lead_name = lead_array.first_name.."__"..lead_array.last_name
		else
			lead_name = lead_array.first_name
		end
		lead_uuid = lead_info.lead_management_uuid
		fs_logger("warning","[dialplan/call_queue.lua:: Lead found::")
	else
		local str_uuid = generateUUIDv4()
		local iso_time = os.date("!%Y-%m-%dT%H:%M:%S+00:00")
		local lead_mgmt_collection = mongo_collection_name:getCollection "lead_management"
		local datatoinsert = {phone_number = callerid,custom_phone_number = callerid,first_name = "Anonymous",last_name = "Anonymous",lead_management_uuid=str_uuid,tenant_uuid = caller_tenant_uuid, createdAt = iso_time, updatedAt = iso_time}
		fs_logger("warning","[dialplan/call_queue.lua:: Lead not found and insert str_uuid::"..str_uuid)		
		fs_logger("warning","[dialplan/call_queue.lua:: Lead not found and insert::")		
		lead_mgmt_collection:insert(datatoinsert)
		lead_uuid = str_uuid
		lead_name = "Anonymous"
		
	end
	table.insert(xml, [[<action application="export" data="sip_h_X-Custom-Callid=]]..params:getHeader("variable_sip_call_id")..[["/>]]);
	table.insert(xml, [[<action application="set" data="sip_h_X-Custom-Callid=]]..params:getHeader("variable_sip_call_id")..[["/>]]);
	
	table.insert(xml, [[<action application="set" data="sip_h_X-did_number=${destination_number}"/>]]);
    table.insert(xml, [[<action application="export" data="sip_h_X-did_number=${destination_number}"/>]]);

	table.insert(xml, [[<action application="set" data="original_caller_id_number=]]..params:getHeader('Caller-Caller-ID-Number')..[["/>]]);
	table.insert(xml, [[<action application="export" data="original_caller_id_number=]]..params:getHeader('Caller-Caller-ID-Number')..[["/>]]);

	table.insert(xml, [[<action application="export" data="sip_h_X-lead_name=]]..lead_name..[["/>]]);
	table.insert(xml, [[<action application="export" data="sip_h_X-Leaduuid=]]..lead_uuid..[["/>]]);
	table.insert(xml, [[<action application="set" data="sip_h_X-lead_name=]]..lead_name..[["/>]]);
	table.insert(xml, [[<action application="set" data="sip_h_X-Leaduuid=]]..lead_uuid..[["/>]]);
	table.insert(xml, [[<action application="export" data="sip_h_X-inbound_campaign_flag=true"/>]]);
	table.insert(xml, [[<action application="set" data="sip_h_X-inbound_campaign_flag=true"/>]]);
	table.insert(xml, [[<action application="export" data="sip_h_X-tenant_uuid=]]..caller_tenant_uuid..[["/>]]);
	table.insert(xml, [[<action application="set" data="sip_h_X-tenant_uuid=]]..caller_tenant_uuid..[["/>]]);
	table.insert(xml, [[<action application="set" data="cc_export_vars=sip_h_X-Custom-Callid,custom_callid,sip_h_X-lead_name,sip_h_X-Leaduuid,sip_h_X-inbound_campaign_flag,sip_h_X-tenant_uuid,sip_h_X-did_number"/>]]);
	table.insert(xml, [[<action application="export" data="presence_data=tenant=]]..caller_tenant_uuid..[[,lead_management_uuid=]]..lead_uuid..[["/>]]);
	
end
	table.insert(xml, [[<action application="set" data="pbx_feature=call_queue"/>]]);
	-- table.insert(xml, [[<action application="set" data="result=${luarun(common/callcenter-announce-position.lua ${uuid} ]]..call_queuearray.uuid..[[@default 30000)}"/>]])
	table.insert(xml, [[<action application="set" data="hangup_after_bridge=true"/>]])
	table.insert(xml, [[<action application="set" data="continue_on_fail=true"/>]])
	table.insert(xml, [[<action application="export" data="call_queue_id=]]..call_queuearray.uuid..[["/>]])
	table.insert(xml, [[<action application="callcenter" data="]]..call_queuearray.uuid..[[@default"/>]])
	-- table.insert(xml, [[<action application="hangup" data="NORMAL_CLEARING"/>]]);
--else
--	table.insert(xml, [[<action application="callcenter" data="57bd6da2-bf27-11ed-afa1-0242ac120004@default"/>]])
--end

-- Queue Timeout Failover Routing
local failover_routing_type    = call_queuearray.failover_routing_type
local failover_routing_options = call_queuearray.failover_routing_options
local fail_over_routing_name   = call_queuearray.fail_over_routing_name

fs_logger("warning","[call_queue.lua] Queue Timeout Failover -> type:"..tostring(failover_routing_type).." options:"..tostring(failover_routing_options).." name:"..tostring(fail_over_routing_name))
if(failover_routing_type ~= nil and failover_routing_type ~= '' and failover_routing_options ~= nil and failover_routing_options ~= '')then

        fs_logger("warning","[call_queue.lua] Queue Timeout Failover -> type:"..tostring(failover_routing_type).." options:"..tostring(failover_routing_options).." name:"..tostring(fail_over_routing_name))
        table.insert(xml, [[<action application="log" data="INFO Queue timeout failover -> ]]..tostring(fail_over_routing_name)..[[ (type ]]..tostring(failover_routing_type)..[[)"/>]])

        --FOR Extension (type 1)
        -- failover_routing_options is the extension's uuid (matches how custom_routing_forwarding
        -- routes type 1 -> extensions.lua). extensions.lua itself expects sip_destination_array to
        -- already be resolved by the router before it runs, so we resolve the username ourselves here.
        if(tonumber(failover_routing_type) == 1)then
                local ext_query = { uuid = failover_routing_options, status = '0' }
                local ext_projection = { username = true, _id = false }
                local ext_cursor = extension_collection:find(ext_query, { projection = ext_projection })
                local ext_array = ''
                for ext_details in ext_cursor:iterator() do
                        ext_array = ext_details
                end
                if(ext_array ~= '' and ext_array.username ~= nil and ext_array.username ~= '')then
                        table.insert(xml, [[<action application="set" data="ringback=%(2000,4000,440,480)"/>]])
                        table.insert(xml, [[<action application="bridge" data="[leg_timeout=30]user/]]..ext_array.username..[[@]]..from_domain..[["/>]])
                else
                        fs_logger("warning","[call_queue.lua] Failover extension lookup failed for uuid:"..tostring(failover_routing_options))
                end
        end

        --FOR IVR (type 2)
        -- Mirrors the action sequence in dialplan/ivr.lua, minus header_xml/callerid_xml/answer
        -- (we're already mid-document and the call is already answered from the queue flow above).
        if(tonumber(failover_routing_type) == 2)then
                table.insert(xml, [[<action application="set" data="hold_music=call-queue.wav"/>]])
                table.insert(xml, [[<action application="bridge_export" data="hold_music=call-queue.wav"/>]])
                table.insert(xml, [[<action application="set" data="ringback=%(2000,4000,440,480)"/>]])
                table.insert(xml, [[<action application="set" data="pbx_feature=ivr"/>]])
                table.insert(xml, [[<action application="set" data="ivr_group_uuid=]]..failover_routing_options..[["/>]])
                if(original_destination_number ~= nil)then
                        table.insert(xml, [[<action application="set" data="original_destination_number=]]..original_destination_number..[["/>]])
                end
                table.insert(xml, [[<action application="ivr" data="]]..failover_routing_options..[["/>]])
        end

        --FOR Time-Condition (type 3)
        if(tonumber(failover_routing_type) == 3)then
                -- TODO: align with time_condition.lua action syntax once available
                table.insert(xml, [[<action application="transfer" data="]]..failover_routing_options..[[ XML default"/>]])
        end

        --FOR Conference (type 4)
        if(tonumber(failover_routing_type) == 4)then
                table.insert(xml, [[<action application="conference" data="]]..failover_routing_options..[[@default"/>]])
        end

        --FOR Call Queue (type 5)
        if(tonumber(failover_routing_type) == 5)then
                table.insert(xml, [[<action application="set" data="pbx_feature=call_queue"/>]])
                table.insert(xml, [[<action application="export" data="call_queue_id=]]..failover_routing_options..[["/>]])
                table.insert(xml, [[<action application="callcenter" data="]]..failover_routing_options..[[@default"/>]])
        end

        --FOR Ring Group (type 6)
        -- failover_routing_options is the ring group's uuid. Mirrors ring_group.lua's bridge_string
        -- construction for internal extensions (extension_type == 0), skipping the external/sofia
        -- branch, lead/CRM lookup, and push-notify logic that only apply to a fresh inbound call.
        if(tonumber(failover_routing_type) == 6)then
                local rg_collection = mongo_collection_name:getCollection "ring_group"
                local rg_query = { uuid = failover_routing_options, status = '0' }
                local rg_projection = { extension_list = true, type = true, timeout = true, _id = false }
                local rg_cursor = rg_collection:find(rg_query, { projection = rg_projection })
                local rg_array = ''
                for rg_details in rg_cursor:iterator() do
                        rg_array = rg_details
                end
                if(rg_array ~= '' and rg_array.extension_list ~= nil)then
                        local rg_timeout = rg_array.timeout
                        if(rg_timeout == nil)then rg_timeout = 30 end
                        local rg_separator = '|'
                        if(tonumber(rg_array.type) == 1)then rg_separator = ',' end
                        local rg_bridge_string = '{ignore_early_media=true}'
                        for _, rg_member in ipairs(rg_array.extension_list) do
                                if(tonumber(rg_member['extension_type']) == 0)then
                                        rg_bridge_string = rg_bridge_string.."[call_timeout="..rg_timeout.."]user/"..rg_member['extension'].."@"..from_domain..rg_separator
                                end
                        end
                        table.insert(xml, [[<action application="set" data="ringback=%(2000,4000,440,480)"/>]])
                        table.insert(xml, [[<action application="bridge" data="]]..rg_bridge_string..[["/>]])
                else
                        fs_logger("warning","[call_queue.lua] Failover ring group lookup failed for uuid:"..tostring(failover_routing_options))
                end
        end

        --FOR Voicemail (type 7)
        if(tonumber(failover_routing_type) == 7)then
                table.insert(xml, [[<action application="answer"/>]])
                table.insert(xml, [[<action application="voicemail" data="default ${domain_name} ]]..failover_routing_options..[["/>]])
        end

        --FOR PSTN (type 8)
        if(tonumber(failover_routing_type) == 8)then
                -- failover_routing_options expected as "gateway|number" or just a number on the default gateway
                local pstn_gateway, pstn_number = failover_routing_options:match("^([^|]+)|(.+)$")
                if(pstn_gateway ~= nil and pstn_number ~= nil)then
                        table.insert(xml, [[<action application="bridge" data="sofia/gateway/]]..pstn_gateway..[[/]]..pstn_number..[["/>]])
                else
                        table.insert(xml, [[<action application="bridge" data="sofia/gateway/${default_gateway}/]]..failover_routing_options..[["/>]])
                end
        end

        --FOR Playback (type 10)
        if(tonumber(failover_routing_type) == 10)then
                table.insert(xml, [[<action application="answer"/>]])
                table.insert(xml, [[<action application="playback" data="]]..upload_file_path..[[/]]..failover_routing_options..[[.wav"/>]])
        end
else
        fs_logger("warning","[call_queue.lua] No failover routing configured on this queue")
end

footer_xml();

