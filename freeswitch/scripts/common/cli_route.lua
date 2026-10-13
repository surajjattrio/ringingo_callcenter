----------------------------------------------------------
-- CLI based outgoing route (outgoing_rules.route_type = "cli")
-- Same logic as API : ringingo-api src/modules/outgoing-rules/utils/cli-route.ts (keep both in sync)
--
-- CLI given   : first row whose match_cli has this CLI and CLI + To lengths are allowed,
--               no such row -> call fails (CLI not configured)
-- CLI missing : first row whose To length is allowed and has CLIs with allowed length
--               rule.no_cli_mode = "first"       -> first such CLI of that row
--               rule.no_cli_mode = "round_robin" -> CLIs of that row in turn (outgoing_rules.cli_rr_counter,
--                                                   one counter per rule, shared with API)
-- Each row    : primary trunk + up to 2 failover trunks, each leg with its own CLI / To format
--               (keep last N digits + prefix)
----------------------------------------------------------

function cli_route_digits(value)
	if(value == nil)then return "" end
	return (tostring(value):gsub("%D", ""))
end

-- Keep last N digits (if N set and number is longer) and add prefix
function cli_route_format(value, keep_last, prefix)
	local digits = cli_route_digits(value)
	local n = tonumber(keep_last or "")
	if(n ~= nil and n > 0 and string.len(digits) > n)then
		digits = string.sub(digits, -n)
	end
	return tostring(prefix or "")..digits
end

-- Same CLI in any format : +917553535469 / 917553535469 / 07553535469 / 7553535469
function cli_route_same_cli(a, b)
	local x = cli_route_digits(a):gsub("^0+", "")
	local y = cli_route_digits(b):gsub("^0+", "")
	if(x == "" or y == "")then return false end
	if(x == y)then return true end
	local shorter, longer = x, y
	if(string.len(x) > string.len(y))then shorter, longer = y, x end
	return string.len(shorter) >= 7 and string.sub(longer, -string.len(shorter)) == shorter
end

local function cli_route_list(value)
	local list = {}
	if(type(value) == "table")then
		for _, item in pairs(value) do
			local v = tostring(item):gsub("^%s+", ""):gsub("%s+$", "")
			if(v ~= "")then table.insert(list, v) end
		end
	elseif(value ~= nil)then
		for item in string.gmatch(tostring(value), "[^,]+") do
			local v = item:gsub("^%s+", ""):gsub("%s+$", "")
			if(v ~= "")then table.insert(list, v) end
		end
	end
	return list
end

function cli_route_length_allowed(value, allowed)
	local list = cli_route_list(allowed)
	if(#list == 0)then return true end
	local len = tostring(string.len(cli_route_digits(value)))
	for _, item in ipairs(list) do
		if(item == len)then return true end
	end
	return false
end

local function cli_route_leg(trunk_uuid, cli, to, row, key)
	return {
		trunk_uuid = trunk_uuid,
		cli = cli_route_format(cli, row[key.."cli_keep_last"], row[key.."cli_prefix"]),
		to = cli_route_format(to, row[key.."to_keep_last"], row[key.."to_prefix"]),
	}
end

local function cli_route_build(row, row_index, route_cli, to_number, log_tag)
	local result = { ok = true, row_index = row_index, failovers = {} }
	result.primary = cli_route_leg(row.trunk_uuid, route_cli, to_number, row, "")
	for n = 1, 2 do
		local failover_trunk = row["failover_trunk_"..n.."_uuid"]
		if(failover_trunk ~= nil and failover_trunk ~= "")then
			local failover_cli = row["failover_trunk_"..n.."_call_id"]
			if(failover_cli == nil or failover_cli == "")then failover_cli = route_cli end
			table.insert(result.failovers, cli_route_leg(failover_trunk, failover_cli, to_number, row, "failover_trunk_"..n.."_"))
		end
	end
	fs_logger("notice", log_tag.."[CLIRoute] Matched route "..row_index.." | trunk : "..result.primary.trunk_uuid.." | CLI : "..result.primary.cli.." | To : "..result.primary.to)
	for n, leg in ipairs(result.failovers) do
		fs_logger("notice", log_tag.."[CLIRoute] Failover "..n.." | trunk : "..leg.trunk_uuid.." | CLI : "..leg.cli.." | To : "..leg.to)
	end
	return result
end

-- Next round robin counter of outgoing rule (atomic $inc, shared with API). Returns 0 on any error.
function cli_route_next_round_robin(rule_uuid, log_tag)
	if(rule_uuid == nil or rule_uuid == "")then return 0 end
	local ok, counter = pcall(function()
		local reply = mongo_collection_name:getCollection("outgoing_rules"):findAndModify(
			{ uuid = tostring(rule_uuid) },
			{ update = { ["$inc"] = { cli_rr_counter = 1 } }, new = true, fields = { cli_rr_counter = true } }
		)
		if(reply == nil)then return 0 end
		if(type(reply) == "userdata" and reply.value ~= nil)then reply = reply:value() end
		local doc = reply
		if(type(reply) == "table" and reply.value ~= nil)then doc = reply.value end
		if(type(doc) ~= "table")then return 0 end
		return tonumber(tostring(doc.cli_rr_counter or 0)) or 0
	end)
	if(not ok)then
		fs_logger("warning", (log_tag or "[cli_route.lua]").."[CLIRoute] Round robin counter error : "..tostring(counter))
		return 0
	end
	return counter
end

-- Returns { ok = true, row_index, primary = leg, failovers = { leg, ... } } or { ok = false, reason }
function cli_route_resolve(rule, cli, to_number, log_tag)
	log_tag = log_tag or "[cli_route.lua]"
	local has_cli = cli_route_digits(cli) ~= ""
	fs_logger("notice", log_tag.."[CLIRoute] Resolve route | CLI : '"..tostring(cli or "").."' | To : '"..tostring(to_number or "").."' | No CLI mode : "..tostring(rule and rule.no_cli_mode or "first"))
	if(rule == nil or type(rule.rules) ~= "table")then
		return { ok = false, reason = "CLI route has no rows" }
	end
	for row_index, row in ipairs(rule.rules) do
		if(row.trunk_uuid ~= nil and row.trunk_uuid ~= "")then
			if(not cli_route_length_allowed(to_number, row.to_allowed_lengths))then
				fs_logger("notice", log_tag.."[CLIRoute] Route "..row_index.." skipped : To length not allowed")
			else
				local row_clis = cli_route_list(row.match_cli)
				if(has_cli)then
					for _, row_cli in ipairs(row_clis) do
						if(cli_route_same_cli(row_cli, cli))then
							if(cli_route_length_allowed(cli, row.cli_allowed_lengths))then
								return cli_route_build(row, row_index, tostring(cli), to_number, log_tag)
							end
							fs_logger("notice", log_tag.."[CLIRoute] Route "..row_index.." skipped : CLI length not allowed")
							break
						end
					end
				else
					-- No CLI selected : first route having CLIs with allowed length
					local candidates = {}
					for _, row_cli in ipairs(row_clis) do
						if(cli_route_length_allowed(row_cli, row.cli_allowed_lengths))then table.insert(candidates, row_cli) end
					end
					if(#candidates > 0)then
						local pick = 1
						if(tostring(rule.no_cli_mode or "") == "round_robin" and #candidates > 1)then
							local counter = cli_route_next_round_robin(rule.uuid, log_tag)
							if(counter > 0)then pick = ((counter - 1) % #candidates) + 1 end
							fs_logger("notice", log_tag.."[CLIRoute] Round robin counter : "..counter.." -> CLI "..pick.." of "..#candidates)
						end
						return cli_route_build(row, row_index, candidates[pick], to_number, log_tag)
					end
				end
			end
		end
	end
	local reason = "No CLI route row allowed for To number "..tostring(to_number or "")
	if(has_cli)then reason = "CLI "..tostring(cli).." not configured (or CLI/To length not allowed) in CLI route" end
	fs_logger("warning", log_tag.."[CLIRoute] "..reason)
	return { ok = false, reason = reason }
end
