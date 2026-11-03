--!strict
--[[
	FishFactory: builds low-poly sea creatures from primitive parts and SpecialMeshes.
	It needs no external assets. Each creature returns its parts with their offsets from the
	creature's root CFrame, so the spawner can move whole schools with one BulkMoveTo call.
	All parts are anchored, non-colliding, non-queryable and shadowless for mobile.
]]

export type CreatureKind = "Fish" | "Tropical" | "Jelly" | "Manta" | "Whale"

export type Creature = {
	model: Model,
	parts: { BasePart },
	offsets: { CFrame },
	tailIndex: number?, -- part that wags
	kind: CreatureKind,
	size: number,
}

local FishFactory = {}

local function basePart(model: Model, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function ellipsoid(model: Model, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = basePart(model, size, color, material)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

local function wedge(model: Model, size: Vector3, color: Color3, material: Enum.Material): WedgePart
	local p = Instance.new("WedgePart")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.Parent = model
	return p
end

-- Creatures face -Z (the CFrame LookVector) so lookAt-style orientation works directly.
function FishFactory.build(kind: CreatureKind, color: Color3, size: number, glowing: boolean): Creature
	local model = Instance.new("Model")
	model.Name = kind
	local material = if glowing then Enum.Material.Neon else Enum.Material.SmoothPlastic
	local accent = color:Lerp(Color3.new(1, 1, 1), 0.45)
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local tailIndex: number? = nil

	local function add(part: BasePart, offset: CFrame)
		table.insert(parts, part)
		table.insert(offsets, offset)
	end

	if kind == "Fish" or kind == "Tropical" then
		local height = if kind == "Tropical" then 1.4 else 0.8
		add(ellipsoid(model, Vector3.new(0.9, height, 2.2) * size, color, material), CFrame.new())
		add(wedge(model, Vector3.new(0.2, height * 0.9, 0.9) * size, accent, material), CFrame.new(0, 0, 1.35 * size) * CFrame.Angles(0, math.rad(180), 0))
		tailIndex = #parts
		add(wedge(model, Vector3.new(0.15, 0.5, 0.7) * size, accent, material), CFrame.new(0, height * 0.55 * size, 0.1 * size))
		local eyeColor = Color3.fromRGB(20, 20, 30)
		for _, side in { -1, 1 } do
			add(ellipsoid(model, Vector3.new(0.18, 0.22, 0.22) * size, eyeColor, Enum.Material.SmoothPlastic), CFrame.new(side * 0.4 * size, 0.12 * size, -0.65 * size))
		end
	elseif kind == "Jelly" then
		add(ellipsoid(model, Vector3.new(2, 1.3, 2) * size, color, Enum.Material.Neon), CFrame.new())
		for i = 1, 4 do
			local a = math.rad(i * 90 + 45)
			add(basePart(model, Vector3.new(0.15, 2.2, 0.15) * size, accent, Enum.Material.Neon), CFrame.new(math.cos(a) * 0.5 * size, -1.3 * size, math.sin(a) * 0.5 * size))
		end
		for _, part in parts do
			part.Transparency = 0.35
		end
	elseif kind == "Manta" then
		add(ellipsoid(model, Vector3.new(1.6, 0.5, 3) * size, color, material), CFrame.new())
		for _, side in { -1, 1 } do
			add(wedge(model, Vector3.new(0.2, 2.6, 2.6) * size, color, material), CFrame.new(side * 1.6 * size, 0, 0.2 * size) * CFrame.Angles(0, 0, math.rad(90 * side)))
		end
		add(basePart(model, Vector3.new(0.1, 0.1, 3) * size, accent, material), CFrame.new(0, 0, 2.8 * size))
		tailIndex = #parts
	elseif kind == "Whale" then
		add(ellipsoid(model, Vector3.new(3.2, 2.8, 9) * size, color, material), CFrame.new())
		add(ellipsoid(model, Vector3.new(2.4, 1.2, 6) * size, accent, material), CFrame.new(0, -1.1 * size, -0.6 * size))
		add(wedge(model, Vector3.new(0.4, 1.4, 3.6) * size, color, material), CFrame.new(0, 0, 5.2 * size) * CFrame.Angles(0, 0, math.rad(90)))
		tailIndex = #parts
		for _, side in { -1, 1 } do
			add(wedge(model, Vector3.new(0.3, 1.2, 2) * size, color, material), CFrame.new(side * 1.9 * size, -0.8 * size, -1 * size) * CFrame.Angles(0, 0, math.rad(70 * side)))
		end
	end

	return { model = model, parts = parts, offsets = offsets, tailIndex = tailIndex, kind = kind, size = size }
end

return FishFactory
