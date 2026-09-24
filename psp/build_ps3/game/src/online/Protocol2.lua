local Wire = require("src.link.Wire")

local Protocol2 = {}

Protocol2.VERSION = 2

Protocol2.INTENTS = { battle = true, trade = true, tournament = true }
Protocol2.JOIN_AS = { player = true, spectator = true }

local function build(msg)
  local out = Wire.sanitize(msg)
  return out
end

function Protocol2.lobbyHello(opts)
  opts = opts or {}
  return build({
    type = "lobby_hello",
    ticket = opts.ticket,
    name = opts.name,
    engineVersion = opts.engineVersion,
    platform = opts.platform,
    profiles = opts.profiles or {},
  })
end

function Protocol2.resume(session, ack)
  return build({ type = "resume", session = session, ack = ack or 0 })
end

function Protocol2.advertise(intent, profile, note)
  return build({ type = "advertise", intent = intent, profile = profile,
                 note = note })
end

function Protocol2.unadvertise()
  return build({ type = "unadvertise" })
end

function Protocol2.roomCreate(opts)
  opts = opts or {}
  return build({
    type = "room_create",
    intent = opts.intent or "battle",
    profile = opts.profile,
    playing = opts.playing ~= false,
    maxSpectators = opts.maxSpectators,
    public = opts.public ~= false,
    note = opts.note,
  })
end

function Protocol2.roomJoin(code, as, profile)
  return build({ type = "room_join", code = code, as = as or "player",
                 profile = profile })
end

function Protocol2.roomLeave()
  return build({ type = "room_leave" })
end

function Protocol2.roomReady(party, partyDigest)
  return build({ type = "room_ready", party = party or {},
                 partyDigest = partyDigest })
end

function Protocol2.roomMsg(seq, msg)
  return build({ type = "room_msg", seq = seq, msg = msg })
end

function Protocol2.roomAck(seq)
  return build({ type = "room_ack", seq = seq })
end

function Protocol2.roomReport(match, result)
  return build({ type = "room_report", match = match, result = result })
end

function Protocol2.forfeit(match)
  return build({ type = "forfeit", match = match })
end

function Protocol2.roomKick(id)
  return build({ type = "room_kick", id = id })
end

function Protocol2.roomClose()
  return build({ type = "room_close" })
end

function Protocol2.lobbyQuery()
  return build({ type = "lobby_query" })
end

Protocol2.SHOT_CLOCKS = { 3, 6, 9 }
Protocol2.TOUR_STAGES = { registering = true, running = true, finished = true }
Protocol2.TOUR_MATCH_STATES = { pending = true, live = true, done = true,
                                bye = true }

function Protocol2.shotClock(value)
  local want = tonumber(value)
  if not want then return Protocol2.SHOT_CLOCKS[2] end
  local best, bestGap = Protocol2.SHOT_CLOCKS[2], math.huge
  for _, allowed in ipairs(Protocol2.SHOT_CLOCKS) do
    local gap = math.abs(allowed - want)
    if gap < bestGap then best, bestGap = allowed, gap end
  end
  return best
end

function Protocol2.tourCreate(opts)
  opts = opts or {}
  return build({
    type = "tour_create",
    profile = opts.profile,
    rule = opts.rule,
    playing = opts.playing ~= false,
    shotClock = Protocol2.shotClock(opts.shotClock),
    maxSpectators = opts.maxSpectators,
    party = opts.party,
    partyDigest = opts.partyDigest,
    public = opts.public ~= false,
    note = opts.note,
  })
end

function Protocol2.tourJoin(code, as, profile, party, partyDigest)
  return build({
    type = "tour_join",
    code = code,
    as = as or "player",
    profile = profile,
    party = party,
    partyDigest = partyDigest,
  })
end

function Protocol2.tourLeave()
  return build({ type = "tour_leave" })
end

function Protocol2.tourStart()
  return build({ type = "tour_start" })
end

function Protocol2.tourKick(id)
  return build({ type = "tour_kick", id = id })
end

function Protocol2.tourClose()
  return build({ type = "tour_close" })
end

Protocol2.CLIENT_TYPES = {
  lobby_hello = true, ping = true, pong = true, resume = true,
  advertise = true, unadvertise = true, room_create = true,
  room_join = true, room_leave = true, room_ready = true,
  room_msg = true, room_ack = true, room_report = true, forfeit = true,
  room_kick = true, room_close = true, lobby_query = true,
  tour_create = true, tour_join = true, tour_leave = true,
  tour_start = true, tour_kick = true, tour_close = true,
}

Protocol2.SERVER_TYPES = {
  lobby_welcome = true, lobby_list = true, lobby_delta = true,
  room_state = true, room_replay = true, room_msg = true,
  room_deadline = true, room_result = true, room_closed = true,
  match_start = true, match_start_spectate = true, join_error = true,
  ping = true, pong = true,
  tour_state = true, tour_match = true, tour_match_spectate = true,
  tour_bye = true, tour_deadline = true, tour_over = true,
  tour_closed = true,
}

Protocol2.RESULTS = { win = true, lose = true, draw = true }

local VALIDATORS = {}

VALIDATORS.lobby_welcome = function(m)
  if type(m.session) ~= "string" or m.session == "" then
    return nil, "lobby_welcome without a session id"
  end
  if type(m.you) ~= "table" then return nil, "lobby_welcome without you" end
  return m
end

VALIDATORS.lobby_list = function(m)
  if type(m.entries) ~= "table" then return nil, "lobby_list without entries" end
  return m
end

local DELTA_LISTS = { "added", "removed", "changed", "add", "update", "remove" }

VALIDATORS.lobby_delta = function(m)
  for _, key in ipairs(DELTA_LISTS) do
    if type(m[key]) == "table" and #m[key] > 0 then return m end
  end
  if type(m.op) == "string"
     and (type(m.entry) == "table" or type(m.id) == "string") then
    return m
  end
  return nil, "empty lobby_delta"
end

VALIDATORS.room_state = function(m)
  if type(m.code) ~= "string" then return nil, "room_state without a code" end
  if type(m.players) ~= "table" then return nil, "room_state without players" end
  return m
end

VALIDATORS.room_replay = function(m)
  if type(m.msgs) ~= "table" then return nil, "room_replay without msgs" end
  return m
end

VALIDATORS.room_msg = function(m)
  if type(m.msg) ~= "table" or type(m.msg.type) ~= "string" then
    return nil, "room_msg without an inner message"
  end
  if type(m.seq) ~= "number" then return nil, "room_msg without a seq" end
  return m
end

VALIDATORS.room_deadline = function(m)
  if type(m.kind) ~= "string" then return nil, "room_deadline without a kind" end
  if type(m.at) ~= "number" then return nil, "room_deadline without a time" end
  return m
end

VALIDATORS.match_start = function(m)
  if type(m.role) ~= "string" or m.role == "" then
    return nil, "match_start without a role"
  end
  if type(m.match) ~= "string" or m.match == "" then
    return nil, "match_start without a match token"
  end
  return m
end

VALIDATORS.match_start_spectate = VALIDATORS.match_start

VALIDATORS.room_closed = function(m)
  if type(m.reason) ~= "string" or m.reason == "" then
    return nil, "room_closed without a reason"
  end
  return m
end

VALIDATORS.room_result = function(m)
  if type(m.how) ~= "string" then return nil, "room_result without how" end
  return m
end

VALIDATORS.tour_state = function(m)
  if type(m.code) ~= "string" or m.code == "" then
    return nil, "tour_state without a code"
  end
  if type(m.players) ~= "table" then return nil, "tour_state without players" end
  if type(m.bracket) ~= "table" then return nil, "tour_state without a bracket" end
  if not Protocol2.TOUR_STAGES[m.stage or ""] then
    return nil, "tour_state without a stage"
  end
  return m
end

VALIDATORS.tour_match = function(m)
  if type(m.match) ~= "string" or m.match == "" then
    return nil, "tour_match without a match token"
  end
  if type(m.code) ~= "string" or m.code == "" then
    return nil, "tour_match without a child room code"
  end
  return m
end

VALIDATORS.tour_match_spectate = VALIDATORS.tour_match

VALIDATORS.tour_bye = function(m)
  if type(m.match) ~= "string" or m.match == "" then
    return nil, "tour_bye without a match token"
  end
  return m
end

VALIDATORS.tour_deadline = function(m)
  if type(m.kind) ~= "string" or m.kind == "" then
    return nil, "tour_deadline without a kind"
  end
  if type(m.at) ~= "number" then return nil, "tour_deadline without a time" end
  return m
end

VALIDATORS.tour_closed = function(m)
  if type(m.reason) ~= "string" or m.reason == "" then
    return nil, "tour_closed without a reason"
  end
  return m
end

VALIDATORS.tour_over = function(m)
  if type(m.code) ~= "string" or m.code == "" then
    return nil, "tour_over without a code"
  end
  return m
end

VALIDATORS.join_error = function(m)
  if type(m.reason) ~= "string" or m.reason == "" then
    return nil, "join_error without a reason"
  end
  return m
end

Protocol2.VALIDATORS = VALIDATORS

function Protocol2.validate(raw)
  if type(raw) ~= "table" then return nil, "not a table" end
  local msg = Wire.sanitize(raw)
  if not msg then return nil, "failed sanitize" end
  local validator = VALIDATORS[msg.type]
  if not validator then return msg end
  local ok, reason = validator(msg)
  if not ok then return nil, reason end
  return ok
end

local REASONS = {
  not_found = "That room code wasn't found.",
  full = "That room is full.",
  expired = "That room code has expired.",
  profile_mismatch = "Your game doesn't match the room.",
  rule_violation = "Your team doesn't meet the room's rule.",
  spectate_late = "That match is too far along to watch.",
  bad_ticket = "The relay didn't accept your sign-in.",
  lobby_disabled = "This relay isn't running online play.",
  resume_unknown = "The relay forgot your session.",
  resume_expired = "You were away too long to rejoin.",
  already_in_room = "You're already in a room.",
  spectators_full = "That room has all the spectators it can take.",
  bad_profile = "The relay couldn't read your game's profile.",
  bad_party = "The relay couldn't read your team.",
  party_ineligible = "Your team doesn't meet the room's rule.",
  tour_not_found = "That tournament code wasn't found.",
  tour_started = "That tournament has already started.",
  tour_full = "That tournament is full.",
  not_creator = "Only the tournament's creator can do that.",
}

local CLOSED_REASONS = {
  kicked = "The host removed you from the room.",
  closed = "The host closed the room.",
  idle = "The room was closed for being idle.",
  backlog = "You fell too far behind to keep watching.",
}

local TOUR_CLOSED_REASONS = {
  kicked = "The creator removed you from the tournament.",
  closed = "The creator closed the tournament.",
  idle = "The tournament was closed for being idle.",
}

function Protocol2.tourClosedText(msg)
  local reason = type(msg) == "table" and msg.reason or tostring(msg)
  return TOUR_CLOSED_REASONS[reason]
    or ("The tournament closed: " .. tostring(reason))
end

function Protocol2.roomClosedText(msg)
  local reason = type(msg) == "table" and msg.reason or tostring(msg)
  return CLOSED_REASONS[reason] or ("The room closed: " .. tostring(reason))
end

function Protocol2.joinErrorText(msg)
  local reason = type(msg) == "table" and msg.reason or tostring(msg)
  local text = REASONS[reason] or ("Couldn't join: " .. tostring(reason))
  local detail = type(msg) == "table" and msg.detail or nil
  if detail and detail ~= "" then return text .. " (" .. detail .. ")" end
  return text
end

return Protocol2
