local object_ids = {
  [169785] = true,
  [164674] = true,
  [330193] = true,
  [169782] = true,
  [169662] = true,
  [169480] = true,
  [171166] = true,
  [157561] = true,
  [156480] = true,
  [167985] = true,
  [171159] = true,
  [167986] = true,
  [338483] = true,
  [167839] = true,
  [169628] = true,
  [324030] = true,
  [324031] = true,
  [167255] = true,
  [168173] = true,
  [170557] = true,
  [169783] = true,
  [164549] = true,
  [164624] = true
}

function RaijinLab:EnableTorghastModule()
  if not RaijinLab:ObjectListExists("torghast") then
    RaijinLab:AddObjectList("torghast", object_ids)
    RaijinLab:EnableObjectList("torgast")
  end
  if not RaijinLab:ObjectListEnabled("torghast") then
    RaijinLab:EnableObjectList("torghast")
  end
  if not RaijinLab:GetObjManagerFrame() then
    RaijinLab:InitObjectManager()
  end
  RaijinLab:AddDrawingCallback("objectTracker", RaijinLab.DrawTrackedObjects)
end

function RaijinLab:DisableTorghastModule()
  if not RaijinLab:ObjectListExists("torghast") then return end
  RaijinLab:DisableObjectList("torghast")
end
