import SwiftUI

// MARK: - Route Option Card
struct RouteOptionCard: View {
    let route: RouteOption
    let index: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Route badge + time
            HStack(alignment: .center) {
                Text(route.isFastest ? "Fastest" : "Route \(String(UnicodeScalar(65 + index)!))")
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.blue : Color.gray.opacity(0.25), in: Capsule())

                Spacer()

                Text(Format.duration(route.expectedTravelTime))
                    .font(.headline)
                    .monospacedDigit()
            }

            // Row 2: New distance + total distance
            (Text("\(Format.distance(route.newDistanceMeters)) new").bold()
                + Text(" · \(Format.distance(route.totalDistanceMeters))").foregroundColor(.secondary))
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            // Row 3: Unexplored %
            Text("\(route.newTerritoryPercentage)% unexplored")
                .font(.subheadline.bold())
                .foregroundStyle(percentageColor(route.newTerritoryPercentage))

            // Row 4: Trade-off against the fastest route
            Text(deltaText)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var deltaText: String {
        if route.isFastest { return "Quickest way there" }
        let minutes = Int((route.extraTimeVsFastest / 60).rounded())
        let time = minutes == 0 ? "Same time" : (minutes > 0 ? "+\(minutes) min" : "\(minutes) min")
        let extraNew = route.extraNewDistanceVsFastest
        let distance = abs(extraNew) < 50
            ? "same new ground"
            : "\(extraNew > 0 ? "+" : "−")\(Format.distance(abs(extraNew))) new"
        return "\(time) · \(distance)"
    }

    private func percentageColor(_ percentage: Int) -> Color {
        if percentage > 80 { return .green }
        if percentage > 50 { return .orange }
        return .red
    }
}
