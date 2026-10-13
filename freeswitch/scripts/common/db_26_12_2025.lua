mongo = require 'mongo'
local mongo_client = mongo.Client "mongodb://db_pbxcc:jEEBhh3bh8p@40.81.228.224:27017/db_pbxcc?authSource=admin"

-- select the database and collection
mongo_collection_name = mongo_client:getDatabase "db_pbxcc"
logger_flag = 0
params_log  = 0
--mongo_connection = mongo.Client('mongodb://128.140.53.103')
--mongo_collection_name = 'inextrix_call_center'
--local collection = client:getCollection('call_center', 'test')
