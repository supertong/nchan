--input:  keys: [], values: [channel_id, time, message, content_type, eventsource_event, msg_ttl, max_msg_buf_size]
--output: message_tag, channel_hash {ttl, time_last_seen, subscribers, messages}

local id=ARGV[1]
local time=tonumber(ARGV[2])
local msg={
  id=nil,
  data= ARGV[3],
  content_type=ARGV[4],
  eventsource_event=ARGV[5],
  ttl= tonumber(ARGV[6]),
  time= time,
  tag= 0
}
if msg.ttl == 0 then
  msg.ttl = 126144000 --4 years
end
local store_at_most_n_messages = tonumber(ARGV[7])
if store_at_most_n_messages == nil or store_at_most_n_messages == "" then
  return {err="Argument 7, max_msg_buf_size, can't be empty"}
end
if store_at_most_n_messages == 0 then
  msg.unbuffered = 1
end

--[[local dbg = function(...)
  local arg = {...}
  for i = 1, #arg do
    arg[i]=tostring(arg[i])
  end
  redis.call('echo', table.concat(arg))
end
]]
if type(msg.content_type)=='string' and msg.content_type:find(':') then
  return {err='Message content-type cannot contain ":" character.'}
end

redis.call('echo', ' #######  PUBLISH   ######## ')

-- sets all fields for a hash from a dictionary
local hmset = function (key, dict)
  if next(dict) == nil then return nil end
  local bulk = {}
  for k, v in pairs(dict) do
    table.insert(bulk, k)
    table.insert(bulk, v)
  end
  return redis.call('HMSET', key, unpack(bulk))
end

--[[
local hash_tostr=function(h)
  local tt = {}
  for k, v in pairs(h) do
    table.insert(tt, ("%s: %s"):format(k, v))
  end
  return "{" .. table.concat(tt,", ") .. "}"
end
]]

local tohash=function(arr)
  if type(arr)~="table" then
    return nil
  end
  local h = {}
  local k=nil
  for i, v in ipairs(arr) do
    if k == nil then
      k=v
    else
      h[k]=v; k=nil
    end
  end
  return h
end

local key={
  time_offset=  'nchan:message_time_offset',
  last_message= nil,
  message=      'channel:msg:%s:'..id, --not finished yet
  channel=      'channel:'..id,
  messages=     'channel:messages:'..id,
  subscribers=  'channel:subscribers:'..id
}

local channel_pubsub = 'channel:pubsub:'..id

local new_channel
local channel
if redis.call('EXISTS', key.channel) ~= 0 then
  channel=tohash(redis.call('HGETALL', key.channel))
  channel.max_stored_messages = tonumber(channel.max_stored_messages)
end

if channel~=nil then
  --dbg("channel present")
  if channel.current_message ~= nil then
    --dbg("channel current_message present")
    key.last_message=('channel:msg:%s:%s'):format(channel.current_message, id)
  else
    --dbg("channel current_message absent")
    key.last_message=nil
  end
  new_channel=false
else
  --dbg("channel missing")
  channel={}
  new_channel=true
  key.last_message=nil
end

--set new message id
local lastmsg, lasttime, lasttag
if key.last_message then
  lastmsg = redis.call('HMGET', key.last_message, 'time', 'tag')
  lasttime, lasttag = tonumber(lastmsg[1]), tonumber(lastmsg[2])
  --dbg("New message id: last_time ", lasttime, " last_tag ", lasttag, " msg_time ", msg.time)
  if lasttime and tonumber(lasttime) > tonumber(msg.time) then
    redis.log(redis.LOG_WARNING, "Nchan: message for " .. id .. " arrived a little late and may be delivered out of order. Redis must be very busy.")
    msg.time = lasttime
    time = lasttime
  end
  if lasttime and lasttime==msg.time then
    msg.tag=lasttag+1
  end
  msg.prev_time = lasttime
  msg.prev_tag = lasttag
else
  msg.prev_time = 0
  msg.prev_tag = 0
end
msg.id=('%i:%i'):format(msg.time, msg.tag)

key.message=key.message:format(msg.id)
if redis.call('EXISTS', key.message) ~= 0 then
  local errmsg = "Message %s for channel %s id %s already exists. time: %s lasttime: %s lasttag: %s"
  errmsg = errmsg:format(key.message, id, msg.id, time, lasttime, lasttag)
  --redis.log(redis.LOG_WARNING, errmsg)
  --redis.log(redis.LOG_WARNING, "channel: " .. key.channel .. hash_tostr(channel))
  --redis.log(redis.LOG_WARNING, ("messages: %s {%s}"):format(key.messages, table.concat(redis.call('LRANGE', key.messages, 0, -1), ", ")))
  return {err=errmsg}
end

msg.prev=channel.current_message
if key.last_message and redis.call('exists', key.last_message) == 1 then
  redis.call('HSET', key.last_message, 'next', msg.id)
end

--update channel
redis.call('HSET', key.channel, 'current_message', msg.id)
if msg.prev then
  redis.call('HSET', key.channel, 'prev_message', msg.prev)
end
if time then
  redis.call('HSET', key.channel, 'time', time)
end
if not channel.ttl then
  channel.ttl=msg.ttl
  redis.call('HSET', key.channel, 'ttl', channel.ttl)
end

local message_len_changed = false
if channel.max_stored_messages ~= store_at_most_n_messages then
  channel.max_stored_messages = store_at_most_n_messages
  message_len_changed = true
  redis.call('HSET', key.channel, 'max_stored_messages', store_at_most_n_messages)
  --dbg("channel.max_stored_messages was not set, but is now ", store_at_most_n_messages)
end

--write message
hmset(key.message, msg)


--check old entries
local oldestmsg=function(list_key, old_fmt)
  local old, oldkey
  local n, del=0,0
  while true do
    n=n+1
    old=redis.call('lindex', list_key, -1)
    if old then
      oldkey=old_fmt:format(old)
      local ex=redis.call('exists', oldkey)
      if ex==1 then
        return oldkey
      else
        redis.call('rpop', list_key)
        del=del+1
      end
    else
      break
    end
  end
end

local max_stored_msgs = channel.max_stored_messages or -1

local oldmsgfmt = 'channel:msg:%s:'..id
if max_stored_msgs < 0 then --no limit
  oldestmsg(key.messages, oldmsgfmt)
  redis.call('LPUSH', key.messages, msg.id)
elseif max_stored_msgs > 0 then
  local stored_messages = tonumber(redis.call('LLEN', key.messages))
  redis.call('LPUSH', key.messages, msg.id)
  -- Reduce the message length if neccessary
  local dump_message_ids = redis.call('LRANGE', key.messages, max_stored_msgs, stored_messages);
  if dump_message_ids then
    for _, msgid in ipairs(dump_message_ids) do
      redis.call('DEL', oldmsgfmt:format(msgid))
    end
  end
  redis.call('LTRIM', key.messages, 0, max_stored_msgs - 1)
  oldestmsg(key.messages, oldmsgfmt)
end


--set expiration times for all the things
  redis.call('EXPIRE', key.message, msg.ttl)
  redis.call('EXPIRE', key.time_offset, channel.ttl)
  redis.call('EXPIRE', key.channel, channel.ttl)
  redis.call('EXPIRE', key.messages, channel.ttl)
  redis.call('EXPIRE', key.subscribers, channel.ttl)

--publish message
local unpacked

-- Always push back data directly. Hacked by Supertong
unpacked= {
  "msg",
  msg.ttl or 0,
  msg.time,
  tonumber(msg.tag) or 0,
  msg.prev_time or 0,
  msg.prev_tag or 0,
  msg.data or "",
  msg.content_type or "",
  msg.eventsource_event or ""
}

if message_len_changed then
  unpacked[1] = "max_msgs+" .. unpacked[1]
  table.insert(unpacked, 2, tonumber(channel.max_stored_messages))
end

local msgpacked

--dbg(("Stored message with id %i:%i => %s"):format(msg.time, msg.tag, msg.data))

--now publish to the efficient channel
local numsub = redis.call('PUBSUB','NUMSUB', channel_pubsub)[2]
if tonumber(numsub) > 0 then
  msgpacked = cmsgpack.pack(unpacked)
  redis.call('PUBLISH', channel_pubsub, msgpacked)
end

local num_messages = redis.call('llen', key.messages)

--dbg("channel ", id, " ttl: ",channel.ttl, ", subscribers: ", channel.subscribers, "(fake: ", channel.fake_subscribers or "nil", "), messages: ", num_messages)
return { msg.tag, {tonumber(channel.ttl or msg.ttl), tonumber(channel.time or msg.time), tonumber(channel.fake_subscribers or channel.subscribers or 0), tonumber(num_messages)}, new_channel}
