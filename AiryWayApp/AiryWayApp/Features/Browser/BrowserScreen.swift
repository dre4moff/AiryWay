import SwiftUI

struct BrowserScreen: View {
    @EnvironmentObject private var browserStore: BrowserStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: browserStore.goBack) {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!browserStore.canGoBack)

                    Button(action: browserStore.goForward) {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!browserStore.canGoForward)

                    TextField("Enter URL or search", text: $browserStore.addressBarText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            browserStore.loadAddressBar()
                        }

                    Button(browserStore.isLoading ? "Stop" : "Go") {
                        browserStore.isLoading ? browserStore.stopLoading() : browserStore.loadAddressBar()
                    }
                    .buttonStyle(.borderedProminent)
                }

                WebViewRepresentable()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if !browserStore.title.isEmpty {
                            Text(browserStore.title)
                                .font(.caption)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(12)
                        }
                    }

                if !browserStore.recentURLs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(browserStore.recentURLs, id: \.absoluteString) { url in
                                Button(url.host ?? url.absoluteString) {
                                    browserStore.load(input: url.absoluteString)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding()
            .navigationTitle("AiryWay Browser")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: browserStore.reload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        browserStore.clearRecentHistory()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .disabled(browserStore.recentURLs.isEmpty)
                }
            }
        }
    }
}
