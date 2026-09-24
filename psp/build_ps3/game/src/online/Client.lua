local Protocol2 = require("src.online.Protocol2")
local Session = require("src.link.Session")
local Version = require("src.core.Version")
local Wire = require("src.link.Wire")

local Client = {}

local BACKOFF = { 1, 2, 4, 8, 15 }
local MAX_ATTEMPTS = 12
local MATCH_STAGES = { battling = true }
local ROOM_STAGES = { waiting = true, ready = true, battling = true,
                      ended = true }
local UNACKED_MAX = 512

local function now()
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

local S
local clearRoom
local clearTournament
local resumeLost

local function blankState()
  return {
    relayAddress = nil,
    connectFn = nil,
    platform = nil,
    engineVersion = Version.engine,
    status = "offline",
    err = nil,
    opts = nil,
    net = nil,
    session = nil,
    sessionId = nil,
    you = nil,
    heartbeatMs = nil,
    serverTime = nil,
    serverTimeAt = nil,
    lobby = {},
    lobbyById = {},
    room = nil,
    roomSession = nil,
    pending = nil,
    seq = 0,
    ack = 0,
    rxSeq = 0,
    unacked = {},
    unackedFloor = 0,
    unackedDropped = 0,
    pendingReport = nil,
    reportSent = nil,
    roomInbox = {},
    delivered = {},
    matchStarted = false,
    match = nil,
    role = nil,
    resuming = false,
    attempt = 0,
    retryAt = nil,
    handlers = {},
    dropped = 0,
    duplicates = 0,
    advertised = nil,
    online = nil,
    tournament = nil,
    tourMatch = nil,
    tourFinished = {},
  }
end

S = blankState()

function Client.reset()
  if S.session then pcall(function() S.session:close() end) end
  S = blankState()
end

-- ---------------------------------------------------------------- events

function Client.on(event, fn)
  if type(event) ~= "string" or type(fn) ~= "function" then return end
  local list = S.handlers[event]
  if not list then
    list = {}
    S.handlers[event] = list
  end
  list[#list + 1] = fn
end

function Client.off(event, fn)
  local list = S.handlers[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == fn or fn == nil then table.remove(list, i) end
  end
end

local function emit(event, payload)
  local list = S.handlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], payload)
    if not ok then
      S.err = tostring(err)
    end
  end
end

local function setStatus(status)
  if S.status == status then return end
  S.status = status
  emit("state", status)
end

-- ---------------------------------------------------------------- accessors

function Client.state() return S.status end
function Client.match() return S.match end

function Client.serverTime()
  if not S.serverTime then return nil end
  return S.serverTime + (now() - (S.serverTimeAt or now())) * 1000
end

function Client.role() return S.role end
function Client.error() return S.err end
function Client.you() return S.you end
function Client.lobby() return S.lobby end
function Client.room() return S.room end
function Client.tournament() return S.tournament end
function Client.tourMatch() return S.tourMatch end
function Client.dropped() return S.dropped end
function Client.unackedDropped() return S.unackedDropped end
function Client.unackedCount() return #S.unacked end
function Client.pendingReport() return S.pendingReport end
function Client.duplicates() return S.duplicates end
function Client.sessionId() return S.sessionId end

-- ---------------------------------------------------------------- transport

local function openTransport()
  if S.connectFn then
    local transport, err = S.connectFn(S.relayAddress)
    if not transport then return nil, err or "no transport" end
    return transport
  end
  local Net = require("src.link.Net")
  local net = Net.new()
  local address = S.relayAddress or Net.defaultRelayAddress()
  if not net:connectTCP(address) then
    return nil, net.error or ("can't reach the relay at " .. tostring(address))
  end
  net.mode = "onlineLobby"
  net.v2 = true
  return net
end

local function sendRaw(msg)
  if not msg or not S.session then return false end
  S.session:send(msg)
  return true
end

Client.sendRaw = sendRaw

-- ---------------------------------------------------------------- room session

local RoomSession = {}
RoomSession.__index = RoomSession

local function refreshRoomSession()
  local rs = S.roomSession
  if not rs then return end
  local room = S.room
  local players = room and room.players or {}
  rs.paired = room ~= nil and #players >= 2
  rs.error = S.err
  if not room and not rs.left then rs.closed = true end
  if S.status == "error" or S.status == "offline" then rs.closed = true end
end

local function shaped(entry)
  if not entry.side then return entry.msg end
  if not entry.shape then
    entry.shape = { type = "spectate", side = entry.side, msg = entry.msg }
  end
  return entry.shape
end

local function deliver(entries)
  local out = {}
  for i = 1, #entries do
    out[i] = shaped(entries[i])
    local seq = entries[i].seq
    if type(seq) == "number" and seq > S.ack then S.delivered[seq] = true end
  end
  local before = S.ack
  while S.delivered[S.ack + 1] do
    S.delivered[S.ack + 1] = nil
    S.ack = S.ack + 1
  end
  if S.ack > before then sendRaw(Protocol2.roomAck(S.ack)) end
  return out
end

function RoomSession:update()
  Client.update(0)
end

function RoomSession:send(msg)
  if type(msg) ~= "table" then return end
  if self.closed then return end
  S.seq = S.seq + 1
  local wrapped = Protocol2.roomMsg(S.seq, msg)
  if not wrapped then return end
  S.unacked[#S.unacked + 1] = wrapped
  while #S.unacked > UNACKED_MAX do
    local oldest = table.remove(S.unacked, 1)
    S.unackedDropped = S.unackedDropped + 1
    S.unackedFloor = (oldest.seq or 0) + 1
  end
  sendRaw(wrapped)
end

function RoomSession:poll()
  local entries = S.roomInbox
  S.roomInbox = {}
  return deliver(entries)
end

function RoomSession:pollOne()
  if #S.roomInbox == 0 then return nil end
  local entry = table.remove(S.roomInbox, 1)
  return deliver({ entry })[1]
end

function RoomSession:take(messageType, predicate)
  for index = 1, #S.roomInbox do
    local entry = S.roomInbox[index]
    local msg = shaped(entry)
    if msg.type == messageType
       and (predicate == nil or predicate(msg) == true) then
      table.remove(S.roomInbox, index)
      return deliver({ entry })[1]
    end
  end
  return nil
end

function RoomSession:unread(messages)
  if type(messages) ~= "table" then return end
  for index = #messages, 1, -1 do
    local msg = messages[index]
    if type(msg) == "table" and type(msg.type) == "string" then
      table.insert(S.roomInbox, 1, { seq = nil, msg = msg })
    end
  end
end

function RoomSession:hasPending() return #S.roomInbox > 0 end

local function sendLeave()
  if S.room and S.role == "host" and S.room.intent ~= "tournament" then
    sendRaw(Protocol2.roomClose())
  end
  sendRaw(Protocol2.roomLeave())
end

function RoomSession:close()
  if self.left then return end
  self.left = true
  self.closed = true
  sendLeave()
  clearRoom()
end

function Client.roomSession()
  if not S.room then return nil end
  if not S.roomSession or S.roomSession.left then
    S.roomSession = setmetatable({
      paired = false, closed = false, error = nil, left = false,
      code = S.room.code, target = S.room.code,
    }, RoomSession)
  end
  refreshRoomSession()
  return S.roomSession
end

-- ---------------------------------------------------------------- lobby model

local function lobbyLess(a, b)
  local sa, sb = a.since or 0, b.since or 0
  if sa ~= sb then return sa < sb end
  return tostring(a.id) < tostring(b.id)
end

local function sortLobby()
  table.sort(S.lobby, lobbyLess)
end

local function putEntry(entry)
  if not entry or not entry.id then return end
  local existing = S.lobbyById[entry.id]
  if existing then
    for i = 1, #S.lobby do
      if S.lobby[i].id == entry.id then S.lobby[i] = entry end
    end
  else
    S.lobby[#S.lobby + 1] = entry
  end
  S.lobbyById[entry.id] = entry
end

local function dropEntry(id)
  if not id or not S.lobbyById[id] then return end
  S.lobbyById[id] = nil
  for i = #S.lobby, 1, -1 do
    if S.lobby[i].id == id then table.remove(S.lobby, i) end
  end
end

function Client.openRooms()
  local mine = S.you and S.you.id or nil
  local out = {}
  for i = 1, #S.lobby do
    local entry = S.lobby[i]
    if entry.code and entry.open == true and entry.id ~= mine then
      out[#out + 1] = entry
    end
  end
  table.sort(out, lobbyLess)
  return out
end

function Client.watchable()
  local mine = S.you and S.you.id or nil
  local out = {}
  for i = 1, #S.lobby do
    local entry = S.lobby[i]
    if entry.code and entry.id ~= mine then
      local room = entry.stage == "battling"
        and (entry.spectators or 0) < (entry.maxSpectators or 0)
      if room or entry.intent == "tournament" then out[#out + 1] = entry end
    end
  end
  table.sort(out, lobbyLess)
  return out
end

function Client.counts()
  local seen, players = {}, 0
  for i = 1, #S.lobby do
    local id = S.lobby[i].id
    if id and not seen[id] then
      seen[id] = true
      players = players + 1
    end
  end
  if type(S.online) == "number" then players = S.online end
  return { players = players, openRooms = #Client.openRooms() }
end

-- ---------------------------------------------------------------- room model

local function seats(room)
  local players = room and room.players or {}
  return players[1], players[2]
end

local function myRole(room)
  local me = S.you and S.you.id
  local host, guest = seats(room)
  if me then
    if host and host.id == me then return "host" end
    if guest and guest.id == me then return "guest" end
  end
  return "spectator"
end

local function applyRoomState(msg)
  local previous = S.room
  local deadlines = {}
  for _, d in ipairs(msg.deadlines or {}) do
    if d.kind then deadlines[d.kind] = d.at end
  end
  if previous and previous.code == msg.code then
    for kind, at in pairs(previous.deadlines or {}) do
      if deadlines[kind] == nil then deadlines[kind] = at end
    end
  end
  if not previous or previous.code ~= msg.code then
    S.seq, S.ack, S.rxSeq = 0, 0, 0
    S.unacked = {}
    S.unackedFloor = 0
    S.delivered = {}
    S.roomInbox = {}
    S.matchStarted = false
    S.pendingReport = nil
  end
  S.room = {
    code = msg.code,
    players = msg.players or {},
    spectators = msg.spectators or {},
    stage = ROOM_STAGES[msg.stage or ""] and msg.stage or "waiting",
    profile = msg.profile,
    host = msg.host,
    seed = msg.seed,
    rule = msg.rule or (msg.profile and msg.profile.rule) or nil,
    intent = msg.intent,
    maxSpectators = msg.maxSpectators,
    match = msg.match,
    deadlines = deadlines,
  }
  S.match = msg.match or S.match
  S.role = myRole(S.room)
  if S.roomSession and S.roomSession.left then S.roomSession = nil end
  if S.pending and S.pending.kind ~= "tournament"
     and (S.pending.code == nil or S.pending.code == msg.code) then
    S.pending.code = msg.code
    S.pending.room = S.room
    S.pending.done = true
  end
  if not MATCH_STAGES[S.room.stage] then S.matchStarted = false end
  emit("room", S.room)
  refreshRoomSession()
end

clearRoom = function()
  S.room = nil
  S.match = nil
  S.role = nil
  S.matchStarted = false
  S.seq, S.ack, S.rxSeq = 0, 0, 0
  S.unacked = {}
  S.unackedFloor = 0
  S.delivered = {}
  S.roomInbox = {}
  S.pendingReport = nil
  if S.roomSession then
    S.roomSession.closed = true
    S.roomSession.left = true
    S.roomSession = nil
  end
end

clearTournament = function()
  S.pendingReport = nil
  S.tournament = nil
  S.tourMatch = nil
  S.tourFinished = {}
end

resumeLost = function()
  local code = S.room and S.room.code or nil
  sendRaw(Protocol2.roomLeave())
  clearRoom()
  emit("room", nil)
  emit("error", { scope = "room", reason = "resume_incomplete", code = code,
                  text = Protocol2.roomClosedText({
                    reason = "resume_incomplete" }) })
end

local function enterChildRoom(code, msg)
  if not code then return end
  if S.room and S.room.code == code then
    S.room.match = msg and msg.match or S.room.match
    return
  end
  clearRoom()
  local tour = S.tournament
  S.room = {
    code = code,
    players = {},
    spectators = {},
    stage = "waiting",
    profile = tour and tour.profile or nil,
    rule = tour and tour.rule or nil,
    host = nil,
    seed = nil,
    intent = "tournament",
    match = msg and msg.match or nil,
    deadlines = {},
  }
  S.match = S.room.match
  emit("room", S.room)
  refreshRoomSession()
end

local function applyTourState(msg)
  local previous = S.tournament
  local deadlines = {}
  if previous and previous.code == msg.code then
    for kind, at in pairs(previous.deadlines or {}) do deadlines[kind] = at end
  end
  if not previous or previous.code ~= msg.code then S.tourFinished = {} end
  S.tournament = {
    code = msg.code,
    creator = msg.creator,
    stage = msg.stage or "registering",
    players = msg.players or {},
    spectators = msg.spectators or {},
    profile = msg.profile,
    rule = msg.rule or (msg.profile and msg.profile.rule) or nil,
    shotClock = msg.shotClock,
    round = msg.round,
    bracket = msg.bracket or {},
    live = msg.live,
    champion = msg.champion,
    championId = msg.championId,
    maxSpectators = msg.maxSpectators,
    deadlines = deadlines,
  }
  if S.pending and S.pending.kind == "tournament"
     and (S.pending.code == nil or S.pending.code == msg.code) then
    S.pending.code = msg.code
    S.pending.tournament = S.tournament
    S.pending.done = true
  end
  emit("tournament", S.tournament)
end

local function matchStart(msg)
  local role = msg.role
  if role ~= "host" and role ~= "guest" then role = "spectator" end
  S.role = role
  S.match = msg.match or S.match
  if S.room then
    S.room.seed = msg.seed or S.room.seed
    S.room.match = S.match
    if msg.rule then S.room.rule = msg.rule end
  end
  if S.reportSent ~= S.match then S.reportSent = nil end
  if S.matchStarted then return end
  S.matchStarted = true
  emit("match_start", {
    code = msg.code or (S.room and S.room.code) or nil,
    match = S.match,
    role = role,
    seed = msg.seed,
    profile = S.room and S.room.profile or nil,
    ruleset = msg.ruleset,
    rule = msg.rule,
    peerName = msg.peerName,
    hostName = msg.hostName,
    guestName = msg.guestName,
    myParty = nil,
    theirParty = msg.theirParty,
    hostParty = msg.hostParty,
    guestParty = msg.guestParty,
  })
end

local function acceptRoomMsg(entry)
  local seq = entry.seq
  if type(seq) == "number" and seq > 0 then
    if seq <= S.rxSeq then
      S.duplicates = S.duplicates + 1
      return
    end
    S.rxSeq = seq
  end
  S.roomInbox[#S.roomInbox + 1] = { seq = seq, side = entry.side,
                                    msg = entry.msg }
end

-- ---------------------------------------------------------------- dispatch

local helloMessage

local function handle(msg)
  local kind = msg.type
  if kind == "lobby_welcome" then
    local resumed = msg.resumed == true
      and (S.resuming or (S.sessionId ~= nil and msg.session == S.sessionId))
    S.sessionId = msg.session
    S.you = { name = msg.you.name, verified = msg.you.verified,
              id = msg.you.id, session = msg.session }
    S.heartbeatMs = msg.heartbeatMs
    S.serverTime = msg.serverTime
    S.serverTimeAt = now()
    S.attempt = 0
    S.retryAt = nil
    S.err = nil
    S.resuming = false
    if not resumed then
      clearRoom()
      clearTournament()
    end
    setStatus("online")
  elseif kind == "lobby_list" then
    S.lobby, S.lobbyById = {}, {}
    S.online = type(msg.online) == "number" and msg.online or nil
    for _, entry in ipairs(msg.entries) do putEntry(entry) end
    sortLobby()
    emit("lobby", S.lobby)
  elseif kind == "lobby_delta" then
    for _, entry in ipairs(msg.added or {}) do putEntry(entry) end
    for _, entry in ipairs(msg.changed or {}) do putEntry(entry) end
    for _, id in ipairs(msg.removed or {}) do dropEntry(id) end
    for _, entry in ipairs(msg.add or {}) do putEntry(entry) end
    for _, entry in ipairs(msg.update or {}) do putEntry(entry) end
    for _, id in ipairs(msg.remove or {}) do dropEntry(id) end
    if msg.op == "add" or msg.op == "update" then putEntry(msg.entry)
    elseif msg.op == "remove" then dropEntry(msg.id or (msg.entry and msg.entry.id)) end
    sortLobby()
    emit("lobby", S.lobby)
  elseif kind == "room_state" then
    if not (S.tournament and S.tourFinished[msg.code]) then
      applyRoomState(msg)
    end
  elseif kind == "match_start" or kind == "match_start_spectate" then
    matchStart(msg)
  elseif kind == "room_replay" then
    if type(msg.yourSeq) == "number" then
      for i = #S.unacked, 1, -1 do
        if (S.unacked[i].seq or 0) <= msg.yourSeq then table.remove(S.unacked, i) end
      end
      if S.unackedFloor > 0 and msg.yourSeq + 1 < S.unackedFloor then
        resumeLost()
        return
      end
      for i = 1, #S.unacked do sendRaw(S.unacked[i]) end
    end
    for _, entry in ipairs(msg.msgs) do acceptRoomMsg(entry) end
    if S.rxSeq > S.ack then sendRaw(Protocol2.roomAck(S.ack)) end
    refreshRoomSession()
  elseif kind == "room_msg" then
    acceptRoomMsg(msg)
  elseif kind == "room_deadline" then
    if S.room then
      S.room.deadlines = S.room.deadlines or {}
      S.room.deadlines[msg.kind] = msg.at
      emit("room", S.room)
    end
  elseif kind == "room_result" then
    S.matchStarted = false
    if S.pendingReport
       and (msg.match == nil or msg.match == S.pendingReport.match) then
      S.pendingReport = nil
    end
    local me = S.you and S.you.id
    emit("match_end", {
      match = msg.match,
      code = msg.code or (S.room and S.room.code) or nil,
      winner = msg.winner,
      winnerId = msg.winnerId,
      how = msg.how,
      youWon = me ~= nil and msg.winnerId ~= nil and msg.winnerId == me,
    })
    if S.tournament then
      local code = msg.code or (S.room and S.room.code) or nil
      if code then S.tourFinished[code] = true end
      S.tourMatch = nil
      clearRoom()
      emit("room", nil)
    end
  elseif kind == "room_closed" then
    local code = msg.code or (S.room and S.room.code) or nil
    clearRoom()
    if S.pending and not S.pending.done then
      S.pending.error = Protocol2.roomClosedText(msg)
      S.pending.reason = msg.reason
      S.pending.done = true
    end
    emit("room", nil)
    emit("error", { scope = "room", reason = msg.reason, code = code,
                    text = Protocol2.roomClosedText(msg) })
  elseif kind == "tour_state" then
    applyTourState(msg)
  elseif kind == "tour_match" or kind == "tour_match_spectate" then
    local payload = { match = msg.match, round = msg.round, code = msg.code,
                      role = kind == "tour_match" and "player" or "spectator" }
    S.tourMatch = payload
    S.tourFinished[msg.code] = nil
    enterChildRoom(msg.code, msg)
    emit(kind == "tour_match" and "tour_match" or "tour_spectate", payload)
  elseif kind == "tour_bye" then
    emit("tour_bye", { match = msg.match, round = msg.round })
  elseif kind == "tour_deadline" then
    if S.tournament then
      S.tournament.deadlines = S.tournament.deadlines or {}
      S.tournament.deadlines[msg.kind] = msg.at
      emit("tournament", S.tournament)
    end
    if S.room then
      S.room.deadlines = S.room.deadlines or {}
      S.room.deadlines[msg.kind] = msg.at
      emit("room", S.room)
    end
  elseif kind == "tour_closed" then
    local code = msg.code or (S.tournament and S.tournament.code) or nil
    local text = Protocol2.tourClosedText(msg)
    clearRoom()
    clearTournament()
    if S.pending and not S.pending.done then
      S.pending.error = text
      S.pending.reason = msg.reason
      S.pending.done = true
    end
    emit("room", nil)
    emit("tournament", nil)
    emit("error", { scope = "tournament", reason = msg.reason, code = code,
                    text = text })
  elseif kind == "tour_over" then
    if S.tournament and S.tournament.code == msg.code then
      S.tournament.stage = "finished"
      S.tournament.champion = msg.championId or S.tournament.champion
      S.tournament.championName = msg.champion
      emit("tournament", S.tournament)
    end
    S.tourMatch = nil
    emit("tour_over", { code = msg.code, champion = msg.champion,
                        championId = msg.championId })
  elseif kind == "join_error" then
    local text = Protocol2.joinErrorText(msg)
    if S.resuming then
      S.resuming = false
      S.sessionId = nil
      clearRoom()
      sendRaw(helloMessage())
      return
    end
    if S.pending then
      S.pending.error = text
      S.pending.reason = msg.reason
      S.pending.field = msg.field
      S.pending.done = true
    end
    emit("error", { scope = "join", reason = msg.reason, field = msg.field,
                    detail = msg.detail, text = text })
  end
end

-- ---------------------------------------------------------------- connection

local function bind()
  local transport, err = openTransport()
  if not transport then return false, err end
  S.net = transport
  S.session = Session.new(transport, { role = "client", kind = "lobby" })
  return true
end

helloMessage = function()
  local opts = S.opts or {}
  return Protocol2.lobbyHello({
    ticket = opts.ticket,
    name = opts.name,
    engineVersion = S.engineVersion,
    platform = S.platform,
    profiles = opts.profiles,
  })
end

local function scheduleRetry()
  S.attempt = S.attempt + 1
  local wait = BACKOFF[math.min(S.attempt, #BACKOFF)]
  S.retryAt = now() + wait
end

local function onDisconnected(detail)
  S.session = nil
  S.net = nil
  if S.sessionId and S.opts and S.attempt < MAX_ATTEMPTS then
    S.err = detail
    setStatus("reconnecting")
    scheduleRetry()
  else
    S.err = detail or S.err or "disconnected"
    setStatus("error")
  end
  refreshRoomSession()
end

local function tryReconnect()
  S.retryAt = nil
  local ok, err = bind()
  if not ok then
    if S.attempt >= MAX_ATTEMPTS then
      S.err = err
      setStatus("error")
      return
    end
    S.err = err
    scheduleRetry()
    return
  end
  S.resuming = true
  sendRaw(Protocol2.resume(S.sessionId, S.ack))
end

function Client.configure(opts)
  opts = opts or {}
  if opts.relayAddress ~= nil then S.relayAddress = opts.relayAddress end
  if opts.connect ~= nil then S.connectFn = opts.connect end
  if opts.platform ~= nil then S.platform = opts.platform end
  if opts.engineVersion ~= nil then S.engineVersion = opts.engineVersion end
  return S.relayAddress
end

function Client.setProfiles(list)
  S.opts = S.opts or {}
  S.opts.profiles = list or {}
  return S.opts.profiles
end

function Client.profiles()
  return (S.opts and S.opts.profiles) or {}
end

function Client.connect(opts)
  opts = opts or {}
  if S.session then Client.disconnect() end
  S.opts = { name = opts.name, ticket = opts.ticket,
             profiles = opts.profiles or {} }
  S.err = nil
  S.sessionId = nil
  S.attempt = 0
  S.retryAt = nil
  setStatus("connecting")
  local ok, err = bind()
  if not ok then
    S.err = err
    setStatus("error")
    return false, err
  end
  sendRaw(helloMessage())
  return true
end

function Client.disconnect()
  if S.session then
    if S.room then sendLeave() end
    pcall(function() S.session:close() end)
  end
  S.session = nil
  S.net = nil
  S.sessionId = nil
  S.you = nil
  S.opts = nil
  S.lobby, S.lobbyById = {}, {}
  S.attempt = 0
  S.retryAt = nil
  S.resuming = false
  S.advertised = nil
  S.online = nil
  clearRoom()
  clearTournament()
  setStatus("offline")
end

-- ---------------------------------------------------------------- pump

local function pump(dt)
  if S.status == "reconnecting" then
    if S.retryAt and now() >= S.retryAt then tryReconnect() end
  end
  local session = S.session
  if not session then return end
  session:update()
  local messages = session:poll()
  for i = 1, #messages do
    local msg, reason = Protocol2.validate(messages[i])
    if msg then
      handle(msg)
    else
      S.dropped = S.dropped + 1
      S.lastDrop = reason
    end
  end
  S.dropped = S.dropped + (session.dropped or 0)
  session.dropped = 0
  if session.closed then
    onDisconnected(session.error or "the relay closed the connection")
    return
  end
  local queued = S.pendingReport
  if queued and S.status == "online" then
    S.pendingReport = nil
    if S.match and queued.match == S.match then
      S.reportSent = queued.match
      sendRaw(queued.msg)
    end
  end
  refreshRoomSession()
end

function Client.update(dt)
  if S.status == "offline" then return end
  local ok, err = pcall(pump, dt or 0)
  if not ok then
    S.err = tostring(err)
    setStatus("error")
  end
end

-- ---------------------------------------------------------------- actions

function Client.advertise(intent, profile, note)
  S.advertised = { intent = intent, profile = profile, note = note }
  return sendRaw(Protocol2.advertise(intent, profile, note))
end

function Client.unadvertise()
  S.advertised = nil
  return sendRaw(Protocol2.unadvertise())
end

local function newPending(code, kind)
  S.pending = { code = code, room = nil, error = nil, done = false,
                kind = kind or "room", at = now() }
  return S.pending
end

function Client.createRoom(opts)
  local pending = newPending(nil)
  sendRaw(Protocol2.roomCreate(opts))
  return pending
end

local function defaultProfile()
  local profiles = S.opts and S.opts.profiles or {}
  return profiles[1]
end

function Client.joinRoom(code, as, profile)
  local pending = newPending(Wire.code(code))
  sendRaw(Protocol2.roomJoin(code, as, profile or defaultProfile()))
  return pending
end

function Client.leaveRoom()
  local rs = S.roomSession
  if rs then
    rs:close()
    S.roomSession = nil
    return true
  end
  if not S.room then return false end
  sendLeave()
  clearRoom()
  return true
end

function Client.ready(packedParty, digest)
  return sendRaw(Protocol2.roomReady(packedParty, digest))
end

local function sendResult(msg)
  if not msg then return false end
  local match = S.match
  if S.session and S.status == "online" then
    if match then S.reportSent = match end
    return sendRaw(msg)
  end
  if match and S.reportSent ~= match then
    S.pendingReport = { match = match, msg = msg }
  end
  return false
end

function Client.report(result)
  if not Protocol2.RESULTS[result] then
    return sendResult(Protocol2.forfeit(S.match))
  end
  return sendResult(Protocol2.roomReport(S.match, result))
end

function Client.forfeit()
  return sendResult(Protocol2.forfeit(S.match))
end

function Client.kick(id)
  return sendRaw(Protocol2.roomKick(id))
end

function Client.closeRoom()
  if not S.room then return false end
  local ok = sendRaw(Protocol2.roomClose())
  return ok
end

function Client.createTournament(opts)
  opts = opts or {}
  local pending = newPending(nil, "tournament")
  sendRaw(Protocol2.tourCreate({
    profile = opts.profile or defaultProfile(),
    rule = opts.rule,
    playing = opts.playing,
    shotClock = opts.shotClock,
    maxSpectators = opts.maxSpectators,
    party = opts.party,
    partyDigest = opts.partyDigest,
    public = opts.public,
    note = opts.note,
  }))
  return pending
end

function Client.joinTournament(code, as, packedParty, digest, profile)
  local pending = newPending(Wire.code(code), "tournament")
  sendRaw(Protocol2.tourJoin(code, as, profile or defaultProfile(),
                             packedParty, digest))
  return pending
end

function Client.leaveTournament()
  if not S.tournament then return false end
  sendRaw(Protocol2.tourLeave())
  clearRoom()
  clearTournament()
  emit("room", nil)
  emit("tournament", nil)
  return true
end

function Client.startTournament()
  if not S.tournament then return false end
  return sendRaw(Protocol2.tourStart())
end

function Client.kickFromTournament(id)
  if not S.tournament then return false end
  return sendRaw(Protocol2.tourKick(id))
end

function Client.closeTournament()
  if not S.tournament then return false end
  return sendRaw(Protocol2.tourClose())
end

return Client
