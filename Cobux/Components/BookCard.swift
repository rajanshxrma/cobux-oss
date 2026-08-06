import SwiftUI

struct BookCard: View {
    let book: Book

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverBackground

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    BookTitleText(
                        title: book.title,
                        font: .headline,
                        weight: .bold,
                        color: .white,
                        lineLimit: 2,
                        expandsWidth: true
                    )

                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    if book.highlights.count > 0 {
                        Text("\(book.highlights.count) highlights")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.3))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.7), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
            }
        }
        .aspectRatio(3/4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3)
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let urlString = book.coverImageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    CoverGradientView(colorHex: book.coverColorHex)
                }
            }
        } else {
            CoverGradientView(colorHex: book.coverColorHex)
        }
    }
}
