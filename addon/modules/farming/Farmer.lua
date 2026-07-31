function RaijinLab:CreateFarmer(farm_name)
  local farm = RaijinLab.farmer.farms[farm_name]
  if farm then
    if RaijinLab.mob_farm_frame then
      RaijinLab:MobFarmDestroy()
    end
    RaijinLab:MobFarmInit(farm.farm_mobs, farm.farm_spells, farm.farm_spots)
  else
    print("Invalid farm name.")
  end
end

function RaijinLab:DestroyAllFarmers()
  RaijinLab:MobFarmDestroy()
end
