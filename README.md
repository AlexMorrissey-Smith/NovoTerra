# Novoterra

An iOS app that reads your Fog of World sync data from iCloud Drive and plans routes through places you haven't been yet.

## Features

- **Exploration routing**: finds routes that cover the most unexplored ground.
- **Three exploration levels**: Balanced, Adventurous and Exploration allow up to 20%, 50% and 100% more travel time than the fastest route.
- **Drive, cycle or walk**: routes and handoff use the chosen travel mode.
- **Avoid tolls or motorways**: driving routes can skip toll roads and motorways. Google Maps handoff keeps the preference; Apple Maps doesn't accept it from other apps.
- **Fog overlay**: the map is fogged everywhere except where your Fog of World tracks have been.
- **Compared with the fastest route**: each route card shows the extra time and the extra new distance.
- **Navigation handoff**: opens the route in Apple Maps or Google Maps with intermediate stops so the external app follows it.

## Requirements

- iOS 17.0+
- Xcode 15.0+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Fog of World with iCloud sync enabled

## Setup

1. Run `xcodegen generate` to create `NovoTerra.xcodeproj` from `project.yml`.
2. Open `NovoTerra.xcodeproj` and set your signing team.
3. Build and run on a device. In the app, connect your Fog of World folder in iCloud Drive.

`project.yml` is the source of truth for the project. Edit it, not the generated `.xcodeproj`.

## Tests

The `NovoTerraTests` target holds logic tests. They compile the model and service code directly.

The Fog of World tests need real sync files as fixtures. Those files are personal location history, so they are not in the repository: `FOW File Examples/` is gitignored. To run those tests, copy some tile files from your own Fog of World `Sync` folder into `FOW File Examples/`, or point `FOW_FIXTURES_DIR` at a folder that holds them. Without fixtures, those tests are skipped.

```bash
xcodebuild test -project NovoTerra.xcodeproj -scheme Novoterra -destination 'platform=iOS Simulator,name=iPhone 17'
```

## How routing works

MapKit can't be told to avoid areas, so `RoutePlanner`:

1. Requests Apple's normal route alternatives. The fastest becomes the baseline.
2. Probes a grid of points across the corridor between start and destination, and keeps the most unexplored ones that are well spread out.
3. Requests a two-leg route through each of those points, a few at a time to stay under MapKit's rate limit. It rejects routes that double back on themselves.
4. Resamples every route every 20 m and checks each sample against the fog data. A sample counts as visited if a recorded track lies within 20 m, which absorbs GPS noise and road-geometry offsets.
5. Removes duplicate routes, then each exploration level shows the best routes within its time budget.

## Architecture

| Component | Role |
| --- | --- |
| `FOWParser` | Decodes tile filenames and decompresses tile files. |
| `MercatorProjection` | Converts between coordinates and Fog of World tile/block/pixel space. |
| `FOWSpatialIndex` | Actor holding the tile list, with a byte-budgeted LRU cache of decoded tiles and the visited checks. |
| `FOWDataManager` | Syncs the iCloud folder into a local cache, builds the index, and refreshes when the app returns to the foreground. |
| `LocalFileCache` | Copies tile files from iCloud Drive into the app sandbox and triggers iCloud downloads. |
| `RoutePlanner` | Candidate generation, scoring and ranking. |
| `FogTileOverlay` / `FogRenderer` | Renders the fog as map tiles. |
| `NavigationHandoff` | Opens Apple Maps or Google Maps with the route's stops. |

The Fog of World file format follows [fog-machine](https://github.com/CaviarChen/fog-machine).

## License

MIT
