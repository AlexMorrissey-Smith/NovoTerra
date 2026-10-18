import SwiftUI

// MARK: - Route Option Card
struct RouteOptionCard: View {
    let route: RouteOption
    let index: Int
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Route Badge + Time
            HStack(alignment: .center) {
                let routeLetter = String(UnicodeScalar(65 + index)!)
                Text("Route \(routeLetter)")
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.blue : Color.gray.opacity(0.25))
                    .clipShape(Capsule())
                
                Spacer()
                
                Text(formatDuration(route.expectedTravelTime))
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            // Row 2: New distance + Total distance
            (Text("\(formatDistance(route.newDistanceMeters)) new")
                .bold()
                .foregroundStyle(.primary) +
            Text(" · \(formatDistance(route.totalDistanceMeters)) total")
                .foregroundStyle(.secondary))
                .font(.caption)
            
            // Row 3: Unexplored %
            Text("\(route.newTerritoryPercentage)% Unexplored")
                .font(.subheadline.bold())
                .foregroundStyle(percentageColor(route.newTerritoryPercentage))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color(.secondarySystemBackground))
                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
    
    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
    }
    
    private func percentageColor(_ percentage: Int) -> Color {
        if percentage > 80 { return .green }
        if percentage > 50 { return .orange }
        return .red
    }
}

