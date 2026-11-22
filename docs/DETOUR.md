# Detour implementation and validation

Branch: `feature/detour-walking-discovery`. The existing `starter/visual-assistant` branch is untouched. The attachment used for this work ends in the middle of the POI JSON example (`source_urls`); the implementation follows the objectives and requirements visible above that point.

## Run on a Mac

1. Fetch and switch to this branch. Keep local signing changes backed up; do not discard them to switch branches.
2. Open `ios/TaskLens.xcodeproj`, keep the **TaskLens** scheme, select your iPhone and Personal Team, and Run. The installed display name is **Detour**. The scheme/module/binary names remain TaskLens so existing signing and tests stay compatible.
3. Start Exploring → enable **Indoor simulation** → Generate → preview the explicitly schematic route → Start → Advance Demo. This path needs no GPS, backend, or AI generation. Apple map tiles still need connectivity or an existing cache; the map is not an offline map download.
4. For a real walk, disable simulation, grant location permission via **Use current location**, and wait for a good fix. You can also search for a starting place or tap the map. Location denial still permits manual previews and simulation; it never pretends to start GPS navigation.
5. Generate a real route. MapKit must return actual `.walking` routes that fit the chosen time budget, including the destination/return leg and a stop allowance. No route is replaced by straight lines on failure.
6. Start near the marked start. Tap discovery pins for a clue. Nearby prompts offer Find it or Keep walking; successful camera checks mark finds and reveal the record. Source summaries work locally after finding. Optional AI stories and camera analysis need the existing backend connection; the scanner's Demo responses setting remains authoritative.
7. For AI, keep the existing `server/.env` values and run `cd server && npm start`. The scanner still uses authenticated `POST /analyze`; the new services are under `/detour/`. A real phone needs the Mac's reachable LAN address, not localhost. Outside that network, point the app at your own reachable backend to use optional cloud features. Already-calculated navigation and source summaries do not depend on that backend.

## Architecture

- `DetourViews.swift`: adaptive light/dark home, preferences, search/map-pin start, preview, active walking map, source details, simulation labels and summary.
- `DetourModels.swift`: normalized public POIs, persistent preferences/history, route legs, and bounded path projection.
- `DetourRoutePlanner.swift`: ranks nearby candidates by real interest matches, novelty and geographic proximity, evaluates up to ten candidates with MapKit, and includes real pedestrian travel estimates and optional return travel in admission decisions. It is a bounded greedy heuristic, not a globally optimal city tour solver. The same selections will often repeat when priorities/availability have not changed.
- `DetourNavigation.swift`: foreground-started Core Location session, path progress, spoken MapKit instructions, arrival detection, notification actions, pause/resume and explicit schematic simulation. It owns a separate instance of the existing SpeechService, so the scanner can stop when locked without stopping walking location updates.
- `DetourStore.swift`: coordinates route generation, local summaries (last 30), cancellation, source/AI narration, and reuse of the existing scanner. Camera-confirmed finds affect future novelty ranking; nearby-only stops and simulation do not.
- `landmarks.mjs`: source normalization, filtering, bounded Overpass calls, deduplication and a 15-minute/32-area cache. It does not run on every GPS update. OSM is requested before merging the bundled municipal catalog. Source outages are explicit and fall back to the catalog.
- `landmark-enrichment.mjs`: optionally batches up to four **explicitly linked** OSM Wikipedia article references, at most English and French. Missing, failed or unlinked articles leave mapped descriptions unchanged. Wikidata IDs are retained as reference links. There is no speculative name matching or arbitrary source fetching.
- `detour-story.mjs`: optional Gemini narration from server-owned municipal records and facts only, with source links and bounded cached output. It cannot accept client-invented history, URLs or coordinates. Generated stories still need source checking; schema checks cannot prove every generated claim is true.

## Geographic data and attribution

`server/data/montreal-landmarks.json` and its identical app resource contain **35 real municipal public-art records** around central Montréal; 30 have no building association and are eligible outdoor routing candidates. Records associated with buildings are retained for discovery but excluded from route generation because indoor access/entrances are unverified. Route candidates must also be reachable through a MapKit walking route whose endpoint is near the mapped discovery point. This is not an accessibility or opening-hours guarantee.

Municipal source: [Art public — information sur les œuvres de la collection municipale](https://www.donneesquebec.ca/recherche/dataset/vmtl-art-public-information-sur-les-oeuvres-de-la-collection-municipale), resource `18705524-c8a6-49a0-bca7-92f493e6d329`, licensed **CC BY 4.0**. The publisher's metadata identifies the JSON resource, coordinates, licence, and field documentation. The direct municipal download was blocked from the authoring environment; the actual source fields/records were inspected through the archived mirror at `5nguy/opendata`, commit `ec8c7325d9e0df7f00bbba09471cc0a999e96705`, path `montreal/ckan/ville-de-montreal/societe-culture/art-public-information-sur-les-oeuvres-de/oeuvresdonneesouvertes.json`.

Inspected fields: `NoInterne`, `Titre`, `CoordonneeLatitude`, `CoordonneeLongitude`, `Artistes`, `DateFinProduction`, `MateriauxAng`, `Materiaux`, `Parc`, `Batiment`. Coordinates are WGS84 decimal latitude/longitude. Names, artists, materials and recorded years are factual normalized metadata; short English/French descriptions are templates from those facts, not invented historical narratives. The archived snapshot can be stale. Do not represent the collection as a current live-access inventory.

To rebuild from a newly downloaded municipal JSON file:

```sh
node scripts/import-detour-landmarks.mjs /path/to/oeuvresdonneesouvertes.json
python3 scripts/generate-xcode-project.py
```

The importer updates the server and iOS resource together. The generator preserves existing per-configuration team, bundle identifier and signing overrides and adds JSON to Copy Bundle Resources. No third-party packages are needed.

OSM: [© OpenStreetMap contributors](https://www.openstreetmap.org/copyright), **ODbL 1.0**. Live Overpass endpoint: `https://overpass-api.de/api/interpreter`. Queries include named historic/artwork/attraction/museum/park features and selected named natural nodes. Private/no-access, disused and indoor-tagged objects are excluded. Named ways/relations retain representative-centre discovery pins but are **not** eligible route entrances. Source IDs and Wikipedia/Wikidata references are retained. OSM and municipal objects are deduplicated by source ID or nearby matching name. Public Overpass can be overloaded; there is no retry/fallback-server fan-out. Wikipedia text retains the linked article and licence/history attribution. In-app attribution is accessible from maps and settings.

## Background behavior and product limits

- This is a native navigation prototype, not a validated substitute for Apple/Google Maps. The route comes from MapKit; Gemini never creates roads, turn directions or route times.
- A user starts a walk in the foreground with When In Use location permission. `UIBackgroundModes` includes `location` and `audio`; active walks enable continuous location updates. Speech uses a playback session for background navigation. Stopping a walk stops location updates and playback. iOS force-quit/termination and relaunch recovery are not implemented as uninterrupted navigation.
- GPS fixes older than 20 seconds or worse than 65 m accuracy do not advance navigation. Progress is constrained to a short forward window to reduce jumps around loops. Urban canyons, parallel paths and missed updates can still confuse this basic tracker. Off-route guidance stops advancing and offers explicit recalculation. Recalculation can exceed the initial budget and keeps the original route if it fails.
- Arrival uses a 45 m proximity check plus path progress near the leg endpoint; this is approximate, not proof the camera faces a specific object. Initial real navigation requires a recent GPS fix within 150 m of the route start. Manual previews never substitute for current GPS.
- Direction prompts interrupt stories. Narration waits for current prompts to finish; skipping a story or opening the scanner cancels pending narration so a late provider reply cannot take over. Sources remain available to inspect.
- The scanner remains fully functional with its own captions, selection, research, voice picker and history. It receives the nearby landmark as a **candidate** plus source facts, never a guaranteed identification. Opening it suspends navigation speech; closing it restores the walk. Camera/microphone handling continues to pause when the scanner leaves the foreground.
- Foreground voice commands are opt-in: find, story, skip, repeat, scan and pause. Speech recognition is **off when the screen is locked**; spoken route cues, notification actions can continue. Optional source narration starts after a find when the scanner closes. The app does not promise always-listening background conversation. Notification actions offer Find it and Keep walking; Find it opens the foreground app.
- Narration can use English/French voices and records. MapKit instruction text follows the device/map-service language; the app does not ask an LLM to translate or invent safety-critical street directions. The main UI is English.
- Live walks require network during route calculation; optional cloud scanning/enrichment also requires network. Offline navigation-map downloads, continuous app-termination recovery, account/social features and route resume after a process restart are outside this MVP.

## Verification

Run backend tests with `npm test --prefix server`. Tests cover the existing scanner, source normalization, duplicate/in-flight discovery requests, cache/fallback behavior, input/authentication, mock isolation, story evidence restrictions, Wikipedia reference restrictions and resource equality. They use fake transports and spend no Gemini/Serper credits.

`ios/TaskLensTests/DetourTests.swift` adds native tests for loop-safe projection, actual walking-time budget admission, interest/novelty ranking, return legs and provider-free simulation. **These tests and the iOS app have not been compiled or run here: Xcode and an iPhone are unavailable.** Do not treat static review or passing Node tests as native build/device validation.

On the Mac:

```sh
xcodebuild -project ios/TaskLens.xcodeproj -scheme TaskLens -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Use Product → Test on an available simulator/device for the native tests. Rehearse the actual outdoor route with a real iPhone before presenting locked-screen guidance. See DEVICE_CHECKS.md for GPS, audio interruption, source access, skip/cancellation and simulation checks.

## Destination and landmark finding

A walk can now finish at an optional searched place or dropped destination pin.
That endpoint takes precedence over return-to-start. Planning checks Apple's
actual walking route to the endpoint before adding stops and includes the final
leg in every time-budget check. If the destination fits but extra stops do not,
Detour offers the direct pedestrian route with an explanation. Recalculation
retains the chosen endpoint. Indoor simulation remains explicitly schematic.

Tap any discovery pin in the preview or active walk for a brief material/category
clue. Unfound pins hide the landmark's title. Accurate GPS within about 45 m of an
on-route stop triggers a spoken nearby prompt and optional notification, with
**Find it** and **Keep walking** actions. Passing near a stop is recorded separately
from finding it. Ignoring a stop does not block the next route leg.

Find it opens the existing scanner with an extra **Check camera view** control.
The deliberate check makes one `/detour/verify` request; ordinary chat answers
cannot award a find. It needs a live walk, current GPS within 100 m (accuracy at
most 65 m), a fresh camera frame, and live AI settings. The backend looks up the
landmark in its own municipal catalog or discovery cache and sends only that
record and the frame to Gemini. Client-supplied facts are ignored. A high-confidence
visual match with readable identification or source-supported distinctive features
is required. Generic/uncertain views remain unconfirmed. A valid returned box uses
the existing frame-aware highlight tracker. Dismissal/backgrounding cancels the
check; no automatic provider retries or background camera loops were added.

This is an AI-assisted prototype check, not a guarantee of identity or an
anti-cheating system. The records do not include reference photographs; many
objects will need a readable identifying plaque. Demo mode and simulation never
award real finds. Successful finds reveal the title and sourced description and
are saved in walk history separately from nearby stops. Legacy histories retain
their nearby counts without being relabelled as verified finds. Automatic stories,
when enabled, play after a successful find once the scanner closes.
