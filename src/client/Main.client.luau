--!strict
-- Client bootstrap. Order matters: state first, then systems that subscribe to it.

local Controllers = script.Parent.Controllers
local StateController = require(Controllers.StateController)
local StationController = require(Controllers.StationController)
local WorldController = require(Controllers.WorldController)
local HudController = require(script.Parent.UI.HudController)
local OceanSpawner = require(script.Parent.Ocean.OceanSpawner)

HudController.init()
OceanSpawner.init()
WorldController.init()
StationController.init()
StateController.init() -- last: requests the first sync once every listener is connected
