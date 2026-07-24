--!strict

-- Frozen compatibility boundary. The experimental procedural implementation
-- remains in ProceduralChibiRenderer; the hybrid runtime consumes it only as
-- an immediate fallback while a validated SpritePackage is unavailable.
return require(script.Parent:WaitForChild("ProceduralChibiRenderer"))
