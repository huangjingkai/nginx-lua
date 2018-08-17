-- Redis Cache module: Transparent subrequest-based caching layout for arbitrary nginx locations. 
-- Auth: huangjingkai#foxmail.com
-- Date: 1398241561

-- [Configuration Start]
g_cache = {}
--[[
g_cache.err_return_page, There are several types of pages returned after failure:
	1] connects to the redis server [error] to prevent the large flow impact on the back end and return to the page directly.
	2] connects to the redis server [normal], but gets the key value [exception] and returns directly to the area.
	3) Connect to the redis server [normal], but loop g_cache. search_count times, get the key value [nil] and return to the page directly.
	4] to the backend request page, return the code is not 200 OK (currently only caching the page returning to 200ok).
]]
g_cache.err_return_page = "/503.html"

-- Sets the timeout (in ms) protection for subsequent operations, including the connect method.
g_cache.redis_timeout = 2000

--[[
Puts the current Redis connection immediately into the ngx_lua cosocket connection pool.
You can specify the max idle timeout (in ms) when the connection is in the pool and the maximal size of the pool every nginx worker process.
]]
g_cache.redis_max_idle_timeout = 60000
g_cache.redis_pool_size = 100
--[[
g_cache.search_count: Connect to the redis server, if the key value does not exist, and is not the first time the key value is queried, the number of loops obtained.
g_cache.search_sleep: Connect to the redis server. If the key value does not exist and is not the first time the key value is queried, the wait time for each loop is required.
g_cache.search_dict_exptime: Gets the key value for the first time, at least after that value, before the next query.
]]
g_cache.search_count = 5
g_cache.search_sleep = 0.4
g_cache.search_dict_exptime = 1

-- The default URI timeout time is used if the configuration file is not set.
g_cache.uri_default_exptime = 600

-- The header domain of the request to be deleted.
g_cache.req_header={
["Accept-Encoding"]=1,
}

-- The response header field contains the following, deletes if it belongs to delete, and does not cache if it belongs to no-cache.
g_cache.resp_header={
["ETag"]="delete",
["Content-Length"]="delete",
["Transfer-Encoding"]="no-cache",
["Set-Cookie"]="delete",
["Cookie"]="delete",
["Date"]="delete",
["Vary"]="delete",
["X-CACHE-S"]="no-cache"
}

-- The expiration time of redundant cache, default 3600s
g_cache.stale_cache_expire_time = 3600

-- Internally fixed string used to cache dynamically replace special content.
g_cache.internal_replace_str="<INTERNAL_REPLACE_STRING>"

-- redis Cache log level
g_cache.log_level=ngx.NOTICE

-- [Configuration End]

function errs(a,b,c)
  ngx.log(ngx.WARN,a," ",b," ",c)
end

function redis_string_split(src, sub)
  if src == nil or sub == nil then return; end

  local output = {}
  local i,j = string.find(src,sub)
  if i == nil then return; end

  return string.sub(src, 1, i-1), string.sub(src, j+1, -1)
end

function redis_get_stale_key(key)
  if key == nil then return; end
  local key_stale=key .. "_stale"
  return key_stale
end

function redis_string_replace(src,repl_old,repl_new)
  if src ~= nil and repl_old ~=nil and repl_new ~= nil then
    local str_len=string.len(src)
    local i,j=string.find(src,repl_old)
    if i ~= nil then
      if i == 1 then
        return repl_new .. string.sub(src,j+1,-1)
      elseif j == str_len then
        return string.sub(src,1,i-1) .. repl_new
      else
        return string.sub(src,1,i-1) .. repl_new .. string.sub(src,j+1,-1)
      end
    else
	ngx.log(g_cache.log_level,"[X-DCS]cant find repl_old=",repl_old,",repl_new=",repl_new)
    end
  end
  return src;
  --return string.gsub(src,repl_old,repl_new);
end

--[[
Description     : try to find cache from redis and assemble HTTP response
Input Parameter : redis_inst,redis instance
				  key,specify cache key
				  expire, User expected expiration time
				  is_stale_cache, Does the user expect to make history caching?
                  status,specify ngx.header['X-DCS-STATUS']
Return Value    : nil
Date                    : 1407227161
Author                  : lvguanglin                               
]]
function try_to_get_resp_from_redis(redis_inst,keys,expire,is_stale_cache,status)
-- calculates the difference between the maximum time of historical caching and the expected expiration time of users.
  local stale_time = 0
  if is_stale_cache and expire < g_cache.stale_cache_expire_time then
	stale_time = g_cache.stale_cache_expire_time - expire
  end
  
  --BEGIN: Modified By lvguanglin, If the expiration time is stored as the historical cache expiration time, the Lua script is executed on Redis using the eval command to check whether the specified record has exceeded the user's expected expiration time. 1407227161
  local res
  local err
  if stale_time > 0 then
	res, err = redis_inst:eval("local left_t=redis.call('ttl',KEYS[1]) if left_t > 0 and left_t > tonumber(KEYS[2]) then return redis.call('get',KEYS[1]) else return nil end",2,keys,stale_time)
  else
	res, err = redis_inst:get(keys)
  end
  if not res then
	ngx.log(ngx.ERR, "[X-DCS] failed to get keys: ", keys,",err:",err)
	return false
  end
  --END

  if res ~= ngx.null and type(res) == "string" then
    local values = res
    local headers, body = redis_string_split(values, '\n\n')

    if headers ~= nil and body ~= nil then
      local rt= {}
      string.gsub(headers, '[^'..'\n'..']+', function(w) table.insert(rt, w) end )

      for k,v in pairs(rt) do
          local header_name, header_value = redis_string_split(v, ':')
          ngx.header[header_name] = header_value
      end

--BEGIN: Added by lvguanglin, When the cache hits, it determines whether cache replacement is necessary. 1407227161
      local callback_val = ngx.var.callback_val
      if callback_val ~= nil and callback_val ~= ngx.null and 0 < string.len(callback_val) then
        ngx.log(g_cache.log_level,"[X-DCS]Redis Hit,need to replace before give body to user,callback_val=",callback_val)
        body=redis_string_replace(body,g_cache.internal_replace_str,callback_val)
      end
--END

      local ok, err = redis_inst:set_keepalive(g_cache.redis_max_idle_timeout, g_cache.redis_pool_size)
      if not ok then
        ngx.log(ngx.ERR, "[X-DCS] failed to set keepalive", err )
      end

      ngx.header['X-DCS-STATUS'] = status
      ngx.header["pragma"]="no-cache"
      ngx.header["cache-control"]="no-cache, no-store, max-age=0"
      ngx.print(body)
      ngx.exit(ngx.HTTP_OK)
    end
  end
  return true
end

--[[
Description     : try to find history cache from redis
Input Parameter : redis_inst, redis instance 
				  key,specify cache key
                  status,specify ngx.header['X-DCS-STATUS']
Return Value    : nil
Date                    : 1407227161
Author                  : lvguanglin                               
]]
function try_to_get_stale_resp_from_redis(redis_inst,key,status)
-- Here we want to read the history buffer, so the expired time passes the expiration time of the historical cache.
  return try_to_get_resp_from_redis(redis_inst,key,g_cache.stale_cache_expire_time,true,status)
end

ngx.log(ngx.WARN, '[X-DCS] nginx redis script start.')
