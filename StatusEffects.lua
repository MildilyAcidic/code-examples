--!strict

--[[ 
status/modifier system based of Valve's "Deadlock"  https://store.steampowered.com/app/1422450/Deadlock/?curator_clanid=4777282 

define an effect one time, apply it to any container. handles stacking, tick callbacks, buildup meters (like infernus afterburn), pause/timescale, tags, cleansing etc.

setup (call setContext before initilization so modules register the right callbacks):

server:
StatusEffect.setContext("server")
StatusEffect.Init({ effectsFolder = ReplicatedStorage.Effects })

client:
StatusEffect.setContext("client")
StatusEffect.Init({ effectsFolder = ReplicatedStorage.Effects })

 applying, with optional per instance overrides (these shadow the definition for that one instance only)
   container:apply("Burn", {
       source       = attacker,
       stacks       = 3,
       duration     = 10,   --> lasts longer than the def says
       intensity    = 20,   --> more damage
       tickInterval = 0.25, --> faster tick
   })

 effect modules can split callbacks by side, top callbacks run on both,
 the server{} / client{} subtables win when context does match:
   return {
       name = "Burn", duration = 5, tickInterval = 0.5,
       server = { onTick = function(self, target, dt) target:TakeDamage(...) end },
       client = { onStart = function(self, target) --burn vfx would go here-- end },
   }

]]

local StatusEffect = {}
StatusEffect.__index = StatusEffect


--[[

 "both"   --> only top callbacks fire (old behavior which is the default)
 "server" --> server{} subtable merges over the top callbacks
 "client" --> same but for client{}

]]
StatusEffect.context = "both"


function StatusEffect.setContext(ctx: string)
	assert(
		ctx == "server" or ctx == "client" or ctx == "both",
		"setContext: expected 'server', 'client', or 'both'"
	)
	StatusEffect.context = ctx
end

--> which keys specifically get pulled out of the server or client subtables when they merge
local callbackKeys = {
	"onStart", "onRefresh", "onStack", "onStackChanged",
	"onTick", "onExpire", "onRemove", "onEnd", "onBuildupTick",
}

local Registry:        { [string]: EffectDefinition  } = {}
local BuildupRegistry: { [string]: BuildupDefinition } = {}

local StackBehavior = {
	Refresh         = "Refresh",
	Extend          = "Extend",
	Stack           = "Stack",
	RefreshAndStack = "RefreshAndStack",
	ExtendAndStack  = "ExtendAndStack",
	Ignore          = "Ignore",
	Replace         = "Replace",
	KeepStrongest   = "KeepStrongest",
}
StatusEffect.StackBehavior = StackBehavior

local ConsumeMode = {
	Consume         = "Consume",
	ConsumeOverflow = "ConsumeOverflow",
	Keep            = "Keep",
	ConsumeAndLock  = "ConsumeAndLock",
}
StatusEffect.ConsumeMode = ConsumeMode

local Polarity = {
	Positive = "Positive",
	Negative = "Negative",
	Neutral  = "Neutral",
}
StatusEffect.Polarity = Polarity

export type EffectDefinition = {
	name: string,
	duration: number,
	tickInterval: number?,
	maxStacks: number,
	stackBehavior: string,
	independentStacks: boolean,
	priority: number,
	category: string?,
	polarity: string,
	tags: { [string]: boolean },
	intensity: number,
	intensityPerStack: number,

	onStart:        ((self: EffectInstance, target: any) -> ())?,
	onRefresh:      ((self: EffectInstance, target: any) -> ())?,
	onStack:        ((self: EffectInstance, target: any, added: number) -> ())?,
	onStackChanged: ((self: EffectInstance, target: any, delta: number) -> ())?,
	onTick:         ((self: EffectInstance, target: any, dt: number) -> ())?,
	onExpire:       ((self: EffectInstance, target: any) -> ())?,
	onRemove:       ((self: EffectInstance, target: any, reason: string) -> ())?,
}

export type EffectInstance = typeof(setmetatable(
	{} :: {
		def:    EffectDefinition,
		name:   string,
		target: any,
		source: any,
		container: any,
		intensity:         number,
		intensityPerStack: number,
		tickInterval:      number?,
		maxStacks:         number,

		stacks:          number,
		duration:        number,
		baseDuration:    number,
		remaining:       number,
		elapsed:         number,
		tickAccumulator: number,
		ticksFired:      number,
		stackTimers:     { number },

		paused:    boolean,
		timeScale: number,
		alive:     boolean,
		data:      { [any]: any },
	},
	StatusEffect
	))

export type BuildupDefinition = {
	name: string,
	threshold: number,
	maxBuildup: number,
	decayRate: number,
	decayDelay: number,
	consumeMode: string,
	perStackAmount: number,
	procEffect: string?,
	procStacks: number,
	procExtendable: boolean,
	tags: { [string]: boolean },
	tickInterval: number?,

	onBuild:       ((self: BuildupMeter, target: any, added: number) -> ())?,
	onProc:        ((self: BuildupMeter, target: any, procCount: number) -> ())?,
	onDecay:       ((self: BuildupMeter, target: any, lost: number) -> ())?,
	onReset:       ((self: BuildupMeter, target: any) -> ())?,
	onBuildupTick: ((self: BuildupMeter, target: any, dt: number) -> ())?,
}

export type BuildupMeter = typeof(setmetatable(
	{} :: {
		def:             BuildupDefinition,
		name:            string,
		target:          any,
		container:       any,
		amount:          number,
		timeSinceGain:   number,
		tickAccumulator: number,
		locked:          boolean,
		procsFired:      number,
		paused:          boolean,
		data:            { [any]: any },
	},
	StatusEffect
	))

local function shallowCopy<T>(t: T): T
	local out = {}
	for k, v in pairs(t :: any) do out[k] = v end
	return (out :: any) :: T
end

local function toTagSet(tags: { string }?): { [string]: boolean }
	local set = {}
	if tags then
		for _, tag in ipairs(tags) do set[tag] = true end
	end
	return set
end

local function safeCall(fn: any, ...): ()
	if not fn then return end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("statusDebug: callback error: " .. tostring(err))
	end
end

local function normalizePolarity(value: any): string
	if type(value) ~= "string" then return Polarity.Neutral end
	local l = string.lower(value)
	if l == "positive" then return Polarity.Positive
	elseif l == "negative" then return Polarity.Negative
	elseif l == "neutral"  then return Polarity.Neutral
	end
	warn("statusDebug: unknown polarity '" .. value .. "', defaulting to Neutral")
	return Polarity.Neutral
end

local function mergeContextCallbacks(base: { [string]: any }, sub: { [string]: any }?): { [string]: any }
	local out = shallowCopy(base)
	if sub then
		for _, key in ipairs(callbackKeys) do
			if sub[key] ~= nil then
				out[key] = sub[key]
			end
		end
	end
	return out
end

local function applyContextToConfig(config: { [string]: any }): { [string]: any }
	local ctx = StatusEffect.context
	if ctx == "both" then
		return config
	end
	return mergeContextCallbacks(config, config[ctx])
end

--> define an effect

function StatusEffect.define(name: string, config: { [string]: any }): EffectDefinition
	assert(type(name) == "string" and name ~= "", "StatusEffect.define: name required")
	if Registry[name] then
		warn("statusDebug: redefining existing effect: " .. name)
	end

	--> resolve server or client callbacks first, then read everything off the cfg
	local cfg = applyContextToConfig(config)

	local polarity = normalizePolarity(cfg.polarity)
	local tags = toTagSet(cfg.tags)
	tags[polarity] = true

	--> onEnd is basically onRemove
	local onEnd    = cfg.onEnd
	local onRemove = cfg.onRemove
	local mergedOnRemove = onRemove
	if onEnd then
		mergedOnRemove = function(self, target, reason)
			safeCall(onEnd, self, target, reason)
			if onRemove then safeCall(onRemove, self, target, reason) end
		end
	end

	local def: EffectDefinition = {
		name              = name,
		duration          = cfg.duration or 0,
		tickInterval      = cfg.tickInterval,
		maxStacks         = cfg.maxStacks or 1,
		stackBehavior     = cfg.stackBehavior or StackBehavior.Refresh,
		independentStacks = cfg.independentStacks == true,
		priority          = cfg.priority or 0,
		category          = cfg.category,
		polarity          = polarity,
		tags              = tags,
		intensity         = cfg.intensity or 1,
		intensityPerStack = cfg.intensityPerStack or 0,

		onStart        = cfg.onStart,
		onRefresh      = cfg.onRefresh,
		onStack        = cfg.onStack,
		onStackChanged = cfg.onStackChanged,
		onTick         = cfg.onTick,
		onExpire       = cfg.onExpire,
		onRemove       = mergedOnRemove,
	}

	Registry[name] = def
	return def
end

function StatusEffect.getDefinition(name: string): EffectDefinition?
	return Registry[name]
end

function StatusEffect.isDefined(name: string): boolean
	return Registry[name] ~= nil
end

function StatusEffect.defineBuildup(name: string, config: { [string]: any }): BuildupDefinition
	assert(type(name) == "string" and name ~= "", "defineBuildup: name required")
	if BuildupRegistry[name] then
		warn("statusDebug: redefining existing buildup: " .. name)
	end

	local cfg = applyContextToConfig(config)

	local threshold = cfg.threshold or 100
	local def: BuildupDefinition = {
		name           = name,
		threshold      = threshold,
		maxBuildup     = math.max(cfg.maxBuildup or threshold, threshold),
		decayRate      = cfg.decayRate or 0,
		decayDelay     = cfg.decayDelay or 0,
		consumeMode    = cfg.consumeMode or ConsumeMode.Consume,
		perStackAmount = cfg.perStackAmount or 1,
		procEffect     = cfg.procEffect,
		procStacks     = cfg.procStacks or 1,
		procExtendable = cfg.procExtendable ~= false,
		tags           = toTagSet(cfg.tags),
		tickInterval   = cfg.tickInterval,

		onBuild       = cfg.onBuild,
		onProc        = cfg.onProc,
		onDecay       = cfg.onDecay,
		onReset       = cfg.onReset,
		onBuildupTick = cfg.onBuildupTick,
	}

	BuildupRegistry[name] = def
	return def
end

function StatusEffect.getBuildupDefinition(name: string): BuildupDefinition?
	return BuildupRegistry[name]
end


--[[
for status effects living in their own modules

StatusEffect.setContext("server")
StatusEffect.register(require(script.Parent.Burn))

or just point Init at a folder. modules need a 'name', everything else is optional. add a 'buildup = { threshold = ... }' table if the effect procs off a meter
]]

function StatusEffect.register(module: { [string]: any }): EffectDefinition
	assert(type(module) == "table", "register: expected a module table")
	local name = module.name
	assert(type(name) == "string" and name ~= "", "register: module needs a 'name'")

	local def = StatusEffect.define(name, module)

	local buildup = module.buildup
	if buildup or module.onBuildupTick then
		local bcfg = {} :: any
		if type(buildup) == "table" then
			for k, v in pairs(buildup) do bcfg[k] = v end
		end
		if bcfg.procEffect    == nil then bcfg.procEffect    = name end
		if bcfg.onBuildupTick == nil then bcfg.onBuildupTick = module.onBuildupTick end
		--> buildup inherits the module's server or client tables unless it has its own
		if bcfg.server == nil and module.server ~= nil then bcfg.server = module.server end
		if bcfg.client == nil and module.client ~= nil then bcfg.client = module.client end
		StatusEffect.defineBuildup(bcfg.name or name, bcfg)
	end

	return def
end

function StatusEffect.registerBuildup(module: { [string]: any }): BuildupDefinition
	assert(type(module) == "table", "registerBuildup: expected a module table")
	local name = module.name
	assert(type(name) == "string" and name ~= "", "registerBuildup: module needs a 'name'")
	return StatusEffect.defineBuildup(name, module)
end

function StatusEffect.registerFolder(folder: any, requireFn: ((any) -> any)?): number
	assert(folder ~= nil, "registerFolder: folder required")
	local req = requireFn or require
	local count = 0
	for _, child in ipairs(folder:GetChildren()) do
		local isModule = (typeof ~= nil and typeof(child) == "Instance" and child:IsA("ModuleScript"))
			or (child.ClassName == "ModuleScript")
		if isModule then
			local ok, mod = pcall(req, child)
			if ok and type(mod) == "table" and mod.name then
				StatusEffect.register(mod)
				count += 1
			else
				warn("statusDebug: registerFolder: skipped '" .. tostring(child) .. "'")
			end
		end
	end
	return count
end

--> overrides, flat table of per-instance stats pulled out of apply() options
--> supports duration, intensity, intensityPerStack, tickInterval, maxStacks
local function newInstance(
	def:       EffectDefinition,
	target:    any,
	source:    any,
	container: any,
	overrides: { [string]: any }?
): EffectInstance

	overrides = overrides or {}

	local rawDur      = overrides.duration or def.duration
	local isPermanent = (rawDur <= 0) or (rawDur == math.huge)
	local dur         = isPermanent and math.huge or rawDur

	local intensity         = overrides.intensity         or def.intensity
	local intensityPerStack = overrides.intensityPerStack or def.intensityPerStack
	local tickInterval      = overrides.tickInterval      or def.tickInterval
	local maxStacks         = overrides.maxStacks         or def.maxStacks

	local self = setmetatable({
		def       = def,
		name      = def.name,
		target    = target,
		source    = source,
		container = container,
		intensity         = intensity,
		intensityPerStack = intensityPerStack,
		tickInterval      = tickInterval,
		maxStacks         = maxStacks,

		stacks          = 1,
		duration        = dur,
		baseDuration    = dur,  --> what Extend adds each time, never inflated
		remaining       = dur,
		elapsed         = 0,
		tickAccumulator = 0,
		ticksFired      = 0,

		stackTimers = def.independentStacks and { dur } or {},

		paused    = false,
		timeScale = 1,
		alive     = true,
		data      = {},
	}, StatusEffect)

	return (self :: any) :: EffectInstance
end

function StatusEffect.getIntensity(self: EffectInstance): number
	return self.intensity + self.intensityPerStack * (self.stacks - 1)
end


function StatusEffect.getProgress(self: EffectInstance): number
	if self.duration == math.huge or self.duration <= 0 then return 1 end --> 0..1 fraction of duration left, permanent effects report 1
	return math.clamp(self.remaining / self.duration, 0, 1)
end

function StatusEffect.isPermanent(self: EffectInstance): boolean
	return self.duration == math.huge
end

function StatusEffect.hasTag(self: EffectInstance, tag: string): boolean
	return self.def.tags[tag] == true
end

function StatusEffect.pause(self: EffectInstance)  self.paused = true  end
function StatusEffect.resume(self: EffectInstance) self.paused = false end

function StatusEffect.setTimeScale(self: EffectInstance, scale: number)
	self.timeScale = math.max(0, scale)
end

function StatusEffect.refresh(self: EffectInstance)
	if self.duration == math.huge then return end
	self.remaining = self.duration
	if self.def.independentStacks then
		for i = 1, #self.stackTimers do
			self.stackTimers[i] = self.duration
		end
	end
	safeCall(self.def.onRefresh, self, self.target)
end

function StatusEffect.addStacks(self: EffectInstance, n: number)
	if n == 0 then return end
	local before = self.stacks
	local after  = math.clamp(self.stacks + n, 0, self.maxStacks)
	local delta  = after - before
	if delta == 0 then return end

	self.stacks = after

	if self.def.independentStacks then
		if delta > 0 then
			for _ = 1, delta do
				table.insert(self.stackTimers, self.duration)
			end
		else
			for _ = 1, -delta do
				table.remove(self.stackTimers, 1)
			end
		end
	end

	if delta > 0 then
		safeCall(self.def.onStack, self, self.target, delta)
	end
	safeCall(self.def.onStackChanged, self, self.target, delta)

	if self.stacks <= 0 then
		self.container:remove(self.name, "expired")
	end
end

function StatusEffect.setStacks(self: EffectInstance, n: number)
	StatusEffect.addStacks(self, n - self.stacks)
end

function StatusEffect.dispel(self: EffectInstance, reason: string?)
	self.container:remove(self.name, reason or "dispelled")
end

local function instanceUpdate(self: EffectInstance, dt: number): boolean
	if self.paused or not self.alive then return self.alive end

	local scaled = dt * self.timeScale
	self.elapsed += scaled

	local interval = self.tickInterval
	if interval and interval > 0 and self.def.onTick then
		self.tickAccumulator += scaled
		while self.tickAccumulator >= interval do
			self.tickAccumulator -= interval
			self.ticksFired += 1
			safeCall(self.def.onTick, self, self.target, interval)
			if not self.alive then return false end
		end
	end

	if self.duration ~= math.huge then
		if self.def.independentStacks then
			local expiredCount = 0
			local i = 1
			while i <= #self.stackTimers do
				self.stackTimers[i] -= scaled
				if self.stackTimers[i] <= 0 then
					table.remove(self.stackTimers, i)
					expiredCount += 1
				else
					i += 1
				end
			end
			if expiredCount > 0 then
				StatusEffect.addStacks(self, -expiredCount)
				if not self.alive then return false end
			end
			local maxT = 0
			for _, t in ipairs(self.stackTimers) do
				if t > maxT then maxT = t end
			end
			self.remaining = maxT
			if #self.stackTimers == 0 then return false end
		else
			self.remaining -= scaled
			if self.remaining <= 0 then
				self.remaining = 0
				return false
			end
		end
	end

	return true
end

local function newMeter(def: BuildupDefinition, target: any, container: any): BuildupMeter
	local self = setmetatable({
		def             = def,
		name            = def.name,
		target          = target,
		container       = container,
		amount          = 0,
		timeSinceGain   = 0,
		tickAccumulator = 0,
		locked          = false,
		procsFired      = 0,
		paused          = false,
		data            = {},
	}, StatusEffect)
	return (self :: any) :: BuildupMeter
end

function StatusEffect.getBuildupProgress(self: BuildupMeter): number
	return math.clamp(self.amount / self.def.threshold, 0, 1)
end

local function applyProcEffect(self: BuildupMeter, procCount: number)
	local def = self.def
	if not def.procEffect then return end
	local container = self.container
	local already   = container:has(def.procEffect)

	--> nonextendable procs don't reapply while the effect is still up
	if already and not def.procExtendable then return end

	container:apply(def.procEffect, {
		source = self.data.source,
		stacks = def.procStacks * procCount,
	})

	if def.consumeMode == ConsumeMode.ConsumeAndLock then
		--> meter stays locked until the proc effect goes away, at which point Container.remove unlocks with __buildupLockOwner
		self.locked = true
		local procInst = container:get(def.procEffect)
		if procInst then
			procInst.data.__buildupLockOwner = self
		end
	end
end

function StatusEffect.addBuildup(self: BuildupMeter, amount: number, source: any?)
	if self.locked then return end
	if amount == 0 then return end
	if source ~= nil then self.data.source = source end

	local def = self.def
	local wasBelow = self.amount < def.threshold

	self.amount = math.clamp(self.amount + amount, 0, def.maxBuildup)
	self.timeSinceGain = 0
	safeCall(def.onBuild, self, self.target, amount)

	if self.amount < def.threshold then return end

	local mode = def.consumeMode

	if mode == ConsumeMode.ConsumeOverflow then
		--> big hit can proc multiple times leftover carries over
		local procCount = math.floor(self.amount / def.threshold)
		self.amount -= def.threshold * procCount
		self.procsFired += procCount
		safeCall(def.onProc, self, self.target, procCount)
		applyProcEffect(self, procCount)

	elseif mode == ConsumeMode.Keep then
		--> meter stays full only proc on the crossing (otherwise every gain past threshold would spam procs)
		if not wasBelow then return end
		self.procsFired += 1
		safeCall(def.onProc, self, self.target, 1)
		applyProcEffect(self, 1)

	else
		self.amount = 0
		self.procsFired += 1
		safeCall(def.onProc, self, self.target, 1)
		safeCall(def.onReset, self, self.target)
		applyProcEffect(self, 1)
	end
end

function StatusEffect.resetBuildup(self: BuildupMeter, releaseLock: boolean?)
	self.amount = 0
	if releaseLock then self.locked = false end
	safeCall(self.def.onReset, self, self.target)
end

function StatusEffect.releaseLock(self: BuildupMeter)
	self.locked = false
end

local function meterUpdate(self: BuildupMeter, dt: number)
	if self.paused then return end
	self.timeSinceGain += dt

	local def = self.def

	if def.onBuildupTick and self.amount > 0 then
		local interval = def.tickInterval
		if interval and interval > 0 then
			self.tickAccumulator += dt
			while self.tickAccumulator >= interval and self.amount > 0 do
				self.tickAccumulator -= interval
				safeCall(def.onBuildupTick, self, self.target, interval)
			end
		else
			safeCall(def.onBuildupTick, self, self.target, dt)
		end
	end

	if def.decayRate > 0 and self.amount > 0 and not self.locked then
		if self.timeSinceGain >= def.decayDelay then
			local lost = math.min(self.amount, def.decayRate * dt)
			if lost > 0 then
				self.amount -= lost
				safeCall(def.onDecay, self, self.target, lost)
			end
		end
	end
end



local Container = {} --> one of these per entity and holds live effect instances + buildup meters and gets stepped by the manager (or manually via :update)
Container.__index = Container
StatusEffect.Container = Container

export type Container = typeof(setmetatable(
	{} :: {
		owner:    any,
		effects:  { [string]: EffectInstance },
		_order:   { string },
		meters:   { [string]: BuildupMeter },
		_managed: boolean,
		_busy:    boolean,
		_id:      number,
	},
	Container
	))

function Container.new(owner: any): Container
	local self = setmetatable({
		owner    = owner,
		effects  = {},
		_order   = {},
		meters   = {},
		_managed = false,
		_busy    = false,
		_id      = 0,
	}, Container)
	StatusEffect._registerContainer(self :: any)
	return self :: any
end

function Container.destroy(self: Container)
	self:removeAll("destroyed")
	self.meters = {}
	StatusEffect._unregisterContainer(self :: any)
end

--> options { source, stacks, duration, intensity, intensityPerStack,  tickInterval, maxStacks } the last five override the def for this instance only         
function Container.apply(self: Container, name: string, options: { [string]: any }?): EffectInstance?
	local def = Registry[name]
	if not def then
		warn("statusDebug: apply: unknown effect '" .. tostring(name) .. "'")
		return nil
	end
	options = options or {}
	local source    = options.source
	local addStacks = options.stacks or 1

	local overrides: { [string]: any } = {
		duration          = options.duration,
		intensity         = options.intensity,
		intensityPerStack = options.intensityPerStack,
		tickInterval      = options.tickInterval,
		maxStacks         = options.maxStacks,
	}

	local existing = self.effects[name]

	if not existing then
		local inst = newInstance(def, self.owner, source, self, overrides)
		if addStacks > 1 then
			inst.stacks = math.clamp(addStacks, 1, inst.maxStacks)
			if def.independentStacks then
				inst.stackTimers = {}
				for _ = 1, inst.stacks do
					table.insert(inst.stackTimers, inst.duration)
				end
			end
		end
		self.effects[name] = inst
		table.insert(self._order, name)
		safeCall(def.onStart, inst, self.owner)
		-- TODO: this really should be a RemoteEvent:FireAllClients
		if game:GetService("RunService"):IsServer() then
			local owner = self.owner
			for _, player in game:GetService("Players"):GetPlayers() do
				task.spawn(function()
					game.ReplicatedStorage.Remotes.StatusReplication:InvokeClient(
						player, "apply", owner, name, options
					)
				end)
			end
		end

		return inst
	end

	local behavior = def.stackBehavior

	if behavior == StackBehavior.Ignore then
		return existing

	elseif behavior == StackBehavior.Replace then
		self:remove(name, "replaced")
		return self:apply(name, options)

	elseif behavior == StackBehavior.Refresh then
		StatusEffect.refresh(existing)
		return existing

	elseif behavior == StackBehavior.Extend then
		existing.remaining += existing.baseDuration
		existing.duration = math.max(existing.duration, existing.remaining)
		safeCall(def.onRefresh, existing, self.owner)
		return existing

	elseif behavior == StackBehavior.Stack then
		StatusEffect.addStacks(existing, addStacks)
		return existing

	elseif behavior == StackBehavior.RefreshAndStack then
		StatusEffect.addStacks(existing, addStacks)
		StatusEffect.refresh(existing)
		return existing

	elseif behavior == StackBehavior.ExtendAndStack then
		StatusEffect.addStacks(existing, addStacks)
		existing.remaining += existing.baseDuration
		existing.duration = math.max(existing.duration, existing.remaining)
		return existing

	elseif behavior == StackBehavior.KeepStrongest then
		local incomingStacks = math.clamp(addStacks, 1, existing.maxStacks)
		local incomingDuration = overrides.duration or def.duration
		if incomingStacks > existing.stacks then
			StatusEffect.setStacks(existing, incomingStacks)
			StatusEffect.refresh(existing)
		elseif incomingDuration > existing.remaining then
			StatusEffect.refresh(existing)
		end
		return existing
	end

	return existing
end

function Container.get(self: Container, name: string): EffectInstance?
	return self.effects[name]
end

function Container.has(self: Container, name: string): boolean
	return self.effects[name] ~= nil
end

function Container.getStacks(self: Container, name: string): number
	local e = self.effects[name]
	return e and e.stacks or 0
end

function Container.remove(self: Container, name: string, reason: string?)
	local inst = self.effects[name]
	if not inst then return end
	inst.alive = false
	self.effects[name] = nil
	local idx = table.find(self._order, name)
	if idx then table.remove(self._order, idx) end

	reason = reason or "removed"
	if reason == "expired" then
		safeCall(inst.def.onExpire, inst, self.owner)
	end
	safeCall(inst.def.onRemove, inst, self.owner, reason)

	local lockOwner = inst.data.__buildupLockOwner
	if lockOwner then lockOwner.locked = false end

	if game:GetService("RunService"):IsServer() then
		local owner = self.owner
		for _, player in game:GetService("Players"):GetPlayers() do
			task.spawn(function()
				game.ReplicatedStorage.Remotes.StatusReplication:InvokeClient( -- Fuckj my chud life
					player, "remove", owner, name, { reason = reason }
				)
			end)
		end
	end
end

function Container.removeAll(self: Container, reason: string?)
	for _, name in ipairs(shallowCopy(self._order)) do
		self:remove(name, reason or "cleared")
	end
end

function Container.removeByTag(self: Container, tag: string, reason: string?)
	for _, name in ipairs(shallowCopy(self._order)) do
		local inst = self.effects[name]
		if inst and inst.def.tags[tag] then
			self:remove(name, reason or "cleansed")
		end
	end
end

function Container.getByTag(self: Container, tag: string): { EffectInstance }
	local out = {}
	for _, name in ipairs(self._order) do
		local inst = self.effects[name]
		if inst and inst.def.tags[tag] then
			table.insert(out, inst)
		end
	end
	return out
end

function Container.getByPolarity(self: Container, polarity: string): { EffectInstance }
	return self:getByTag(normalizePolarity(polarity))
end

--> strip up to #n effects of a polarity (highest priority first) optionally filtered to a tag. count = nil strips all of them
function Container.cleanse(
	self:      Container,
	polarity:  string,
	count:     number?,
	reason:    string?,
	tagFilter: string?
): number
	polarity = normalizePolarity(polarity)
	local candidates = {}
	for _, name in ipairs(self._order) do
		local inst = self.effects[name]
		if inst and inst.def.tags[polarity] then
			if tagFilter == nil or inst.def.tags[tagFilter] then
				table.insert(candidates, inst)
			end
		end
	end

	if count ~= nil then
		table.sort(candidates, function(a: any, b: any)
			return a.def.priority > b.def.priority
		end)
	end

	local removed = 0
	for _, inst: any in ipairs(candidates) do
		if count ~= nil and removed >= count then break end
		self:remove(inst.name, reason or "cleansed")
		removed += 1
	end
	return removed
end

function Container.cleanseDebuffs(self: Container, count: number?, reason: string?): number
	return self:cleanse(Polarity.Negative, count, reason or "cleansed")
end

function Container.dispelBuffs(self: Container, count: number?, reason: string?): number
	return self:cleanse(Polarity.Positive, count, reason or "dispelled")
end

function Container.purge(self: Container, reason: string?): number
	local n = #self._order
	self:removeAll(reason or "purged")
	return n
end

function Container.sumIntensity(self: Container, tag: string?): number
	local total = 0
	for _, name in ipairs(self._order) do
		local inst = self.effects[name]
		if inst and (tag == nil or inst.def.tags[tag]) then
			total += StatusEffect.getIntensity(inst)
		end
	end
	return total
end

function Container.build(self: Container, name: string, options: { [string]: any }?): BuildupMeter?
	local def = BuildupRegistry[name]
	if not def then
		warn("statusDebug: build: unknown buildup '" .. tostring(name) .. "'")
		return nil
	end
	options = options or {}

	local meter = self.meters[name]
	if not meter then
		meter = newMeter(def, self.owner, self)
		self.meters[name] = meter
	end

	local amount = options.amount
	if amount == nil then
		amount = def.perStackAmount * (options.stacks or 1)
	end
	StatusEffect.addBuildup(meter, amount, options.source)
	return meter
end

function Container.getMeter(self: Container, name: string): BuildupMeter?
	return self.meters[name]
end

function Container.getBuildup(self: Container, name: string): number
	local m = self.meters[name]
	return m and m.amount or 0
end

function Container.hasMeter(self: Container, name: string): boolean
	return self.meters[name] ~= nil
end

function Container.clearMeter(self: Container, name: string)
	self.meters[name] = nil
end

function Container.update(self: Container, dt: number)
	for _, name in ipairs(shallowCopy(self._order)) do
		local inst = self.effects[name]
		if inst and inst.alive then
			local stillAlive = instanceUpdate(inst, dt)
			if not stillAlive and inst.alive then
				self:remove(name, "expired")
			end
		end
	end

	for meterName in pairs(self.meters) do
		local meter = self.meters[meterName]
		if meter then meterUpdate(meter, dt) end
	end
end


function Container.updateAsync(self: Container, dt: number, spawnFn: ((any, ...any) -> ())?)
	local spawn = spawnFn or (task and task.spawn) or function(fn, ...) fn(...) end

	for _, name in ipairs(shallowCopy(self._order)) do
		local inst = self.effects[name]
		if inst and inst.alive then
			spawn(function()
				if not inst.alive then return end
				local stillAlive = instanceUpdate(inst, dt)
				if not stillAlive and inst.alive then
					self:remove(name, "expired")
				end
			end)
		end
	end

	for meterName in pairs(self.meters) do
		local meter = self.meters[meterName]
		if meter then
			spawn(function() meterUpdate(meter, dt) end)
		end
	end
end

local Manager = {
	containers  = {} :: { [number]: Container },
	_nextId     = 1,
	_count      = 0,
	connection  = nil :: any,
	async       = true,
	initialized = false,
	timeScale   = 1,
}
StatusEffect.Manager = Manager

function StatusEffect._registerContainer(container: Container)
	if container._managed then return end
	local id = Manager._nextId
	Manager._nextId += 1
	container._id      = id
	container._managed = true
	Manager.containers[id] = container
	Manager._count += 1
end

function StatusEffect._unregisterContainer(container: Container)
	if not container._managed then return end
	Manager.containers[container._id] = nil
	container._managed = false
	Manager._count -= 1
end

function StatusEffect.step(dt: number)
	local scaled = dt * Manager.timeScale
	for id in pairs(Manager.containers) do
		local container = Manager.containers[id]
		if container then
			if Manager.async then
				if not container._busy then
					container._busy = true
					local spawn = (task and task.spawn) or function(fn, ...) fn(...) end
					spawn(function()
						container:updateAsync(scaled)
						container._busy = false
					end)
				end
			else
				container:update(scaled)
			end
		end
	end
end


function StatusEffect.Init(config: { [string]: any }?): typeof(Manager)
	config = config or {}

	if config.effectsFolder then
		local n = StatusEffect.registerFolder(config.effectsFolder)
		print("statusDebug: registered " .. n .. " effect module(s) [context=" .. StatusEffect.context .. "]")
	end
	if config.buildupFolder then
		for _, child in ipairs(config.buildupFolder:GetChildren()) do
			local ok, mod = pcall(require, child)
			if ok and type(mod) == "table" and mod.name then
				StatusEffect.registerBuildup(mod)
			end
		end
	end

	Manager.async = config.async ~= false

	local connection: RBXScriptConnection = Manager.connection
	if connection then
		if connection.Disconnect then connection:Disconnect() end
		Manager.connection = nil
	end

	local heartbeat = config.heartbeat
	if not heartbeat then
		local ok, RunService = pcall(function()
			return game:GetService("RunService")
		end)
		if ok and RunService then
			heartbeat = RunService.Heartbeat
		end
	end

	if heartbeat and heartbeat.Connect then
		Manager.connection = heartbeat:Connect(function(dt: number)
			StatusEffect.step(dt)
		end)
	else
		warn("statusDebug: Init: no Heartbeat available; call StatusEffect.step(dt) manually")
	end

	Manager.initialized = true
	return Manager
end

function StatusEffect.Shutdown()
	local connection: RBXScriptConnection = Manager.connection
	if connection and connection.Disconnect then
		connection:Disconnect()
	end
	Manager.connection = nil
	for id in pairs(Manager.containers) do
		local c = Manager.containers[id]
		if c then c._managed = false end
	end
	Manager.containers = {}
	Manager._count      = 0
	Manager.initialized = false
end

function StatusEffect.getContainerCount(): number
	return Manager._count
end

return StatusEffect