import SwiftUI

/// Placeholder geometry uses the same layout containers and spacing as live content.
/// Only the group animates; individual bars do not run their own animations.
struct SkeletonGroup<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .opacity(reduceMotion ? 1 : (pulse ? 0.55 : 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = !reduceMotion }
            .onChange(of: reduceMotion) { pulse = !reduceMotion }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Loading"))
    }
}

struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Theme.fillActive)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

struct SkeletonTaskCard: View {
    var height: CGFloat = 180

    var body: some View {
        TaskCardBodyLayout(minimumHeight: max(180, height) - 28) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    SkeletonBar(width: 55, height: 11)
                    SkeletonBar(width: 28, height: 11)
                    Spacer()
                }
                SkeletonBar(height: 14).padding(.trailing, 18)
                SkeletonBar(height: 14).padding(.trailing, 60)
                HStack(spacing: 5) {
                    SkeletonBar(width: 70, height: 21, radius: 6)
                    SkeletonBar(width: 95, height: 21, radius: 6)
                }
            }
            SkeletonBar(height: 11).frame(maxHeight: .infinity, alignment: .topLeading).clipped()
            HStack(spacing: 6) {
                SkeletonBar(width: 105, height: 26, radius: 6)
                Spacer(minLength: 8)
                SkeletonBar(width: 26, height: 26, radius: 6)
                SkeletonBar(width: 26, height: 26, radius: 6)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceActive))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

struct SkeletonTaskSection: View {
    var cardHeight: CGFloat = 180

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SkeletonBar(width: 160, height: 15)
                    SkeletonBar(width: 16, height: 12)
                }
                TaskCardGrid {
                    ForEach(0 ..< 6) { _ in SkeletonTaskCard(height: cardHeight) }
                }
            }
        }
    }
}

struct SkeletonAccount: View {
    var body: some View {
        SkeletonGroup {
            HStack(spacing: 7) {
                SkeletonBar(width: 20, height: 20, radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonBar(width: 90, height: 12)
                    SkeletonBar(width: 65, height: 10)
                }
            }
        }
    }
}

struct SkeletonFilters: View {
    var body: some View {
        SkeletonGroup {
            HStack(spacing: 6) {
                ForEach([60.0, 95, 130, 85], id: \.self) { width in
                    SkeletonBar(width: width, height: 26, radius: 7)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

struct SkeletonRepositoryGrid: View {
    var body: some View {
        SkeletonGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(0 ..< 6) { _ in
                    HStack(spacing: 10) {
                        SkeletonBar(width: 17, height: 17)
                        VStack(alignment: .leading, spacing: 5) {
                            SkeletonBar(width: 110, height: 13)
                            SkeletonBar(height: 12).padding(.trailing, 12)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Theme.border))
                }
            }
        }
    }
}

struct SkeletonSavedWork: View {
    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(width: 210, height: 15)
                SkeletonBar(height: 12).padding(.trailing, 70)
                ForEach(0 ..< 3) { _ in
                    HStack(spacing: 12) {
                        SkeletonBar(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 5) {
                            SkeletonBar(height: 14).padding(.trailing, 40)
                            SkeletonBar(width: 220, height: 12)
                            SkeletonBar(width: 140, height: 12)
                        }
                        Spacer()
                        SkeletonBar(width: 80, height: 13)
                    }.padding(14)
                    Divider()
                }
            }
        }
    }
}

struct SkeletonList: View {
    enum Kind { case worktrees, reviews, files }
    var kind: Kind
    var count = 6

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: kind == .files ? 1 : 4) {
                ForEach(0 ..< count, id: \.self) { index in
                    HStack(spacing: 10) {
                        SkeletonBar(width: kind == .files ? 12 : 18, height: 14)
                        VStack(alignment: .leading, spacing: 5) {
                            SkeletonBar(height: 13)
                                .frame(maxWidth: kind == .files ? 80 : CGFloat(180 + index % 3 * 40), alignment: .leading)
                            SkeletonBar(height: 10)
                                .frame(maxWidth: kind == .files ? 95 : CGFloat(310 + index % 3 * 30), alignment: .leading)
                            if kind == .reviews {
                                SkeletonBar(height: 10).frame(maxWidth: 230, alignment: .leading)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if kind == .files {
                            SkeletonBar(width: 18, height: 10)
                            SkeletonBar(width: 18, height: 10)
                        } else {
                            Spacer(minLength: 8)
                            SkeletonBar(width: 75, height: 12)
                            SkeletonBar(width: 24, height: 20)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: kind == .files ? 38 : (kind == .reviews ? 58 : 46))
                }
            }
        }
    }
}

struct SkeletonDiff: View {
    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBar(width: 240, height: 13).padding(.horizontal, 12).frame(height: 32)
                Divider()
                ForEach(0 ..< 18) { index in
                    HStack(spacing: 14) {
                        SkeletonBar(width: 70, height: 10)
                        GeometryReader { geometry in
                            SkeletonBar(width: geometry.size.width * [0.65, 0.4, 0.8, 0.5, 0.3][index % 5], height: 11)
                        }
                        .frame(height: 11)
                    }.padding(.horizontal, 14).frame(height: 18)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct SkeletonResult: View {
    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 14) {
                SkeletonBar(width: 145, height: 12)
                ForEach(0 ..< 3) { index in SkeletonBar(height: 14).padding(.trailing, CGFloat(index * 45)) }
                SkeletonBar(width: 110, height: 12).padding(.top, 8)
                HStack(spacing: 8) {
                    SkeletonBar(width: 18, height: 18)
                    SkeletonBar(width: 200, height: 13)
                }
                SkeletonBar(height: 40, radius: 7)
            }
        }
    }
}

struct SkeletonIssueSuggestions: View {
    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 2) {
                SkeletonBar(width: 135, height: 11).padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(0 ..< 6) { index in
                    HStack(spacing: 6) {
                        SkeletonBar(width: 12, height: 12)
                        SkeletonBar(width: 38, height: 12)
                        SkeletonBar(height: 12).padding(.trailing, CGFloat(index % 3 * 30))
                    }.padding(.horizontal, 10).frame(height: 26)
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
        }
    }
}
