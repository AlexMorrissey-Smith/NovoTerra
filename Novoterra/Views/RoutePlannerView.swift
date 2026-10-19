import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

struct RoutePlannerView: View {
    @EnvironmentObject var fowDataManager: FOWDataManager
    @EnvironmentObject var iCloudManager: iCloudFileManager

    @StateObject private var locationManager = LocationManagerService()
    @StateObject private var routePlanner = RoutePlanner()
    @Environment(\.openURL) private var openURL

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var cameraRequestID = 0
    @State private var showFolderPicker = false
    @State private var showSearchSheet = false
    @State private var searchField: SearchField = .destination
    @State private var searchText = ""

    @State private var origin: RouteEndpoint = .currentLocation
    @State private var destination: RouteEndpoint?

    @State private var selectedLevel: AvoidanceLevel = .exploration
    @State private var selectedRouteID: UUID?

    @AppStorage("travelMode") private var travelMode: TravelMode = .driving
    @AppStorage("showFog") private var showFog = true
    @AppStorage("avoidTolls") private var avoidTolls = false
    @AppStorage("avoidHighways") private var avoidHighways = false
    @AppStorage("routeSortingPreference") private var routeSortingPref: RouteSortingPreference = .newDistance
    @AppStorage("preferredNavigationApp") private var preferredNavApp: NavigationAppPreference = .showBoth

    enum SearchField {
        case origin, destination
    }

    // MARK: - Derived State

    private var avoidance: RouteAvoidance {
        RouteAvoidance(tolls: avoidTolls, highways: avoidHighways)
    }

    private var levelRoutes: [RouteOption] {
        routePlanner.routes(for: selectedLevel, sortedBy: routeSortingPref)
    }

    private var currentRoute: RouteOption? {
        levelRoutes.first { $0.id == selectedRouteID } ?? levelRoutes.first
    }

    private var resolvedOrigin: CLLocationCoordinate2D? {
        origin.isCurrentLocation ? locationManager.location : origin.coordinate
    }

    /// True when either end of the trip is the user's current location.
    private var needsCurrentLocation: Bool {
        origin.isCurrentLocation || destination?.isCurrentLocation == true
    }

    private var resolvedDestination: CLLocationCoordinate2D? {
        guard let destination else { return nil }
        return destination.isCurrentLocation ? locationManager.location : destination.coordinate
    }

    /// Fog is drawn only once real data is indexed; otherwise the whole map would be fogged.
    private var fogIndex: FOWSpatialIndex? {
        showFog && fowDataManager.isReady && fowDataManager.tileCount > 0 ? fowDataManager.spatialIndex : nil
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            mapView

            VStack(spacing: 0) {
                topBar
                Spacer()
            }

            // Content stays above the tab bar; only the card's background extends under it.
            bottomCard
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            connectFolder(url)
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchSheetView(
                isPresented: $showSearchSheet,
                searchField: searchField,
                origin: $origin,
                destination: $destination,
                initialSearchText: searchText,
                onSelection: planIfReady
            )
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .onChange(of: travelMode) { _, _ in planIfReady() }
        .onChange(of: avoidance) { _, _ in planIfReady() }
        // New fog data: re-score the routes already shown (keeping the selection),
        // or plan for the first time if nothing was planned yet.
        .onChange(of: fowDataManager.dataVersion) { _, _ in
            if routePlanner.options.isEmpty {
                planIfReady()
            } else {
                routePlanner.rescore(index: fowDataManager.spatialIndex)
            }
        }
        // A first load that fails never changes dataVersion, so plan once loading stops.
        .onChange(of: fowDataManager.isLoading) { _, isLoading in
            if !isLoading, routePlanner.options.isEmpty, !routePlanner.isCalculating, routePlanner.error == nil {
                planIfReady()
            }
        }
        // Plan as soon as the first location fix arrives, if we were waiting for it.
        .onChange(of: locationManager.location != nil) { _, hasLocation in
            if hasLocation, routePlanner.options.isEmpty, !routePlanner.isCalculating { planIfReady() }
        }
        .onChange(of: routePlanner.options.map(\.id)) { _, _ in
            selectedRouteID = nil
            zoomToFitCurrentRoute()
        }
    }

    // MARK: - Map

    private var mapView: some View {
        RouteMapView(
            cameraPosition: cameraPosition,
            cameraRequestID: cameraRequestID,
            selectedRoute: currentRoute,
            alternativeRoutes: levelRoutes,
            routeColor: UIColor(routeColor(for: selectedLevel)),
            fogIndex: fogIndex,
            fogVersion: fowDataManager.dataVersion,
            originMarker: origin.isCurrentLocation ? nil : resolvedOrigin.map { ($0, origin.name) },
            destinationMarker: resolvedDestination.map { ($0, destination?.name ?? "Destination") }
        )
        .ignoresSafeArea()
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 8) {
            statusBanner
            searchCard
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    mapButton(systemImage: "location.fill", label: "Show my location") {
                        moveCamera(to: .userLocation(fallback: .automatic))
                    }
                    if fowDataManager.tileCount > 0 {
                        mapButton(systemImage: showFog ? "cloud.fill" : "cloud", label: showFog ? "Hide fog" : "Show fog") {
                            showFog.toggle()
                        }
                    }
                }
            }
        }
        .padding(.top, 60)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !iCloudManager.isAccessGranted {
            banner(icon: "exclamationmark.triangle.fill", tint: .orange, text: "Connect Fog of World data", showsChevron: true) {
                showFolderPicker = true
            }
        } else if fowDataManager.isLoading && !fowDataManager.isReady {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Loading fog data…").font(.caption)
                Spacer()
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        } else if let error = fowDataManager.error ?? iCloudManager.error {
            banner(icon: "exclamationmark.octagon.fill", tint: .red, text: error.localizedDescription, showsChevron: true) {
                showFolderPicker = true
            }
        } else if fowDataManager.pendingDownloads > 0 {
            banner(icon: "icloud.and.arrow.down", tint: .blue,
                   text: "\(fowDataManager.pendingDownloads) tiles still downloading from iCloud", showsChevron: false) {}
        }
    }

    private func banner(icon: String, tint: Color, text: String, showsChevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right").font(.caption)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var searchCard: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    openSearch(.origin)
                } label: {
                    HStack {
                        Circle().fill(.blue).frame(width: 10, height: 10)
                        Text(origin.name)
                            .foregroundStyle(origin.isCurrentLocation ? .blue : .primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: swapEndpoints) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.blue)
                        .font(.caption)
                        .padding(8)
                        .background(Color.blue.opacity(0.1), in: Circle())
                }
                .disabled(destination == nil)
                .accessibilityLabel("Swap start and destination")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().padding(.leading, 34)

            Button {
                openSearch(.destination)
            } label: {
                HStack {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Text(destination?.name ?? "Where to?")
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            Picker("Travel mode", selection: $travelMode) {
                ForEach(TravelMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }

    private func mapButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .accessibilityLabel(label)
    }

    // MARK: - Bottom Card

    @ViewBuilder
    private var bottomCard: some View {
        if destination != nil {
            Group {
                if routePlanner.isCalculating {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding routes through new territory…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if let error = routePlanner.error {
                    ContentUnavailableView {
                        Label("No route", systemImage: "location.slash")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button("Try Again", action: planIfReady)
                    }
                    .frame(height: 200)
                } else if fowDataManager.isLoading && !fowDataManager.isReady {
                    Label("Loading fog data…", systemImage: "cloud")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if needsCurrentLocation && locationManager.isDenied {
                    ContentUnavailableView {
                        Label("Location is off", systemImage: "location.slash")
                    } description: {
                        Text("Allow location access in Settings, or choose a start point.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        Button("Choose Start Point") { openSearch(.origin) }
                    }
                    .frame(height: 220)
                } else if resolvedOrigin == nil || resolvedDestination == nil {
                    Label("Waiting for your location…", systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if !routePlanner.options.isEmpty {
                    routeResults
                }
            }
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20)
                    .fill(.regularMaterial)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private var routeResults: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Picker("Exploration level", selection: $selectedLevel) {
                    ForEach(AvoidanceLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedLevel) { _, _ in
                    selectedRouteID = nil
                    zoomToFitCurrentRoute()
                }

                Text(selectedLevel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if routePlanner.scoredWithoutFogData {
                Label("No fog data loaded, so every road counts as new.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(levelRoutes.enumerated()), id: \.element.id) { index, route in
                        Button {
                            selectedRouteID = route.id
                            zoomToFitCurrentRoute()
                        } label: {
                            RouteOptionCard(route: route, index: index, isSelected: route.id == currentRoute?.id)
                                .frame(width: levelRoutes.count == 1 ? nil : 190)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)

            if let route = currentRoute {
                navigationButtons(for: route)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func navigationButtons(for option: RouteOption) -> some View {
        switch preferredNavApp {
        case .showBoth:
            HStack(spacing: 12) {
                navButton("Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill", app: .appleMaps, option: option)
                    .buttonStyle(.borderedProminent)
                navButton("Google Maps", systemImage: "map", app: .googleMaps, option: option)
                    .buttonStyle(.bordered)
            }
        case .appleMaps:
            navButton("Open in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill", app: .appleMaps, option: option)
                .buttonStyle(.borderedProminent)
        case .googleMaps:
            navButton("Open in Google Maps", systemImage: "map", app: .googleMaps, option: option)
                .buttonStyle(.borderedProminent)
        }
    }

    private func navButton(_ title: String, systemImage: String, app: NavigationApp, option: RouteOption) -> some View {
        Button {
            guard let dest = resolvedDestination else { return }
            NavigationHandoff.open(
                option,
                in: app,
                origin: origin.isCurrentLocation ? nil : resolvedOrigin,
                destination: dest,
                destinationName: destination?.name ?? "Destination",
                mode: travelMode,
                avoiding: avoidance
            )
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    // MARK: - Actions

    private func connectFolder(_ url: URL) {
        iCloudManager.handleFolderSelection(url)
        guard iCloudManager.isAccessGranted, let folderURL = iCloudManager.syncFolderURL else { return }
        Task { await fowDataManager.loadData(from: folderURL) }
    }

    private func openSearch(_ field: SearchField) {
        searchField = field
        switch field {
        case .origin: searchText = origin.isCurrentLocation ? "" : origin.name
        case .destination: searchText = destination?.name ?? ""
        }
        showSearchSheet = true
    }

    private func swapEndpoints() {
        guard let oldDestination = destination else { return }
        destination = origin
        origin = oldDestination
        planIfReady()
    }

    private func planIfReady() {
        guard let dest = resolvedDestination, let orig = resolvedOrigin else {
            routePlanner.clear()
            return
        }
        // Wait for the first fog load so routes aren't scored against an empty index.
        // The dataVersion change at the end of loading triggers planning again.
        if fowDataManager.isLoading && !fowDataManager.isReady {
            routePlanner.clear()
            return
        }
        routePlanner.plan(from: orig, to: dest, mode: travelMode, avoiding: avoidance, index: fowDataManager.spatialIndex)
    }

    private func moveCamera(to position: MapCameraPosition) {
        cameraPosition = position
        cameraRequestID += 1
    }

    private func zoomToFitCurrentRoute() {
        guard let route = currentRoute else { return }
        let rect = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count).boundingMapRect
        moveCamera(to: .rect(rect))
    }

    private func routeColor(for level: AvoidanceLevel) -> Color {
        switch level {
        case .balanced: return .blue
        case .adventurous: return .orange
        case .exploration: return .green
        }
    }
}

#Preview {
    RoutePlannerView()
        .environmentObject(FOWDataManager())
        .environmentObject(iCloudFileManager())
}
