# Novoterra

An iOS app that reads Fog of World sync data from iCloud Drive and provides intelligent routing that avoids already-traveled areas.

## Features

- 📍 **Smart Route Planning**: Find routes through unexplored territory
- 🗺️ **FOW Integration**: Reads directly from Fog of World's iCloud sync folder
- 🎯 **Avoidance Levels**: Pioneer, Explorer, Adventurer, and Traveler modes
- 🚗 **Navigation Handoff**: Opens routes in Apple Maps or Google Maps with waypoints
- ⚡ **Memory Optimized**: Metadata-only indexing with JIT bitmap loading

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Fog of World app with iCloud sync enabled

## Setup

1. Open `Novoterra.xcodeproj` in Xcode
2. Configure your team and bundle identifier
3. Enable iCloud capability in Signing & Capabilities
4. Build and run on device

## Architecture

See [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md) for detailed technical documentation.

### Key Components

- **MercatorProjection**: Coordinate → Tile/Block/Pixel conversion
- **FOWParser**: Tile file parsing with zlib decompression
- **FOWSpatialIndex**: Memory-optimized JIT bitmap loading
- **RoutePlanner**: Two-pass algorithm with waypoint fuzzing
- **NavigationHandoff**: Apple Maps / Google Maps integration

## License

MIT
