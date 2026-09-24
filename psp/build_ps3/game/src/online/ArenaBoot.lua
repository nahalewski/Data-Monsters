local Protocol = require("src.link.Protocol")

local ArenaBoot = {}

local VERSIONS = {
  red = true, blue = true, yellow = true,
  gold = true, silver = true, crystal = true,
}

local ROLES = { host = true, guest = true, spectator = true }

local KINDS = { vanilla = true, cart = true }

local function isCallable(v)
  if type(v) == "function" then return true end
  if type(v) ~= "table" then return false end
  local mt = getmetatable(v)
  return type(mt) == "table" and type(mt.__call) == "function"
end

local function hasMethod(obj, name)
  if type(obj) ~= "table" then return false end
  return isCallable(obj[name])
end

local function isPackedParty(v)
  if type(v) ~= "table" then return false end
  for _, mon in ipairs(v) do
    if type(mon) ~= "table" or type(mon.species) ~= "string" then return false end
  end
  return true
end

local function level(v)
  return type(v) == "number" and v >= 1 and v <= 100 and math.floor(v) == v
end

local function normaliseRule(rule)
  if rule == nil then rule = {} end
  if type(rule) ~= "table" then return nil, "rule must be a table" end
  local size = rule.partySize
  if size == nil then size = 6 end
  if type(size) ~= "number" or size < 1 or size > 6 or math.floor(size) ~= size then
    return nil, "rule.partySize must be 1..6"
  end
  if rule.minLevel ~= nil and not level(rule.minLevel) then
    return nil, "rule.minLevel must be 1..100"
  end
  if rule.maxLevel ~= nil and not level(rule.maxLevel) then
    return nil, "rule.maxLevel must be 1..100"
  end
  if rule.minLevel and rule.maxLevel and rule.minLevel > rule.maxLevel then
    return nil, "rule.minLevel is above rule.maxLevel"
  end
  if rule.forceLevel ~= nil and not level(rule.forceLevel) then
    return nil, "rule.forceLevel must be 1..100"
  end
  return {
    partySize = size,
    minLevel = rule.minLevel,
    maxLevel = rule.maxLevel,
    forceLevel = rule.forceLevel,
  }
end

function ArenaBoot.profile(fields)
  if type(fields) ~= "table" then return nil, "profile must be a table" end
  local engine = fields.engine
  if engine ~= 1 and engine ~= 2 then return nil, "profile.engine must be 1 or 2" end
  if type(fields.version) ~= "string" or not VERSIONS[fields.version] then
    return nil, "profile.version is not a known game"
  end
  local kind = fields.kind or "vanilla"
  if not KINDS[kind] then return nil, "profile.kind must be vanilla or cart" end
  if kind == "cart" then
    local cart = fields.cart
    if type(cart) ~= "table" or type(cart.id) ~= "string" or cart.id == ""
        or type(cart.hash) ~= "string" or cart.hash == "" then
      return nil, "a cart profile needs cart.id and cart.hash"
    end
  end
  if fields.engineVersion ~= nil and type(fields.engineVersion) ~= "string" then
    return nil, "profile.engineVersion must be a string"
  end
  if fields.rulesetId ~= nil and type(fields.rulesetId) ~= "string" then
    return nil, "profile.rulesetId must be a string"
  end
  local rule, ruleErr = normaliseRule(fields.rule)
  if not rule then return nil, ruleErr end
  local cart = nil
  if kind == "cart" then
    cart = {
      id = fields.cart.id,
      version = fields.cart.version,
      hash = fields.cart.hash,
    }
  end
  return {
    engine = engine,
    version = fields.version,
    engineVersion = fields.engineVersion,
    apiVersion = fields.apiVersion,
    fingerprint = fields.fingerprint,
    rulesetId = fields.rulesetId,
    kind = kind,
    cart = cart,
    rule = rule,
  }
end

local function normaliseTeam(team, size)
  if team == nil then return nil end
  if type(team) ~= "table" then return nil, "team must be an array of party indices" end
  local seen, out = {}, {}
  for _, index in ipairs(team) do
    if type(index) ~= "number" or index < 1 or index > 6 or math.floor(index) ~= index then
      return nil, "team holds a party index outside 1..6"
    end
    if seen[index] then return nil, "team repeats a party index" end
    seen[index] = true
    out[#out + 1] = index
  end
  if #out == 0 then return nil, "team is empty" end
  if #out > size then return nil, "team is longer than the rule allows" end
  return out
end

function ArenaBoot.spec(fields)
  if type(fields) ~= "table" then return nil, "spec must be a table" end
  local profile, profileErr = ArenaBoot.profile(fields.profile)
  if not profile then return nil, profileErr end

  local role = fields.role
  if type(role) ~= "string" or not ROLES[role] then
    return nil, "role must be host, guest or spectator"
  end

  local spectating = role == "spectator"
  if not spectating then
    if type(fields.slotId) ~= "string" or fields.slotId == "" then
      return nil, "slotId is required"
    end
  elseif fields.slotId ~= nil and type(fields.slotId) ~= "string" then
    return nil, "slotId must be a string"
  end

  local team, teamErr = normaliseTeam(fields.team, profile.rule.partySize)
  if fields.team ~= nil and not team then return nil, teamErr end

  if type(fields.seed) ~= "number" then return nil, "seed must be a number" end

  local session = fields.session
  if not (hasMethod(session, "send") and hasMethod(session, "poll")
      and hasMethod(session, "close")) then
    return nil, "session must provide send, poll and close"
  end

  if fields.onDone ~= nil and not isCallable(fields.onDone) then
    return nil, "onDone must be a function"
  end

  if spectating then
    if not isPackedParty(fields.hostParty) or not isPackedParty(fields.guestParty) then
      return nil, "a spectator spec needs hostParty and guestParty"
    end
  else
    if not isPackedParty(fields.theirParty) then
      return nil, "theirParty must be a packed party"
    end
    if fields.myParty ~= nil and not isPackedParty(fields.myParty) then
      return nil, "myParty must be a packed party"
    end
  end

  local onDone = fields.onDone
  return {
    profile = profile,
    role = role,
    slotId = fields.slotId,
    team = team,
    seed = fields.seed,
    peerName = fields.peerName or "FOE",
    hostName = fields.hostName or "HOST",
    guestName = fields.guestName or "GUEST",
    myParty = fields.myParty,
    theirParty = fields.theirParty,
    hostParty = fields.hostParty,
    guestParty = fields.guestParty,
    session = session,
    onDone = function(result)
      if onDone then onDone(result) end
    end,
  }
end

function ArenaBoot.battleOpts(spec)
  if type(spec) ~= "table" or type(spec.profile) ~= "table" then
    return nil, "spec must carry a profile"
  end
  local rule = spec.profile.rule or {}
  if spec.role == "spectator" then
    return {
      hostParty = spec.hostParty,
      guestParty = spec.guestParty,
      hostName = spec.hostName,
      guestName = spec.guestName,
      seed = spec.seed,
      ruleset = spec.profile.rulesetId,
      verdict = "full",
      strict = true,
      forceLevel = rule.forceLevel,
      keepNetOpen = true,
    }
  end
  return {
    myParty = spec.myParty,
    theirParty = spec.theirParty,
    theirName = spec.peerName,
    role = spec.role,
    seed = spec.seed,
    ruleset = spec.profile.rulesetId,
    verdict = "full",
    strict = true,
    forceLevel = rule.forceLevel,
    keepNetOpen = true,
  }
end

function ArenaBoot.packOwnParty(game, spec)
  if type(spec) ~= "table" then return nil, "spec must be a table" end
  if spec.role == "spectator" then return nil end
  if isPackedParty(spec.myParty) and #spec.myParty > 0 then return spec.myParty end
  local party = game and game.save and game.save.party
  if type(party) ~= "table" then return nil, "no party to send" end
  local size = (spec.profile and spec.profile.rule and spec.profile.rule.partySize) or 6
  local indices = {}
  for _, index in ipairs(spec.team or {}) do
    if party[index] then indices[#indices + 1] = index end
  end
  if #indices == 0 then
    for index = 1, math.min(#party, size) do indices[index] = index end
  end
  if #indices == 0 then return nil, "no party to send" end
  spec.myParty = (spec.profile and spec.profile.engine == 2)
    and Protocol.packParty2(party, indices)
    or Protocol.packParty(party, indices)
  return spec.myParty
end

return ArenaBoot
