-- Lightweight proxy client for the singleton Mongo daemon (see
-- mongo_daemon.lua). Exposes the same getCollection()/find()/insert()/
-- update()/remove()/aggregate() surface as a real mongo.Client database
-- handle, so every existing dialplan script that uses
-- `mongo_collection_name:getCollection(...)` keeps working unmodified --
-- only db.lua changes, to return this proxy instead of creating its own
-- per-call mongo.Client() connection.

local mongo = require 'mongo'
local socket = require 'socket.unix'

if type(scripts_dir) ~= "string" then scripts_dir = '/usr/local/freeswitch/scripts/' end
dofile(scripts_dir .. "common/mongo_config.lua")

local function log_err(msg)
	pcall(function() freeswitch.consoleLog("err", "[mongo_client] " .. msg .. "\n") end)
end

local function send_request(req)
	local sock = socket()
	sock:settimeout(5)

	local ok, err = sock:connect(mongo_proxy_socket)
	if not ok then
		sock:close()
		return nil, "connect failed: " .. tostring(err)
	end

	local payload = tostring(mongo.BSON(req))
	local sent, serr = sock:send(#payload .. "\n" .. payload)
	if not sent then
		sock:close()
		return nil, "send failed: " .. tostring(serr)
	end

	local len_line, lerr = sock:receive("*l")
	if not len_line then
		sock:close()
		return nil, "read length failed: " .. tostring(lerr)
	end

	local len = tonumber(len_line)
	if not len then
		sock:close()
		return nil, "bad length header: " .. tostring(len_line)
	end

	local body, berr = sock:receive(len)
	sock:close()
	if not body then
		return nil, "read body failed: " .. tostring(berr)
	end

	local resp = mongo.BSON(body):value()
	if not resp.ok then
		return nil, resp.error or "unknown proxy error"
	end
	return resp
end

local Cursor = {}
Cursor.__index = Cursor

function Cursor:iterator()
	local docs = self.docs
	local i = 0
	return function()
		i = i + 1
		return docs[i]
	end
end

local function empty_cursor()
	return setmetatable({ docs = {} }, Cursor)
end

local Collection = {}
Collection.__index = Collection

function Collection:find(query, opts)
	local resp, err = send_request{ op = "find", collection = self.name, query = query, opts = opts }
	if not resp then
		log_err("find on '" .. self.name .. "' failed: " .. tostring(err))
		return empty_cursor()
	end
	return setmetatable({ docs = resp.docs or {} }, Cursor)
end

function Collection:aggregate(pipeline)
	local resp, err = send_request{ op = "aggregate", collection = self.name, query = pipeline }
	if not resp then
		log_err("aggregate on '" .. self.name .. "' failed: " .. tostring(err))
		return empty_cursor()
	end
	return setmetatable({ docs = resp.docs or {} }, Cursor)
end

function Collection:insert(doc)
	local resp, err = send_request{ op = "insert", collection = self.name, doc = doc }
	if not resp then
		log_err("insert on '" .. self.name .. "' failed: " .. tostring(err))
		return nil, err
	end
	return true
end

function Collection:update(query, update, opts)
	local resp, err = send_request{ op = "update", collection = self.name, query = query, update = update, opts = opts }
	if not resp then
		log_err("update on '" .. self.name .. "' failed: " .. tostring(err))
		return nil, err
	end
	return true
end

function Collection:remove(query, opts)
	local resp, err = send_request{ op = "remove", collection = self.name, query = query, opts = opts }
	if not resp then
		log_err("remove on '" .. self.name .. "' failed: " .. tostring(err))
		return nil, err
	end
	return true
end

local Database = {}
Database.__index = Database

function Database:getCollection(name)
	return setmetatable({ name = name }, Collection)
end

return setmetatable({}, Database)
