-- Redis Cache module: Transparent subrequest-based caching layout for arbitrary nginx locations. 
-- Auth: huangjingkai#foxmail.com
-- Date: 1398241561

--[[
NGINX parameters:
  1. User define parameters:
  *** Required ) ngx.var.redis_host
  *** Required ) ngx.var.redis_port
  *** Required ) ngx.var.redis_password
  *** Required ) ngx.var.cache_key
  * option ) ngx.var.exptime, user define, default: 600s
  * option ) ngx.var.callback_val, user define, default : null
  * option ) ngx.var.do_stale_cache, user define, default: 

  2. System parameters:
  * ngx.var.request_method
  * ngx.var.request_body
  * ngx.var.content_length
]]


-- Get the value of ngx.var.cache_backend
local backend = "/reverse-proxy"
if ngx.var.cache_backend ~= nil and ngx.var.cache_backend ~= "" then
    backend = "/" .. ngx.var.cache_backend
end

local keys = ngx.var.cache_key
if keys == nil or keys == "" or keys == "initial" then
    ngx.log(ngx.ERR,"[X-DCS]cache_key is nil,wil goto bacnend: ", backend)
    ngx.header['X-DCS-STATUS'] = 'MISS'
    return ngx.exec(backend)
end


-- Get user behavior, do you expect to do historical caching.
local is_stale_cache = true 
local stale_cache = ngx.var.do_stale_cache
if stale_cache ~= nil and stale_cache ~= "" and string.len(stale_cache) > 0 then
	is_stale_cache = (string.lower(stale_cache) == "yes" and true) or false
end

-- Get user expected cache time
local exptime = tonumber(ngx.var.exptime)
if exptime == nil or exptime <= 0 then
	ngx.log(g_cache.log_level, "[X-DCS] Use default exptime, keys=", keys)
	exptime = g_cache.uri_default_exptime
end

--  Connect to the redis server.
local redis = require "resty.redis"
local red = redis:new()
red:set_timeout(g_cache.redis_timeout) -- 1 sec

-- connect to a unix domain socket file listened by a redis server:
-- local ok, err = red:connect("unix:/usr/local/NSP/etc/redis/redis.sock", {pool="mypool"})
local ok, err = red:connect(ngx.var.redis_host, ngx.var.redis_port, {pool="mypool"})
if not ok then
	ngx.log(ngx.ERR, "[X-DCS] Redis server failed to connect: ", g_cache.redis_host, g_cache.redis_port)
	ngx.header['X-DCS-STATUS'] = 'DOWN'
	ngx.header["pragma"]="no-cache"
	ngx.header["cache-control"]="no-cache, no-store, max-age=0"
	ngx.log(ngx.ERR,"[X-DCS]can not connect to redis ,wil goto backend: " , backend, "err: ", err)
    return ngx.exec(backend)
end

local res, err = red:auth(ngx.var.redis_password)
if not res then
	ngx.log(ngx.ERR, "[CACHE] auth failed: ", ngx.var.redis_host, ":", ngx.var.redis_port)
	ngx.header['X-CACHED-STATUS'] = 'DOWN'
	ngx.header["pragma"]="no-cache"
	ngx.header["cache-control"]="no-cache, no-store, max-age=0"
	ngx.log(ngx.ERR,"[X-DCS] can not connect to redis , passwordd is wrong, wil goto backend: " , backend, ",err: ", err)
    return ngx.exec(backend)
end

local count = g_cache.search_count
local loop loop_cnt=0
for loop = 1,count,1 do
--BEGIN：Modified By lvguanglin, Encapsulated as functions, the number of cycles needs to be counted individually by loop_cnt. 1407486361
  loop_cnt = loop
  if not try_to_get_resp_from_redis(red,keys,exptime,is_stale_cache,'HIT') then
    ngx.header['X-DCS-STATUS'] = 'MISS'
    ngx.header["pragma"]="no-cache"
    ngx.header["cache-control"]="no-cache, no-store, max-age=0"
    return ngx.exec(g_cache.err_return_page)
  end
--END
  
  -- If the first time, then break to get reply from backend.
  if not ngx.shared.dict_cache_uri_search_flag:get(keys) then
    ngx.shared.dict_cache_uri_search_flag:set(keys, 1, g_cache.search_dict_exptime)
    break;
  end

  ngx.sleep(g_cache.search_sleep)
end

if loop_cnt == count then
--BEGIN：Added By lvguanglin, If the cache exceeds a certain number of times, if history cache is made, try to query the history cache. 1407486361
  if is_stale_cache then
	try_to_get_stale_resp_from_redis(red,keys,'STALE')
  end
--END  
  ngx.header['X-DCS-STATUS'] = 'MISS'
  ngx.header["pragma"]="no-cache"
  ngx.header["cache-control"]="no-cache, no-store, max-age=0"
  return ngx.exec(g_cache.err_return_page)
end


ngx.log(g_cache.log_level, "[X-DCS] Search from backend, key=", keys)


-- query from the backend.
for k,v in pairs(g_cache.req_header) do
  ngx.req.clear_header(k)
end

local capture_options = {copy_all_vars=true}
if ngx.var.request_method == "POST" then
   ngx.req.read_body()
   capture_options.method=ngx.HTTP_POST
   local req_body = ngx.var.request_body
   if not req_body and ngx.var.content_length ~= "0" then
   	local file = ngx.req.get_body_file()
	if file then 
	    local fp = io.open(file,"r")
	    if fp then fp:seek("set",0) req_body = fp:read("*a") fp:close() end
	end
   end
   if not req_body then 
	ngx.log(ngx.ERR,"[X-DCS]post request but doesnt has request_body,content_length:"..tostring(ngx.var.content_length))
        ngx.header['X-DCS-STATUS'] = 'MISS'
  	return ngx.exec(backend)
   end
   capture_options.body=req_body
   ngx.log(g_cache.log_level,"[X-DCS]it's post request,cache_key is " ..keys)
end

local res_backend = ngx.location.capture(backend,capture_options)
if res_backend.status ~= ngx.HTTP_OK then
  ngx.shared.dict_cache_uri_search_flag:delete(keys)
--BEGIN：Added By lvguanglin, When the backend is down, a history buffer is attempted to query the history cache. 1407486361
  if is_stale_cache then
	  if not try_to_get_stale_resp_from_redis(red,keys,'STALE') then
		ngx.header['X-DCS-STATUS'] = 'MISS'
		ngx.header["pragma"]="no-cache"
		ngx.header["cache-control"]="no-cache, no-store, max-age=0"
		return ngx.exec(g_cache.err_return_page)
	  end
  end
--END
  ngx.log(ngx.ERR,"[X-DCS]response status is not ok,is ", res_backend.status, ". backend: ", backend)
  ngx.header['X-DCS-STATUS'] = 'MISS'
  return ngx.exec(backend)
end


-- save to the end.
local headers =''
local is_store = true
for k,v in pairs(res_backend.header) do
  if g_cache.resp_header[k] == "no-cache" then
    is_store = false
    break
  end

  if g_cache.resp_header[k] ~= "delete" and type(v) == "string" then
    headers = headers .. k .. ':' .. v .. '\n'
  end

end

if is_store == true then
  ngx.header['X-DCS-STATUS'] = 'STORE'
  local body = res_backend.body

  --BEGIN: Added by lvguanglin, If there is a specific string, it is necessary to process the back-end response first and then store it in redis. 1407486361
  local callback_v=ngx.var.callback_val
  if callback_v ~= nil and callback_v ~= ngx.null and 0 < string.len(callback_v) then
    ngx.log(g_cache.log_level,"[X-DCS]need to replace before save body to redis,callback_v=",callback_v)
    body=redis_string_replace(body,callback_v,g_cache.internal_replace_str)  
  end
  --END

  local values = headers .. '\n' .. body
  local exptime = tonumber(ngx.var.exptime)
  if exptime == nil or exptime <= 0 then
    ngx.log(g_cache.log_level, "[X-DCS] Use default exptime, keys=", keys)
    exptime = g_cache.uri_default_exptime
  end
  
  --BEGIN：Added By lvguanglin, When history caching is enabled, cache expiration times are set to larger values in exptime and g_cache. stale_cache_expire_time, add 10 minutes. 1407486361
  local stale_exptime = g_cache.stale_cache_expire_time
  if is_stale_cache and stale_exptime ~= nil and exptime < stale_exptime then
	exptime = stale_exptime
  end
  
  -- Explosion proof, add 10 minutes
  exptime = exptime + 600
  local res, err = red:setex(keys,exptime,values)
  if not res then
    ngx.log(ngx.ERR, "[X-DCS] failed to set value: ", values)
  end
--END
else
  ngx.header['X-DCS-STATUS'] = 'PASS'
  ngx.log(g_cache.log_level, "[X-DCS] cache miss, keys=", keys)
end

-- put it into the connection pool of size 100,
-- with 60 seconds max idle time
local ok, err = red:set_keepalive(g_cache.redis_max_idle_timeout, g_cache.redis_pool_size)
if not ok then
  ngx.log(ngx.ERR, "[X-DCS] failed to set keepalive: ", err)
end

ngx.print(res_backend.body)
ngx.exit(ngx.HTTP_OK)
