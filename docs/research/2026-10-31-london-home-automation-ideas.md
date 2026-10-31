# London HA idea catalogue

I checked ha-london read-only (HA 2026.10.1 on the Pi 3, 327 entities), what the Alexa skill can do, which cluster signals the Pi can reach, and the household context from memory. Nothing was changed, sent or bought: only GETs, file reads and history replays. Every idea had to cost £0 unless it says otherwise. All 42 ideas passed verification, most with caveats, and the plans below are the corrected versions.

One note applies to most ideas. UI helpers (template, statistics, input_number) and automation edits only reload automations, so they never touch the Anca presence templates. A YAML `template:` change or a new integration (`rest`, `prometheus`, `alexa` filter) needs a reload or restart. In 2026.10.1 restarts already restore the presence sensors: 3 restarts in 10 days caused no false push. The false-push risk comes from template reloads. Pausing the 4 Anca automations before either one is still the safe habit.

## Start here

### 1. Purple LED when the flat needs attention

The AIR-1 LED pulses purple (`rgb [128,0,255]`, effect `Slow Pulse`) when something at home has been broken for 15 minutes. It answers your "change colour when something breaks" question, sends no push, and Anca's switch still decides whether the LED is lit.

- Create `binary_sensor.london_home_problem` as a UI Template helper (device_class problem). It is on when any of these is true: `binary_sensor.rpi_power_status` is on, `sensor.gl_inet_mt6000_primary_wan` is not `connected`, `switch.pikkachu` is unavailable, or the backup failed. The backup has failed if last_attempted is more than 1 h newer than last_successful, or last_successful is older than 192 h.
- In automation `1768255643471` (CO2 indicator), add a first choose branch: if the problem sensor has been on for 15 min, set purple with `Slow Pulse`.
- Add `effect: 'None'` to the red, orange and green branches so the pulse clears.
- Add a small automation: when the problem sensor holds a state for 15 min, call `automation.trigger` on the CO2 automation with `skip_condition: false`. The LED then repaints straight away and still respects the switch and the 09:45/10:00 to 22:00 window.
- Tell Anca and Gheorghe once that a purple pulse means "tell Viktor".

### 2. Copy HA backups off the SD card

The only full backups live on the same SD card that died in June. The card is 88% full with 3.1 GB free. Adding a network copy means a dead card costs a reflash and a restore, not a rebuild from memory.

- On Proxmox (192.168.1.127), create `/srv/nfs/ha-london-backup`. The safer route is a dedicated export restricted to 10.3.2.6 in `scripts/pve-nfs-exports`, which is a free git change applied by CI. Today `/srv/nfs` is exported rw, no_root_squash to `*`, and the London LAN can reach it.
- In ha-london, add a Supervisor NFS mount (usage: backup) and add it to the automatic backup locations with per-agent retention, for example 4 remote and 2 local.
- Delete the manual and pre-upgrade tars to free about 1.2 GB.
- Watch the first remote run, because the Pi had 11 MB RAM free and 720 MB of swap in use.
- nfs-mirror then copies the directory offsite to the Synology with no extra work.

### 3. Skip the Anca push when you travel together

Today you got "Anca left home" at 13:00 and "Anca is home" at 16:05 for trips you made together. Those 2 were the only joint trips in 7 days.

- In "Anca left home", add a template condition: skip if one of your GPS trackers (read from `person.viktorbarzin` device_trackers, filtered to source_type gps) went not_home within about 10 min of `trigger.to_state.last_changed`. No wait is needed, because the trigger already holds for 10 min. Your GPS tracker left 18 s before Anca did.
- In "Anca getting home safely", skip if your GPS tracker or person went home in the last 15 min. Otherwise wait up to 5 min (continue_on_timeout) and push only if you don't arrive.
- Edit through the automation editor, which reloads automations only.
- Trade-off: a skipped "left" can leave an unpaired "is home" later.

### 4. Per-plug cost in pounds

This turns each plug's kWh into GBP today and this month, using the 100Green rate.

- Create a UI helper `input_number.electricity_unit_rate` = 0.2805 GBP/kWh from about 5 Nov.
- Create UI template-sensor helpers per plug (device_class monetary, unit GBP). Michelle's ids differ: `sensor.emeter_plug_today_s_consumption` but `sensor.michelle_this_month_s_consumption`. Use the today and month sensors only, because `*_total_consumption` resets on the device.
- Add a "plugged loads total" sensor and put the sensors on the smart_plugs dashboard.
- Leave the Energy grid source and the DCC integration alone. The Energy dashboard has no per-device cost field.
- The plugs cover about a quarter of the flat's usage, and the rate needs a manual edit at the switch and at the VAT change on 1 Jul 2027.

### 5. Clean AIR-1 feeds

The verifier reported CO2 readings of 0.0 and PM2.5 readings of the 6553.4 error value, which every LED idea above would react to. A recheck of the last 10 days of state history (2026-10-31) found neither: CO2 stayed between 650 and 1317 ppm, and PM2.5 peaked at 1911.8, which is above the SEN55's specified 1000 ceiling. The glitch values may only be in older long-term statistics. The filter is still cheap insurance, but less urgent than this list order suggests. It costs nothing and needs no restart.

- Create a UI template helper for clean CO2 that drops values under 350: `{% set v = states('sensor.apollo_air_1_fa2d34_co2')|float(-1) %}{{ v if v >= 350 else none }}`.
- Create a clean PM2.5 helper that rejects values of 6553 or more and anything above 1000 (the SEN55's specified ceiling).
- Set unit, device_class and `state_class: measurement` so both keep long-term statistics.
- Point the CO2 automation's trigger at clean CO2. That is an automation reload only.
- In the `air-quality` dashboard, remove the 6 gas tiles from the `detailed` view (they have never recorded a value) and point the Home gauges at the clean sensors.

Runner-up: the local HA URL on your phone (see Safety). It takes about ten minutes and keeps HA usable during tunnel drops.

## Infra health

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| Purple LED | Pulses purple when Pi power, WAN, cooler plug or backup is broken for 15 min | S | £0 | with caveats |
| Blue LED for homelab | Polls gatus and pulses blue when 3+ endpoints or the tunnel fail, only while you're home | S | £0 | yes |
| ha-london watchdog | Blackbox probe on `/manifest.json`, new LondonHomeAssistantDown alert | S | £0 | with caveats |
| Echo speaks on events | Proactive events plus an Alexa routine. "Bedroom air" first, "Home check" later | M | £0 | with caveats |
| Yellow Echo ring | Second custom skill sends a MessageAlert, so the ring pulses yellow | L | £0 | with caveats |
| Health chips | Mushroom chips plus a Markdown dead-device list on Overview | S | £0 | with caveats |
| Weekly fix list | Sunday 10:00 push of things broken all week | S | £0 | with caveats |

- Purple LED: backups run weekly (Sunday 05:00), so a 50 h threshold would show purple about 5 days a week. Use 192 h or the failed-backup check. The WAN sensor only catches sustained outages.
- Blue LED: `rest` is not loaded, so it needs a full restart. Poll `?page=1&pageSize=1` (3.7 KB instead of 132 KB), and add triggers on `binary_sensor.homelab_down` and `person.viktorbarzin`. It could be folded into purple instead.
- Watchdog: IngressUpstreamDown already paged #alerts through the Sep to Oct outage. What's left is a check that doesn't depend on traffic. It needs inhibits against LondonTunnelDown and IngressUpstreamDown, plus your OK for a new alert. The cheaper option is removing the stale `external_monitor = false` so Uptime Kuma comes back.
- Echo speaks: needs plan decision 10 re-decided, Anca's developer console and Alexa app, and a first dev-stage ChangeReport, which is still unproven. In 3 days of data no stuffy-air episode started inside 18:00 to 22:00, so the time gate belongs in the template.
- Yellow ring: goes against #15525 and Alexa plan decisions 10 and 11. It lands on Anca's Echo devices, is untested on the Dot 3, and needs Anca to turn on notifications for the dev skill.
- Health chips: unknown whether the Portal keeps HA on screen. Internet and Homelab chips can't turn red, because the dashboard itself comes over the tunnel. `last_changed` resets on restart, so a 24 h filter can't be built. The 54 unavailable entities need grouping and an exclusion list.
- Weekly list: a new notification against #15525. #11525 says send a one-line all-clear when the list is empty. Use 7-day history_stats. A 14-day update age can't be built with 10 days of recorder history.

## Voice control

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| Goodnight / good morning | "Alexa, goodnight" turns the LED off and sets a night flag; morning clears it | S | £0 | with caveats |
| Room temperature | "Alexa, what's the temperature of the Air sensor?" | S | £0 | with caveats |
| How's the air | LED pulses for 20 s, numbers go to Anca's phone | S | £0 | with caveats |
| Water cooler | Template switch "Water cooler" that is on only while chilling (above about 20 W) | S | £0 | with caveats |
| Yiko by voice | Start, dock and pause the vacuum | S | £0 | with caveats |
| Movie mode | Stage 1: LED off for 3 h. Stage 2: projector and Stremio | M | £0 | with caveats |

- Goodnight: the plugs are already off and unused (Livia 0.0 kWh lifetime), and the LED is already dark from 22:00 to 09:45, so it mainly matters for an early goodnight. Gheorghe's own Echo probably can't run it.
- Temperature: HA docs say sensors need proactive events, while the source suggests an on-demand query might work. One test after discovery settles it.
- How's the air: Anca has to build the routine. The push to `notify.xiomi` needs your OK against #15525 and one test send. "Check the air" is the safer phrase.
- Water cooler: "turn on" only restores power. Live data showed 0 W for 7.5 h after the 01:42 power-on until someone pressed the button. Build it after the #16621 decision.
- Yiko: you have to finish the Ecovacs re-auth with the emailed code first. "Pause" and "resume" both call `vacuum.start_pause`, which toggles. "Minimum" maps to normal.
- Movie mode: HA controls one small LED, not the flat's lights. The Tapo P100 needs the Tapo Lab fix, and waking the projector over the network is unproven. Ports 5555 and 6466 are open from the HA host.

## Presence and daily life

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| House mode | `input_select.house_mode` Home/Away/Night from presence, plus voice scripts | M | £0 | with caveats |
| Gheorghe overnight hold | Keeps `binary_sensor.gheorghe_home` on through his 02:05 to 06:29 Wi-Fi drop | S | £0 | with caveats |
| Cooler follows house mode | Off at 02:00 and after 12 h empty, button cue, savings ledger | M | £0 | with caveats |
| Skip joint Anca push | Drops the push when you made the same move | S | £0 | yes |
| Weekday vacuum | Mon to Fri 10:30 when you and Anca are out, "Vacuum today" opt-out | M | £0 | with caveats |

- House mode: needs its own Night script, because `script.london_goodnight` doesn't exist. Away is rare (one 3.5 h episode in 10 days). Night must take precedence over Gheorghe's drop.
- Gheorghe hold: it only helps rules that read the binary sensor, not `person.gheorghe_milea` or `zone.home`. Nothing reads it today.
- Cooler: the flat was never empty for 12 h in 11 days, so savings are about 0, while 02:00 off costs about £8.90/yr. The button cue would fire most mornings, so it needs your OK. Use a below-1 W threshold. Portal delivery is unverified.
- Weekday vacuum: the Yiko re-auth comes first. Gheorghe was home for every sampled run, so ask him. His Echo probably can't use the skill.

## Energy and cost

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| Per-plug cost | GBP per plug today and this month | S | £0 | yes |
| Glowmarkt meter | Whole-flat kWh from the SMETS2 meter | M | £0 | with caveats |
| Monthly energy line | One line on the 1st with last month's kWh and GBP | S | £0 | with caveats |
| Overnight standby audit | 02:00 to 05:00 draw per plug, with GBP/yr | S | £0 | with caveats |
| Michelle cycle log | Duration, kWh and cost per Michelle run, logbook only | S | £0 | with caveats |

- Glowmarkt: the config entry already holds an account, but its resources belong to the old flat's meter (2023 to 2025 data). You need to add MPAN 27-0000-0946-551 using the IHD GUID. Expect new entity ids. The component (v1.0.3, last release Jan 2023) is untested on 2026.10.1.
- Monthly line: statistic sums are corrupt (October reads -47.7 kWh for the cooler). Use the month's max of the monthly counters instead. Real October figures: cooler 32.2 kWh (about £9.03), Thor 23.9 kWh (about £6.71). Slack is the default channel.
- Standby audit: only Thor draws overnight now (about 6 W, about £15/yr). The £120/yr figure was a past state. Use statistics UI helpers.
- Michelle log: the rule cuts the load at about 137 W, mid-taper, so it doesn't detect a finished cycle. Use the `total_consumption` delta. One run in 10 days (0.306 kWh, about 8.6p).

## Air and comfort

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| Morning LED verdict | LED shows last night's peak CO2, only when someone is home | S | £0 | with caveats |
| Bedtime purge nudge | Pulse from 21:00 to 22:00 when CO2 is high | S | £0 | with caveats |
| PM spike detector | White Fast Pulse plus a weekly spike count | M | £0 | with caveats |
| Seasonal air view | Monthly means and counts on the Air Quality dashboard | S | £0 | yes |
| Summer cooling advisor | Cyan pulse when opening the window will cool the room | M | £0 | with caveats |
| Clean AIR-1 feeds | Filtered CO2 and PM2.5, gas tiles removed | S | £0 | yes |
| Purifier on Livia | Plug-switched HEPA purifier | S | ~£75 | with caveats |

- Morning verdict: works on weekdays only, because the weekend morning turn-on and the CO2 window both start at 10:00. Use a statistics helper with `value_max`. `input_select.house_mode` doesn't exist yet.
- Bedtime nudge: CO2 was above 1000 at 21:00 on 3 of 5 sampled nights, so 1200 is probably the better threshold. Anca is always cold. Add `effect: 'None'` to the CO2 branches.
- PM spikes: 85 to 90% of excursions last under 2 minutes, so smooth with a 2-minute mean first. The 22:00 to 01:00 cluster falls outside the LED window. The source is unknown.
- Seasonal view: counts for past months need a SQL sensor on the statistics table (scan_interval 86400). The error rows distort max and min.
- Summer advisor: needs your OK for outdoor weather (met and metoffice are disabled on purpose, #6588) and a restart for `rest`. It would have pulsed on 52 of 90 summer evenings. The first real test is about May 2027.
- Purifier: needs purchase approval. Most spikes are over within 2 minutes, so a purifier that starts after 3 may not help. Run a free sustained-spike counter for 2 to 4 weeks first. The Livia plug is in the living room and in `scene.night`.

## Safety and resilience

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| Scrape ha-london | Prometheus haos_* metrics for London, alerts and 26-week history | M | £0 | with caveats |
| Backups off SD | NFS backup location on Proxmox | S | £0 | with caveats |
| Power-cut reminder | Detects router and HA booting together, reminds people to press the cooler button | S | £0 | with caveats |
| Local HA URL | Phone uses `http://192.168.8.103:8123` on home Wi-Fi | S | £0 | with caveats |
| Empty-flat air watch | Push if CO2 rises or PM spikes while nobody is home | S | £0 | with caveats |
| Michelle safety caps | 4 h run cap and 250 W over-draw cut | S | £0 | with caveats |
| Restart-safe presence | Stops template reloads from faking Anca edges | S | £0 | with caveats |

- Scrape: needs its own scrape_config with a second token, because the job has one bearer file. Add `equal: [instance]` to the HomeAssistantDown inhibit, or London outages would hide Sofia alerts. It needs a 15m `for` or a tunnel guard, and must exclude person, device_tracker, zone and presence entities, since other devvm users can query Prometheus. It also needs your OK for London alerts.
- Backups: creating the Proxmox directory needs root. The dedicated export restricted to 10.3.2.6 is safer than the shared `/srv/nfs`. Any stale-backup push needs your OK.
- Power cut: the daily 00:30/07:00 cycle already needs a morning press, so only daytime cuts matter. Gate on the cooler drawing under 10 W and target whoever is home. No cut is on record to test against.
- Local URL: the setting that matters is in the Companion app on your phone, not core `internal_url`. Use the IP, not `.lan`, which resolves over the tunnel. Check that .103 has a DHCP reservation. Anca and the Portal on guest Wi-Fi need a Flint rule (fresh ask), or the Portal can join the main SSID.
- Empty-flat watch: Gheorghe's nightly drop makes the flat look empty while he's asleep, so skip 01:30 to 07:00. One 30+ minute empty window in 10 days. It's a new push.
- Michelle caps: the existing below-140 W rule never cuts a load that starts under 140 W, which makes this idea stronger. Enable `sensor.michelle_on_since` for a cap that survives restarts. Confirm what Michelle powers first. 250 W only guards against the wrong appliance being plugged in.
- Restart-safe: change the hold branch to return `none` after a reload, and test that on a scratch template first. The restart pause step in the runbook can then go.

## Wildcard

| Idea | What it does | Effort | Cost | Verdict |
|---|---|---|---|---|
| F1 lights out | Five red steps then dark, 5 min before the race | S | £0 | with caveats |
| Fresh-air thank-you | Green Fast Pulse when CO2 drops from orange to green | S | £0 | with caveats |
| Sunday air card | Weekly CO2 summary on a dashboard card | S | £0 | with caveats |
| Cowboy milestones | Gold pulse every 250 km or 100 kg CO2 saved | S | £0 | with caveats |
| Commute rain check | 07:20 rain warning before a bike commute | S | £0 | with caveats |

- F1: needs a full restart for `rest`. Drop the scene snapshot and run the roughly 10 s sequence right after a CO2 update. Jolpica has no SLA but fails safe. Next race is the Mexico City GP, 2026-11-01 20:00Z.
- Fresh-air: as specified it would have fired 0 times in about 9 days. With a 1000 ppm peak, 1 to 4 times. Needs Anca's consent.
- Sunday card: the Portal's HA app hasn't connected in 29 days, so the dashboard card is the output that works. `recorder.get_statistics` covers it with no new sensors.
- Cowboy: 4,250 km is about 58 days away. The message must compute its numbers (501.8 kg is about 990 trips, not 1,500). Use a persistent notification, and add `effect: 'None'`.
- Rain check: `notify.portal` is very likely a dead registration from before the July factory reset, and needs an on-site Companion login. Also blocked on the #6588 weather question, and it's a new push.

## Answers to Viktor's question

You asked about making "Alexa's colour" change when something breaks. Short answer: the Echo ring can't do it in any useful way. The air sensor LED can, today, for free. Spoken announcements are possible later if you reopen one decision.

### The Echo ring

No third party can set the Echo Dot 3's ring colour. Amazon's light-ring states are system-only.

- The only ring state a skill can cause is the yellow pulse, meaning "a notification is waiting". Getting it takes a second custom skill on Anca's developer account, a tiny sibling Lambda, and a Unicast `AMAZON.MessageAlert.Activated` through the Proactive Events API. Effort L.
- What you'd get: always yellow, and a fixed sentence ("You have 1 new message from <name>", where the name is free text). It lands on Anca's Echo devices, because you own no Echo. Nobody has tested whether it lights the Dot 3 ring.
- It goes against #15525 ("no new notifications") and Alexa plan decisions 10 and 11. I'd skip it.

### The air sensor LED

This is the recommended route. Start with the purple "needs attention" pulse from Start here.

- It respects Anca's switch. The purple branch lives inside the CO2 automation, the repaint uses `skip_condition: false`, and the existing on/off-switch automation still turns the LED off when `input_boolean.air_sensor_light` goes off.
- Two things to get right: add `effect: 'None'` to every CO2 branch, and use the weekly backup threshold (192 h or a failed-backup check).
- Optional homelab signal: either a separate blue pulse from gatus, only while you're home, or fold `homelab_down` into purple to keep the number of LED meanings small. Every LED override has to be a branch of the one CO2 automation, because it runs in mode restart.

### Spoken announcements

The official, free path is proactive events plus an Alexa routine on a virtual contact sensor.

- Setup: turn on "Send Alexa Events" on the London Home skill, add endpoint `https://api.eu.amazonalexa.com/v3/events` plus the Skill Messaging client_id and secret, restart, have Anca unlink and relink and run discovery, then build an "Alexa says" routine.
- Anca controls the wording and quiet hours. The Echo needs internet, so it can't announce a London internet outage.
- "Home check" needs `binary_sensor.london_home_problem` from the purple idea first. "Bedroom air" can be built on its own.
- Blockers: plan decision 10 ("no proactive state reporting"), Anca's time in her console and app, and an unproven first dev-stage ChangeReport.
- The unofficial routes (core Alexa Devices, HACS Alexa Media Player) can speak any text, but they log in with Anca's Amazon credentials.

### Recommended route

1. Build the purple LED now.
2. Decide whether homelab-down joins purple or gets its own blue.
3. If you want speech, reopen decision 10 and start with "Bedroom air". Add "Home check" once purple exists.
4. Leave the Echo ring alone.

## Needs money or a decision

| Item | Price or decision | Trade-off |
|---|---|---|
| Purifier on the Livia plug | About £50 to £100, price unverified | Run the free spike counter first. It must resume when power returns (mechanical switch) |
| Home Assistant Cloud | £6.50/month or £65/year | Not needed for anything here. The self-hosted Lambda covers it. It would only keep Alexa working during tunnel outages |
| Alexa Devices (core) | Free, Anca's Amazon email, password and OTP | Speaks any text on the Echo. Credential login, not a public API. Account-lock risk unverified |
| Alexa Media Player (HACS) | Free, "unofficial Alexa API" | Same as above, and Amazon can cut it off at any time |
| Notify Me skill | Free, third-party server | Chime and yellow ring only. UK status unconfirmed. Not recommended |

Decisions only you can make:

- New pushes under #15525: weekly fix list, yellow ring, how's-the-air, cooler button cue, power-cut reminder, empty-flat watch, Michelle cap push, monthly energy line (Slack by default), Sunday card, rain check, stale-backup push.
- New London alerts: the watchdog and the Prometheus scrape.
- Plan decision 10 (proactive events): Echo speaks, plus the temperature fallback.
- Outdoor weather despite met and metoffice being disabled (#6588): summer advisor and rain check.
- A Flint rule from guest Wi-Fi to HA, for Anca's phone and the Portal.
- Your own steps: the Glowmarkt MPAN and the Ecovacs re-auth.
- Consent: Anca for LED behaviour changes and routines, Gheorghe for the weekday vacuum.

## Ruled out

No idea failed verification outright. These parts of ideas did, and the plans above leave them out:

- Setting the Echo ring to a chosen colour: no API exists.
- A gatus endpoint for the ha-london watchdog: gatus `services` endpoints are display-only, and ADR-0020 keeps gatus to public hostnames.
- Editing the existing `ha-london-alexa` Lambda: `deploy.sh` refetches the gist on every run.
- A 50 h backup threshold: backups are weekly.
- Internet and Homelab chips on the Portal dashboard: the dashboard itself comes over the tunnel.
- "Unavailable for 24 h" from `last_changed`: it resets on every restart.
- A 14-day update age: the recorder keeps 10 days.
- Monthly kWh from statistic sums: those sums are corrupt.
- Exposing the raw water-cooler plug to Alexa: on doesn't mean chilling.
- A `sensor.uptime` condition for restart safety: it doesn't change on a template reload.
- Per-device cost in the Energy dashboard: there is no field for it.
- A generic "cycle finished" blueprint built from Michelle's data: that load never goes idle before the cut.
- Scene-snapshot restores in F1 and How's the air: they can repaint a stale colour.

## Open questions

1. Build the purple LED now? Should homelab-down fold into purple, or get its own blue?
2. Which of the new pushes, if any, are fine under #15525? Is Slack fine for the monthly energy line?
3. Reopen plan decision 10 so the Echo can speak on events?
4. Drop the yellow-ring idea? That's my recommendation.
5. Create the Proxmox backup directory with a dedicated export restricted to 10.3.2.6?
6. Is outdoor weather data from Open-Meteo OK, given met and metoffice were disabled on purpose?
7. What do Thor, Livia, Jinx and Michelle power?
8. Does the Portal keep HA on screen, and can someone in London re-pair its Companion app?
9. Ready to add MPAN 27-0000-0946-551 to Bright for the whole-flat meter?
10. Settle the water-cooler plan (#16621) first, then house mode?