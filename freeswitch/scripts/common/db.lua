mongo = require 'mongo'
local mongo_client = mongo.Client "mongodb://db_pbxcc:qxR3aghkOaZToadsJed3q@103.36.121.197:3815/db_pbxcc?authSource=db_pbxcc"
-- select the database and collection
mongo_collection_name = mongo_client:getDatabase "db_pbxcc"
logger_flag = 0
params_log  = 0
