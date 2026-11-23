-- Thermal collector for prometheus-node-exporter-lua on the London Flint.
-- The 2022.04.18 opkg feed has no thermal or hwmon collector package, so
-- provision.sh copies this file to /usr/lib/lua/prometheus-collectors/.
-- The metric name and labels are those of the Go node_exporter:
--   node_thermal_zone_temp{zone="0",type="cpu-thermal"} 50.784
-- It reads the zones at scrape time and writes nothing to flash.
local function scrape()
  local temp = metric("node_thermal_zone_temp", "gauge")
  local zone = 0
  while true do
    local base = "/sys/class/thermal/thermal_zone" .. zone
    local millidegrees = tonumber(get_contents(base .. "/temp"))
    if not millidegrees then break end
    local kind = string.gsub(get_contents(base .. "/type"), "%s+$", "")
    temp({ zone = tostring(zone), type = kind }, millidegrees / 1000)
    zone = zone + 1
  end
end

return { scrape = scrape }
