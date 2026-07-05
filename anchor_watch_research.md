# Anchor Watch / Anchor Alarm — Competitive Feature Research

Research to inform building "the best anchor app on the planet" inside the Matau Nav sailing app. Grounded in app-store listings, first-party docs, and cruiser-forum sentiment. Sources are cited inline and listed at the end.

Apps covered: Anchor Pro (IdeaBoys), "Anchor!" / Anchor Alarm–Anchor Watch (Florian Kriesche), Drag Queen, HoldFast, ankeralarm.app (w+h GmbH), Anchor Alert (PredictWind), SafeAnchor.Net / AnchorQueen "Jules", SeaNav + Boat Beacon (Pocket Mariner), Savvy Navvy, Aqua Map, Navionics Boating, iNavX, Garmin / Vesper Cortex Anchor Watch, Raymarine LightHouse, B&G Zeus, and the SignalK `anchoralarm` plugin.

> Note on a few list items: **Navionics Boating has NO built-in anchor alarm** (you run a 3rd-party app alongside it). **"Aweigh"** does not exist as a current standalone nav app — likely a confusion with "Anchor's Aweigh" ($0.99, basic) or with Pocket Mariner's **SeaNav/Boat Beacon** anchor watch. **SailProof** makes rugged tablets, not an app — anchor watch there comes from whatever app you run (they recommend Aqua Map / iNavX / OpenCPN).

---

## 1. Feature Inventory

Exhaustive list of every distinct anchor-watch feature found across all apps, grouped by category. App attributions in (parentheses).

### A. Setting the anchor

- **Drop at current GPS the moment you let go** (Anchor Pro, HoldFast, Aqua Map, iNavX, Anchor Alert, SignalK `dropAnchor`, Savvy Navvy, Raymarine, Vesper Cortex, B&G).
- **Bow-offset / GPS-antenna-offset compensation** — anchor placed ahead of the GPS antenna, not at it. (Anchor Alert: explicit bow-roller-to-GPS + boat-center-to-GPS + bow-roller-to-depth-sensor offsets; SignalK: bow offset + bow height; Aqua Map: "enter distance to anchor" after capturing GPS.)
- **Set rode / chain length deployed**, used to compute the swing radius (Anchor Alert: rode + default 4.0 scope ratio; SignalK `setRodeLength`; iNavX "Scope" button recommends rode; Raymarine LightHouse 4.9: edit length-of-chain; Aqua Map scope coaching).
- **Snub / scope-ratio guidance** (Aqua Map coaching: chain vs bow-height + depth, reverse-set test at 800–1200 RPM; Anchor Alert scope alarm; iNavX recommended scope; Vesper shows live scope ratio e.g. 1.5:1; B&G estimated chain length).
- **Manual placement on the map / drag the anchor icon to where it actually dropped** (Anchor!/Kriesche, HoldFast, Savvy Navvy, ankeralarm, SafeAnchor, Aqua Map, SignalK `setAnchorPosition`).
- **Set later by distance + bearing** from the boat (Anchor Pro; SignalK `setManualAnchor` via heading + depth + rode; the method cruisers most praise in AnchorWatch).
- **Enter exact coordinates** (Anchor Pro, Aqua Map, Anchor Alert, SignalK).
- **Compass-bearing placement** — aim the phone to set distance + direction (HoldFast Lifetime).
- **Re-center / move anchor + radius after setting** at any time (ankeralarm, SafeAnchor, Savvy Navvy, Anchor Alert mid-session, Aqua Map re-tap capture).
- **Simple vs Advanced setup modes** (Anchor Alert).
- **Rode-counter automation** — auto-set the anchor when the chain counter shows rode has hit the seabed, by depth threshold (water depth + bow height) or rode-length threshold, with a stabilization delay (SignalK — unique).
- **Ship dimensions drawn to scale** on the map (Anchor!/Kriesche).
- **Visual chain-length representation** on the map (ankeralarm).

### B. The swing / drag model

- **Simple radius circle** around a point (Drag Queen, iNavX, HoldFast free, ankeralarm classic, Garmin chartplotter, base apps generally).
- **Adjustable radius to the meter, 5–200 m** (HoldFast, ankeralarm).
- **Swing-circle computed from rode + depth (+ bow height + GPS offset + fudge factor)** rather than a guessed radius (SignalK, Anchor Alert, Raymarine auto-calculates swing + drag circles, Vesper).
- **Two concentric zones: inner Swing Zone + outer Safety/Drag Zone** — warning before the hard alarm (Savvy Navvy; Raymarine swing-circle + drag-circle; Aqua Map alarm-radius + warning-area).
- **Asymmetric / two-radii zone** — different radius at different angles (Anchor Pro: two radii at specific angles).
- **Directional exclusion sector** — carve out and rotate a no-go arc (e.g. away from rocks/shore); choose full circle or sector (Savvy Navvy; ankeralarm angle/polygon mode for shoreline mooring 180°–360°).
- **Freehand / finger-drawn custom boundary** around reefs, shoals, sandbars (HoldFast Lifetime, Anchor!/Kriesche custom swing shapes, trimaran-san "ideal" spec).
- **GPS-antenna-offset asymmetry handled by custom shapes** (Anchor!/Kriesche: free space can differ in each direction).
- **Apparent-bearing model that accounts for heading** (SignalK `navigation.anchor.apparentBearing`; Vesper uses heading/compass, not just position).
- **Historical track / breadcrumb fan** drawn during the swing to judge holding vs dragging (Anchor Pro, Anchor!/Kriesche, HoldFast, ankeralarm, Aqua Map dedicated anchorage track, SignalK 24h @ 1-min, SafeAnchor history, Savvy Navvy live trackline).
- **"Actual swing" learned circle** — observe the arc first, then size the radius ~10 m outside it (cruiser technique; Raymarine/SignalK track supports it; no app fully automates this — opportunity).
- **Offline radar plot of your own swing + nearby boats** (SafeAnchor/AnchorQueen).
- **Predictive drift detection — distinguish real drag from a normal swing** (SafeAnchor/AnchorQueen "Jules"; Vesper "detects when the anchor starts to plough").
- **Polling cadence** affects battery vs responsiveness (SignalK 1 s when active; ankeralarm adjustable interval; once-per-minute apps praised for ~15% overnight battery).

### C. Alarms

- **Drag / radius-breach alarm** — audible + visual when boat exits the zone (all apps).
- **Excessive-swing alarm** separate from drag (Anchor Alert).
- **Drift-speed alarm** — fires if drifting faster than ~1 kt (SeaNav).
- **Wind-speed alarm** (Anchor Alert, Vesper Cortex).
- **Wind-gust alarm** (Anchor Alert).
- **Wind-shift / wind-direction alarm** (Anchor Alert — noted not yet functional in v2.0.2; Vesper Cortex wind direction).
- **Depth change / shoaling alarm — Min and Max depth** (Anchor Alert depth Min/Max for tidal anchoring; Vesper depth change + drift-into-shallow; B&G traffic-light safe-depth / low-water warning).
- **Scope / rode-ratio alarm** (Anchor Alert).
- **Heading-based alarm** — fires if the boat turns more than N degrees (Anchor!/Kriesche — good for bow+stern anchoring).
- **AIS proximity / collision alarm** — warning + collision zones around nearby AIS targets, with speed filter (Anchor Alert via DataHub; Vesper smartAIS; SafeAnchor COLREGS warnings).
- **GPS-signal-loss alarm** — losing the fix FIRES the alarm rather than going silent (HoldFast philosophy; Anchor Pro GPS-strength threshold; Aqua Map fires after 5+ min weak; SignalK no-position alarm; Drag Queen GPS-accuracy alarm; iNavX shows HPE).
- **Low-battery alarm** (Anchor Pro, Aqua Map, SignalK; Anchor Alarm 219 SMS).
- **Low-sound-level / volume alarm** (trimaran-san "ideal" spec; partially Anchor Pro thresholds).
- **Incomplete-anchoring alarm** — anchoring not completed in time (SignalK).
- **Alarm delay / grace period / time-out-of-bounds** before sounding, to suppress momentary GPS excursions (Drag Queen, Aqua Map, Anchor Alert tolerance, SignalK debounce, ankeralarm).
- **False-fix filtering** — ignore single bad GPS points (Anchor!/Kriesche, SafeAnchor predictive).
- **Loud alarm that overrides low volume / Silent mode / Do Not Disturb** — via iOS Critical Alerts (Anchor!/Kriesche, HoldFast full volume, AnchorQueen, Anchor Alert critical alerts bypass DND). **Note:** ordinary apps generally CANNOT beat iOS Silent/DND (ankeralarm FAQ admits this) — only Critical Alert entitlement or hardware speakers truly solve it.
- **Snooze / mute** — 5-min mute (Savvy Navvy), 60-sec silence (Vesper), snooze while ashore (Anchor Alert).
- **Escalation / repeat** — re-alarm every 5 min, re-arm after raise+drop (Boat Beacon).
- **Secondary / external loud output** — route to Bluetooth speaker or boat aux jack (Drag Queen); Pi speaker, NMEA-2000 buzzer/YDAB-01, chartplotter beeper (SignalK); 85 dB handset speaker + connected speaker (Vesper).
- **Works backgrounded / screen off / phone locked** — true background GPS (HoldFast, ankeralarm, SafeAnchor OS-geofence, Anchor!/Kriesche push, Aqua Map). **Foreground-only / fragile in background**: iNavX, Savvy Navvy (must stay running), Android often needs screen on.
- **Test / simulate alarm** button (iNavX; cruiser self-test = arm it and motor out).

### D. Situational awareness

- **Other anchored boats plotted** (SafeAnchor offline radar; AIS apps below).
- **AIS overlay / targets** (Anchor Alert via DataHub, Vesper Cortex smartAIS, SafeAnchor AIS+COLREGS, SeaNav AIS radar on watch; Savvy Navvy/iNavX have AIS but not wired into the anchor screen).
- **Live depth / depth under keel** from instruments (Anchor Alert N2K, Vesper, B&G, Aqua Map AnchorLink Wi-Fi sensor depth, SignalK).
- **Tide / current state** (SafeAnchor 180k tide stations; B&G tide-aware low-water warning).
- **Bearing + distance to anchor on the map** (Anchor Pro, ankeralarm, SafeAnchor, Anchor Alert, iNavX AAD drift distance, SignalK bearing paths).
- **Distance to shore / hazards** (implicit via freehand/exclusion zones; no app does true automatic shore-distance alarm — opportunity).
- **Live wind speed + direction readout** (Anchor Alert, Vesper, Aqua Map AnchorLink).
- **Anchorage depth contours / chart context** (chartplotters; nav apps generally).

### E. Forecast / planning

- **Marine wind forecast for the night** (Anchor Alert via PredictWind — highly accurate; SafeAnchor wind/gusts/waves 7-day meteogram; Savvy Navvy app has forecasts but not on the anchor screen).
- **Gust forecast / warnings** (Anchor Alert, SafeAnchor).
- **Wind direction over time** (SafeAnchor meteogram).
- **"Is this anchorage safe tonight"** — implied by forecast + swing model, but **no app delivers a clear go/no-go verdict for the night ahead** (clear gap / opportunity).
- **Anchorage database & community reviews** (ankeralarm ~685k–751k anchorages; Anchor Alert user ratings; Navionics/Aqua Map community POIs).

### F. Remote / multi-device

- **Push notifications onboard + ashore** (Anchor Alert over cellular/Starlink/Iridium satellite; Vesper to phone + smartwatch; HoldFast lock-screen push).
- **Apple Watch / smartwatch companion** (Anchor Pro shows distance/bearing/battery; Vesper/Garmin Quatix drift alerts + vibrate; SeaNav free watch app; Anchor Alert watch alerts).
- **Remote monitoring of the onboard device from a second device** — sender→receiver pairing (ankeralarm, SafeAnchor "Anchor Remote", Aqua Map AnchorLink mirroring, Anchor!/Kriesche "remote screen", Garmin ActiveCaptain viewing the chartplotter).
- **Browser-based remote watch via short code, no app install** — share a 6-char code so crew ashore watch live in any browser (HoldFast — standout).
- **Telegram / email / SMS / URI alerts** (Anchor Pro Telegram + email + on-demand status; Aqua Map Telegram/email/URI; Anchor!/Kriesche email; Anchor Alarm 219 SMS; SignalK Pushover/ClickSend SMS/Node-RED).
- **Live remote map view of the boat track ashore** — desired but mostly missing ("The Anchor!" can't show track remotely; Vesper Monitor can — opportunity).
- **Runs always-on on a dedicated device** the OS can't kill — Raspberry Pi / SignalK server (does the watching itself, persists across restarts), old phone, PC + OpenCPN, chartplotter, Vesper/Nautic Alert hardware.

### G. Night usability

- **Red night mode** — weakly evidenced across the field; mentioned for "Safety Anchor Alarm" and implied in some reviews. **Largely a gap** in dedicated anchor apps (opportunity).
- **Big, glanceable readouts** (distance/bearing/battery on Anchor Pro watch; Vesper attitude graphic; cruisers want a 3-second glance from the bunk).
- **Screen-on / keep-awake** mode (Aqua Map, Android apps that require it; battery-saving mode in HoldFast as the counterweight).

### H. History & logging

- **Position track recording** at adjustable interval (ankeralarm, SignalK 24h @ 1-min, Aqua Map dedicated anchorage track, SafeAnchor).
- **Anchor log / catalog** — store and pin every anchorage to revisit (SafeAnchor/AnchorQueen — standout; Aqua Map waypoints).
- **Playback / "relive every anchorage"** (SafeAnchor; SignalK getTrack).
- **Free vs unlimited history** — e.g. ankeralarm free ~1 h, premium unlimited.
- **Export** — track export (Aqua Map, OpenCPN/SignalK via GPX); not common in pure anchor apps (minor gap).

### I. Nice-to-haves & standout / differentiating features

- **AI co-captain "Jules"** — reads live position/wind/tide/depth and answers in plain language, 13 languages (SafeAnchor/AnchorQueen — unique).
- **No-app browser remote watch via 6-char code** (HoldFast — unique).
- **Rode-counter auto-set when chain hits the seabed** (SignalK — unique).
- **On-demand status query** — text the app and it replies with live status (Anchor Pro via Telegram).
- **Pre-anchor live coaching** — speed, drift direction, scope, reverse-set test before arming (Aqua Map; Raymarine Anchor Drag Wizard).
- **Heading/turn-degrees alarm for bow+stern anchoring** (Anchor!/Kriesche).
- **Integrated offline video manual** (Anchor!/Kriesche).
- **Multi-channel pluggable notifications** — audio on Pi, onto N2K bus, push, Pushover, SMS (SignalK).
- **Smart drag detection (plough detection) using heading + position, not just radius** (Vesper, SafeAnchor).
- **Power-Pole / trolling-motor auto-reanchor on drag** (Garmin + Power-Pole — hardware).

---

## 2. What Cruisers Actually Complain About / Wish For

Synthesized from Cruisers Forum, YBW, Sailboat Owners, Sailing Anarchy, Trawler Forum, and cruiser review blogs (sources at end).

**Top pain points (ranked by how often they come up):**

1. **False alarms wake you at 3 a.m.** — the #1 complaint by far. Radius set too tight + normal wind/tide swing trips it; momentary GPS wander reads as drag. SailGrib AA "woke me up several times with false alarms." The single highest praise any app earned was the *absence* of this ("AnchorWatch — zero middle-of-the-night false alarms").
2. **Phone battery dies overnight** — "It killed the phone battery and then I had no anchor alarm or phone." GPS polling is the drain; everyone tethers to 12 V/USB. Low polling rate matters (1-per-min app used ~15% overnight).
3. **Alarm too quiet / silenced by Silent mode or DND** — structurally, consumer apps cannot override iOS Silent/DND without Critical Alert entitlement. You can sleep right through it. Drives people to hardware with a real speaker.
4. **GPS wander causes false drag** — position can jump 20+ m without DGPS (~3 m with EGNOS), far worse inside a metal hull / below deck. "Can wander by as much as the length of rode I have down."
5. **The OS kills the app in the background** — phones sleep background processes, so the watch silently dies. ankeralarm itself warns its remote mode may be closed by the OS over multiple days.
6. **Having to keep the screen on** (esp. Android) to stop GPS sleeping — treated as a defect.
7. **Wrong center point** — apps that circle your *current* position instead of where the anchor actually dropped produce a badly offset zone and false alarms.
8. **No remote view of the track ashore** — apps alert remotely but can't show you the boat's live track from the bar/restaurant.

**Most-requested / most-loved features:**

- **A genuinely loud alarm that wakes you** — and since no app beats iOS DND, hardware with its own 85 dB speaker (Vesper Cortex) wins; "It literally saved my life."
- **A dedicated always-on device** the OS can't kill (Pi/SignalK + speaker + N2K forwarding, old phone, chartplotter).
- **Swing circle that accounts for GPS-at-antenna vs anchor-at-bow offset** — "my antenna is 12 m aft of where the anchor hit bottom." Want radius = rode + boat-length/offset.
- **"Set the radius where you DROPPED, not where you sit"** — via bearing/distance entry or recenter on the observed swing arc. Greatly reduces false alarms.
- **Remote monitoring while ashore** with push/SMS/cloud AND a live track.
- **Integration with real wind/depth/NMEA instruments + external GPS** ("iPad internal GPS is not reliable" → add a Garmin GLO).
- **Position-history track** to tell a wind-shift swing (arcing) from real drag (progressive translation).
- **Alarm delay** to ignore momentary excursions without disabling the alarm.

**Specific techniques cruisers describe:**

- Radius = rode/chain deployed + 5–10 m buffer; or rode + bow offset; typical anchorages 40–60 m.
- **Observe the swing for an hour first**, capture the arc, set the radius ~10 m outside it for tide/stretch.
- **Two devices** — one aboard as the alarm, one ashore as the monitor (iPad aboard + iPhone ashore).
- **Self-test**: arm the alarm and motor out of the zone — if it doesn't fire, "something is very fishy."
- Place the alarm center at the bow / on the actual anchor.

**Apps cruisers recommend vs dislike:**

- **Loved:** AnchorWatch (reliability, zero false alarms, bearing/distance set), ankeralarm (loud, honest about limits), Aqua Map (AnchorLink remote + external GPS), "The Anchor!" (remote + email), Anchor Alarm 219 (SMS, Android), Drag Queen (deliberately annoying wake-you alarm, now effectively discontinued), OpenCPN/SignalK-on-Pi (reliability crowd).
- **Disliked:** SailGrib AA (battery drain, false alarms), standalone chartplotter alarm (can't hear the beep from the cabin), **PredictWind Anchor Alert ("overkill for basic monitoring")** — relevant given Matau's existing PredictWind integration. General distrust of phone apps inside metal hulls.
- **Hardware gold standard:** Vesper Cortex (VHF + Class B AIS + anchor watch + remote + 85 dB speaker); Nautic Alert Insight (dedicated geofence hardware).

---

## 3. Top 12 Features That Define a Truly Great Anchor Mode

Ranked, each with a one-line rationale.

1. **Loud alarm that overrides Silent/DND (iOS Critical Alerts) + optional external/boat-speaker output.** — The #1 failure mode is sleeping through it; nothing else matters if it can't wake you.
2. **Set the anchor where it actually dropped — bearing/distance, manual map placement, or rode-projection — with GPS-antenna→bow offset.** — Wrong center is the root cause of most false alarms; this is the single biggest reliability lever.
3. **Rock-solid background operation with the screen off / phone locked, and GPS-loss FIRES the alarm.** — A watch that the OS silently kills, or that goes quiet when it loses signal, is worse than none.
4. **Swing-circle computed from rode + depth (+ bow height + fudge), not a guessed radius, with an inner warning ring before the hard alarm.** — Right-sized zones plus an early warning kill false alarms while still catching real drag.
5. **Alarm delay / debounce + bad-fix filtering to reject momentary GPS wander.** — Directly attacks the 3 a.m. false alarm without making the alarm less sensitive to real drag.
6. **Breadcrumb track + drag-vs-swing discrimination (heading-aware, plough detection).** — Lets the boat (and the skipper) tell a normal wind-shift arc from a dragging translation.
7. **Remote monitoring ashore — push + live track view — on a second device or no-app browser link.** — Cruisers want to watch the boat from the bar; alerting without a track view is half a solution.
8. **Runs on an always-on boat device (Pi/SignalK or instrument hub) that the phone can't kill, persisting across restarts.** — Decouples the watch from a sleepy, battery-limited phone.
9. **Integration with real wind + depth + AIS instruments**, with **wind-speed/shift, depth Min/Max shoaling, and AIS proximity alarms.** — The premium tier cruisers actually trust; catches threats a position-only circle never sees.
10. **Directional / freehand swing zones (exclusion sector, finger-drawn boundary) for shore-, reef-, and tide-aware anchorages.** — Real anchorages aren't circles; lets you guard the shoreline side without nuisance alarms elsewhere.
11. **Wind forecast for the night + a clear "safe tonight?" verdict, with anchorage notes.** — Moves from reactive alarm to proactive planning; Matau's PredictWind tie-in is a natural edge here.
12. **Night-usable, glanceable UI (red mode, big distance/bearing/depth readouts) + Apple Watch + low-battery alarm.** — At 3 a.m. from the bunk you need a 3-second glance and a watch tap, not a chart to decipher.

---

## 4. Clever / Novel Things Most Apps DON'T Do (Killer Differentiators)

- **A real "is this anchorage safe tonight?" verdict.** No app combines tonight's wind forecast + tide + your swing geometry + distance-to-shore into a clear go/no-go with reasons. With Matau's existing PredictWind integration this is a uniquely ownable feature — and it directly counters the "Anchor Alert is overkill" complaint by being *simpler* to read, not more.
- **Auto-learned swing circle.** Cruisers manually watch the arc for an hour and size the radius outside it. No app automates this: silently learn the observed swing envelope over the first 30–60 min and *propose* a tightened, recentered zone ("I've watched you swing — set the alarm to this?"). Turns the #1 expert technique into one tap.
- **Distance-to-shore / lee-shore alarm.** Everyone alarms on a circle; almost no one alarms on "you're now X m from charted land" or "the wind shift just put the shore to leeward." Using chart data already in a nav app, this catches the actual danger (grounding), not just circle-breach.
- **Browser remote watch with no app install (HoldFast does it; almost nobody else).** A 6-char share code so any crew/friend ashore opens a live track in a browser — dead simple, no onboarding.
- **Drag-vs-swing intelligence with a calm "just a wind shift" status** instead of alarming. Heading-aware plough detection (Vesper-style) brought into software, so the app can say "you swung 80°, anchor still holding" rather than crying wolf — the credibility that earns "zero false alarms."
- **On-demand status by message** (Anchor Pro's Telegram query) — text/notify the boat and get live position, swing, depth, battery, wind back. Few apps do pull-based status; great for spotty connectivity.
- **Phone-as-backup to an always-on watcher, with automatic handoff.** Primary watch runs on the boat hub (Pi/instruments/PredictWind DataHub); phone is a redundant watcher and remote display, and the system tells you which is active and healthy — solving the battery/OS-kill problem by design rather than by warning the user.
- **Rode-counter auto-set** (SignalK-style) for boats with a chain counter — set the anchor automatically the instant the chain hits the seabed.
- **Anchor catalog / "relive every anchorage"** (SafeAnchor) — store each anchorage with its swing, holding notes, and conditions, so you build a personal pilot book and can pre-load a proven zone on return.

---

## Sources

Dedicated anchor apps:
- https://apps.apple.com/us/app/anchor-pro/id1445476850
- https://apps.apple.com/us/app/anchor-alarm-anchor-watch/id1047308803
- https://www.anchoralarm.app/ (HoldFast)
- https://ankeralarm.app/en/ · https://ankeralarm.app/en/faq · https://apps.apple.com/app/ankeralarm/id1428485893
- https://apps.apple.com/us/app/anchor-alert/id1628786449 · https://help.predictwind.com/en/articles/7208392-anchor-alert-app-overview · https://www.predictwind.com/anchoralert
- https://apps.apple.com/us/app/safeanchor-net-anchor-alarm/id1225033114 · https://www.safeanchor.net/
- https://appadvice.com/app/dragqueen-anchor-alarm/489294173 · https://i-marineapps.blogspot.com/2012/01/drag-queen-ancor-alarm.html
- https://trimaran-san.de/en/anchor-alarm-apps-overview/ · https://trimaran-san.de/en/anchor-apps/
- https://www.safetyanchoralarm.com/blog/best-anchor-alarm-apps
- https://apps.apple.com/us/app/seanav/id857841271 · https://pocketmariner.com/mobile-apps/seanavapp/tips-on-using-seanav-with-the-apple-watch/ · https://apps.apple.com/bm/app/boat-beacon/id494877039

Nav apps / chartplotters:
- https://help.savvy-navvy.com/en/article/how-to-use-savvy-navvys-anchor-alarm-1he5yow/ · https://www.savvy-navvy.com/user-guide/anchor-alarm-2
- https://www.aquamap.app/support/16-advanced-functions/28-anchor-alarm · https://www.aquamap.app/blog/5-did-you-know/57-the-anchoring-process-before-setting-the-anchor-alarm · https://www.aquamap.app/support/17-master-functions/160-anchor-link%E2%84%A2
- https://inavx.com/anchor-alarm · https://inavx.com/h/inavx/anchor.htm
- https://www8.garmin.com/manuals/webhelp/gpsmap8400-8600/EN-US/GUID-B733438A-D5A8-45E7-9EC2-EFCAF8251C64.html · https://static.garmin.com/pumac/Vesper_Marine_Cortex_AnchorWatch.pdf · https://support.vespermarine.com/hc/en-us/articles/360004227655-Using-Cortex-Anchor-Watch
- https://www.raymarine.com/en-us/learning/online-guides/lighthouse-4-9 · https://www.bandg.com/zeus-sr/
- (Navionics has no anchor alarm) https://www.cruisersforum.com/forums/f118/best-anchor-watch-alert-alarms-apps-209690.html
- (SailProof) https://sailproof.shop/navigate-smarter-best-route-planning-apps-for-your-tablet/

SignalK:
- https://github.com/sbender9/signalk-anchoralarm-plugin · https://www.npmjs.com/package/signalk-anchoralarm-plugin · https://demo.signalk.org/documentation/Guides/Anchor_Alarm.html · https://signalk.org/2025/signalk-local-remote-alerts/

Cruiser sentiment:
- https://www.foghornlullaby.com/2021/02/review-anchor-alarm-software/
- https://forums.sailboatowners.com/threads/what-is-your-favorite-anchor-alarm-app.1249942187/ · https://forums.sailboatowners.com/threads/remote-anchor-watch-app-recommendation.1249934437/
- https://forums.ybw.com/threads/phone-anchor-alarms.549565/ · https://forums.ybw.com/threads/anchor-drag-alarm-setting-dilemma.447351/
- https://www.cruisersforum.com/forums/f2/advice-on-setting-anchor-drag-alarm-204866.html
- https://www.milltechmarine.com/Vesper-Cortex-Monitoring-One-of-the-most-compelling-reasons-to-buy-this-product_b_40.html · https://www.yachtingmonthly.com/gear/tested-vesper-cortex-vhf-radio-ais-and-remote-monitoring-79119
