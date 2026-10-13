-- Singleton MongoDB connection holder for FreeSWITCH.
--
-- mod_lua's xml-handler-script (main.lua) runs in a brand new Lua VM for
-- every single call (lua_fetch()/lua_init() in mod_lua.cpp), so a plain Lua
-- global can never persist a live mongo.Client() across calls. Previously
-- every call created its own mongo.Client(), and under heavy concurrent call
-- volume many threads raced on the same process-wide /dev/shm/mongoc-<pid>
-- SASL shared memory segment, crashing FreeSWITCH with SIGBUS.
--
-- This script is launched once at FreeSWITCH startup (see lua.conf.xml's
-- startup-script) and lives for the life of the process, holding ONE Mongo
-- connection and serving every call's query over a local Unix socket.
-- Per-call scripts talk to it via common/mongo_client.lua.

scripts_dir = '/usr/local/freeswitch/scripts/'
dofile(scripts_dir .. "common/mongo_config.lua")

local mongo = require 'mongo'
local socket = require 'socket.unix'

local function log(level, msg)
	pcall(function() freeswitch.consoleLog(level, "[mongo_daemon] " .. msg .. "\n") end)
end

local mongo_db = nil

local function connect()
	mongo_db = nil
	while not mongo_db do
		local ok, result = pcall(function()
			local client = mongo.Client(mongo_uri)
			return client:getDatabase(mongo_dbname)
		end)
		if ok and result then
			mongo_db = result
			log("notice", "connected to MongoDB")
		else
			log("err", "connection failed, retrying in 5s: " .. tostring(result))
			freeswitch.msleep(5000)
		end
	end
end

local function handle_op(req)
	local collection = mongo_db:getCollection(req.collection)
	local op = req.op

	if op == "find" then
		local cursor = collection:find(req.query, req.opts)
		local docs = {}
		for doc in cursor:iterator() do
			docs[#docs + 1] = doc
		end
		docs.__array = true
		return { ok = true, docs = docs }

	elseif op == "aggregate" then
		local cursor = collection:aggregate(req.query)
		local docs = {}
		for doc in cursor:iterator() do
			docs[#docs + 1] = doc
		end
		docs.__array = true
		return { ok = true, docs = docs }

	elseif op == "insert" then
		local ok, err = collection:insert(req.doc)
		if ok then return { ok = true } end
		return { ok = false, error = tostring(err) }

	elseif op == "update" then
		local ok, err = collection:update(req.query, req.update, req.opts)
		if ok then return { ok = true } end
		return { ok = false, error = tostring(err) }

	elseif op == "remove" then
		local ok, err = collection:remove(req.query, req.opts)
		if ok then return { ok = true } end
		return { ok = false, error = tostring(err) }
	end

	return { ok = false, error = "unknown op: " .. tostring(op) }
end

local function handle_connection(conn)
	conn:settimeout(5)

	local len_line, lerr = conn:receive("*l")
	if not len_line then
		log("warning", "read length failed: " .. tostring(lerr))
		return
	end

	local len = tonumber(len_line)
	if not len then
		log("warning", "bad length header: " .. tostring(len_line))
		return
	end

	local body, berr = conn:receive(len)
	if not body then
		log("warning", "read body failed: " .. tostring(berr))
		return
	end

	local ok, req_or_err = pcall(function() return mongo.BSON(body):value() end)
	if not ok then
		log("warning", "bad request payload: " .. tostring(req_or_err))
		return
	end
	local req = req_or_err

	local op_ok, resp = pcall(handle_op, req)
	if not op_ok then
		log("err", "op '" .. tostring(req.op) .. "' on '" .. tostring(req.collection) .. "' failed: " .. tostring(resp))
		-- The mongo client/connection may have gone bad; force a reconnect on
		-- the next request rather than keep hammering a broken client.
		mongo_db = nil
		resp = { ok = false, error = tostring(resp) }
	end

	local payload = tostring(mongo.BSON(resp))
	conn:send(#payload .. "\n" .. payload)
end

local function serve()
	os.remove(mongo_proxy_socket)

	local server = assert(socket())
	assert(server:bind(mongo_proxy_socket))
	assert(server:listen(512))
	os.execute("chmod 0666 " .. mongo_proxy_socket)

	log("notice", "listening on " .. mongo_proxy_socket)

	while true do
		local conn, aerr = server:accept()
		if conn then
			local ok, err = pcall(handle_connection, conn)
			if not ok then
				log("err", "connection handler crashed: " .. tostring(err))
			end
			conn:close()
		else
			log("warning", "accept failed: " .. tostring(aerr))
		end

		if not mongo_db then
			connect()
		end
	end
end

connect()

while true do
	local ok, err = pcall(serve)
	if not ok then
		log("err", "serve loop crashed, restarting in 2s: " .. tostring(err))
		freeswitch.msleep(2000)
	end
end
