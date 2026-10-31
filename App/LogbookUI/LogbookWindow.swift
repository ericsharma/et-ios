import SwiftUI

/// The Logbook window (PLAN-logbook-v2 §4.1): places, cards, transcript.
struct LogbookWindow: View {
    var body: some View {
        ContentUnavailableView("Logbook", systemImage: "book.pages", description: Text("Coming in B2"))
    }
}
