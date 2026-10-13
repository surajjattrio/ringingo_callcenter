-- Shared Mongo connection settings, used by both mongo_daemon.lua (the
-- singleton connection holder) and mongo_client.lua (the per-call proxy).
mongo_uri = 'mongodb://admin:JHy3q4tbAzzxJDqZT0n8GY4NFfEG0EnJ@127.0.0.1:3870/admin'
mongo_dbname = 'admin'
mongo_proxy_socket = '/tmp/fs_mongo_proxy.sock'
