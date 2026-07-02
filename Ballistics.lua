local workspace = game:GetService("Workspace")

local Calibers = {
	["9x19mm"] = {
		Name = "9x19mm",
		Penetration = 35,
		RicochetModifier = 1.2,
		Mass = 7.5,
		Diameter = 0.0322,
		PenetrationEfficiency = 1.00,
		DeformationFactor = 0.15,
	},
	["5.56x45mm"] = {
		Name = "5.56x45mm",
		Penetration = 70,
		RicochetModifier = 0.9,
		Mass = 4.0,
		Diameter = 0.0204,
		PenetrationEfficiency = 1.05,
		DeformationFactor = 0.13,
	},
	["7.62x39mm"] = {
		Name = "7.62x39mm",
		Penetration = 85,
		RicochetModifier = 0.95,
		Mass = 8.0,
		Diameter = 0.0283,
		PenetrationEfficiency = 1.05,
		DeformationFactor = 0.13,
	},
	["7.62x54mmR"] = {
		Name = "7.62x54mmR",
		Penetration = 105,
		RicochetModifier = 0.85,
		Mass = 9.6,
		Diameter = 0.0283,
		PenetrationEfficiency = 1.15,
		DeformationFactor = 0.10,
	},
	["7.62x51mm"] = {
		Name = "7.62x51mm",
		Penetration = 110,
		RicochetModifier = 0.8,
		Mass = 9.5,
		Diameter = 0.0279,
		PenetrationEfficiency = 1.10,
		DeformationFactor = 0.12,
	},
	["9x39mm"] = {
		Name = "9x39mm",
		Penetration = 95,
		RicochetModifier = 0.75,
		Mass = 16.0,
		Diameter = 0.0322,
		PenetrationEfficiency = 1.40,
		DeformationFactor = 0.08,
	},
	["7.92x33mm Kurz"] = {
		Name = "7.92x33mm Kurz",
		Penetration = 90,
		RicochetModifier = 0.9,
		Mass = 8.1,
		Diameter = 0.0283,
		PenetrationEfficiency = 1.00,
		DeformationFactor = 0.15,
	},
	["12.7x55mm"] = {
		Name = "12.7x55mm",
		Penetration = 140,
		RicochetModifier = 0.6,
		Mass = 18.5,
		Diameter = 0.0454,
		PenetrationEfficiency = 1.50,
		DeformationFactor = 0.08,
	},
	["12.7x99mm"] = {
		Name = "12.7x99mm",
		Penetration = 200,
		RicochetModifier = 0.5,
		Mass = 42.9,
		Diameter = 0.0454,
		PenetrationEfficiency = 1.30,
		DeformationFactor = 0.10,
	},
	["12.7x108mm"] = {
		Name = "12.7x108mm",
		Penetration = 210,
		RicochetModifier = 0.45,
		Mass = 48.0,
		Diameter = 0.0454,
		PenetrationEfficiency = 1.40,
		DeformationFactor = 0.08,
	},
	["14.5x114mm"] = {
		Name = "14.5x114mm",
		Penetration = 260,
		RicochetModifier = 0.4,
		Mass = 64.0,
		Diameter = 0.0518,
		PenetrationEfficiency = 1.80,
		DeformationFactor = 0.05,
	},
}


local MaterialResistances = {
	[Enum.Material.Wood]          = 5000,
	[Enum.Material.WoodPlanks]    = 5000,
	[Enum.Material.Plastic]       = 6000,
	[Enum.Material.Glass]         = 2500,
	[Enum.Material.Foil]          = 8000,
	[Enum.Material.Fabric]        = 1500,
	[Enum.Material.Brick]         = 30000,
	[Enum.Material.Cobblestone]   = 25000,
	[Enum.Material.Concrete]      = 80000,
	[Enum.Material.Slate]         = 22000,
	[Enum.Material.Granite]       = 100000,
	[Enum.Material.Marble]        = 70000,
	[Enum.Material.Sandstone]     = 15000,
	[Enum.Material.Limestone]     = 18000,
	[Enum.Material.Pebble]        = 10000,
	[Enum.Material.Metal]         = 250000,
	[Enum.Material.DiamondPlate]  = 500000,
	[Enum.Material.CorrodedMetal] = 180000,
}

local resistanceScale = 1e6

local minGrazeCosine   = 0.087
local ricochetCosine   = 0.342
local ricochetFalloff  = 0.15

local deformVelocityPivot = 3200
local deformVelocityMin   = 0.5
local deformVelocityMax   = 1.5


local Ballistics = {}

function Ballistics.GetCaliberStats(caliberName)
	return Calibers[caliberName]
end

function Ballistics.FindWallExit(hitPos, direction, wallInstance)
	local depth = 50
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {wallInstance}
	local ray = workspace:Raycast(hitPos + direction * depth, -direction * depth, params)
	if ray then
		return ray.Position, (ray.Position - hitPos).Magnitude
	end
	return hitPos + direction * 1, 1
end

function Ballistics.Reflect(direction, normal)
	return direction - 2 * direction:Dot(normal) * normal
end

function Ballistics.Perturb(direction, amount)
	if amount <= 0 then return direction end
	local axis = direction:Cross(Vector3.new(math.random(), math.random(), math.random()))
	if axis.Magnitude < 1e-4 then return direction end
	axis = axis.Unit
	local angle = (math.random() - 0.5) * 2 * amount
	return CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(direction)
end


function Ballistics.CalculatePenetration(bulletData, wallData)
	local caliberStats = bulletData.CaliberStats
	if not caliberStats then
		caliberStats = Calibers[bulletData.Caliber]
	end
	if not caliberStats then
		return false, 0, 0
	end

	local m = bulletData.Mass
	local v = bulletData.Velocity
	local r = caliberStats.Diameter * 0.5
	local area = math.pi * r * r

	local dir = bulletData.Direction
	local normal = wallData.Normal
	local cosTheta = -dir:Dot(normal) 

	if cosTheta < minGrazeCosine + ricochetFalloff then
		local rolloff = math.clamp((minGrazeCosine + ricochetFalloff - cosTheta) / ricochetFalloff, 0, 1)
		if cosTheta < minGrazeCosine or math.random() < rolloff * rolloff then
			return false, 0, 1
		end
	end
	cosTheta = math.max(cosTheta, minGrazeCosine)

	local effectiveThickness = wallData.Thickness / cosTheta
	local Ein = 0.5 * m * v * v

	local Erequired = (wallData.MaterialResistance * resistanceScale * area * effectiveThickness)
		/ caliberStats.PenetrationEfficiency

	local velocityScale = math.clamp(v / deformVelocityPivot, deformVelocityMin, deformVelocityMax)
	local deformationLoss = Ein * (1 - cosTheta) * caliberStats.DeformationFactor * velocityScale

	local Eout = Ein - Erequired - deformationLoss
	if Eout <= 0 then
		return false, 0, 0 
	end

	if cosTheta < ricochetCosine and Eout < Ein * 0.4 then
		return false, 0, math.clamp(1 - Eout / Ein, 0, 1)
	end

	local Vout = math.sqrt(2 * Eout / m)

	local energyRatio = Eout / Ein
	local obliquePenalty = 1 + (1 - cosTheta)
	local penDeficit = math.clamp(Erequired / (caliberStats.Penetration + 1), 0, 4)
	local stabilityLoss = caliberStats.RicochetModifier
		* (1 - energyRatio)
		* obliquePenalty
		* (0.5 + 0.5 * penDeficit)

	return true, Vout, math.clamp(stabilityLoss, 0, 1)
end

function Ballistics.GetMaterialResistance(material)
	return MaterialResistances[material] or 2000
end

function Ballistics.ResolveHit(bulletData, wallData, randomPerturbationAmount)
	local penetrated, vOut, stabilityLoss = Ballistics.CalculatePenetration(bulletData, wallData)

	if penetrated then
		return {
			Type = "Penetration",
			NewVelocity = vOut,
			StabilityLoss = stabilityLoss,
		}
	elseif stabilityLoss > 0 then
		local reflected = Ballistics.Reflect(bulletData.Direction, wallData.Normal)
		reflected = Ballistics.Perturb(reflected, randomPerturbationAmount or 0.08 * stabilityLoss)
		local retainedSpeed = bulletData.Velocity * (0.35 + 0.4 * (1 - stabilityLoss))
		return {
			Type = "Ricochet",
			NewVelocity = retainedSpeed,
			ReflectedDirection = reflected,
			StabilityLoss = stabilityLoss,
		}
	else
		return { Type = "Stop" }
	end
end

return Ballistics