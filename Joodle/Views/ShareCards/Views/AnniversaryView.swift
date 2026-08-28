import SwiftUI

struct AnniversaryView: View {
  private let cardStyle: ShareCardStyle = .anniversary
  let entry: DayEntry?
  let date: Date
  let highResDrawing: UIImage?
  var showWatermark: Bool = true

  private var countdownString: String {
    return CountdownHelper.countdownText(from: Date(), to: date, locale: locale)
  }

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.locale) private var locale

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let scale = size.width / cardStyle.cardSize.width

      ZStack {
        // Background
        (colorScheme == .dark ? Color.black : Color.white)
          .ignoresSafeArea()

        VStack(spacing: 0) {
          Spacer()

          // Main content - Drawing or Text
          DrawingPreviewView(
            entry: entry,
            highResDrawing: highResDrawing,
            size: 600,
            scale: scale
          )
          .background(
            RoundedRectangle(cornerRadius: 80 * scale, style: .continuous)
              .foregroundStyle(.appSurface)
          )
          .clipShape(RoundedRectangle(cornerRadius: 80 * scale, style: .continuous))
          .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 2)

          Spacer()
          Spacer()

        }
        // Date footer
        VStack(){
          Spacer()
          VStack(spacing: 14 * scale) {
            Text(entry?.body ?? "")
              .font(.appFont(size: 52 * scale))
              .lineLimit(1)
              .padding(.horizontal, 140 * scale)
            Text(countdownString)
              .font(.appFont(size: 48 * scale))
              .foregroundColor(.appTextSecondary)
          }
        }
        .padding(.top, 30 * scale)
        .padding(.bottom, 100 * scale)
        .padding(.horizontal, 80 * scale)

        // Watermark - bottom right corner
        if showWatermark {
          MushroomWatermarkView(scale: scale)
        }
      }
      .frame(width: size.width, height: size.height)
    }
    .aspectRatio(cardStyle.cardSize.width / cardStyle.cardSize.height, contentMode: .fit)
  }
}

#Preview("With Drawing") {
  AnniversaryView(
    entry: DayEntry(
      body: "",
      createdAt: Date(),
      drawingData: createMockDrawingData()
    ),
    date: Date().addingTimeInterval(86400 * 5), // 5 days later
    highResDrawing: nil
  )
  .frame(width: 300, height: 300)
  // add border
  .border(Color.black)
}

#Preview("Without Watermark") {
  AnniversaryView(
    entry: DayEntry(
      body: "Birthday",
      createdAt: Date(),
      drawingData: createMockDrawingData()
    ),
    date: Date().addingTimeInterval(86400 * 5), // 5 days later
    highResDrawing: nil,
    showWatermark: false
  )
  .frame(width: 300, height: 300)
  // add border
  .border(Color.black)
}
