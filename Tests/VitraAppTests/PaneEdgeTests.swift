import Testing
import Foundation
@testable import VitraApp

@Suite("Pane drop edges")
struct PaneEdgeTests {
    let rect = CGRect(x: 0, y: 0, width: 800, height: 400)

    @Test("each wedge answers its own side")
    func wedges() {
        #expect(PaneEdge.nearest(to: CGPoint(x: 40, y: 200), in: rect) == .leading)
        #expect(PaneEdge.nearest(to: CGPoint(x: 760, y: 200), in: rect) == .trailing)
        // Top-left origin: a small y is the top of the pane.
        #expect(PaneEdge.nearest(to: CGPoint(x: 400, y: 20), in: rect) == .top)
        #expect(PaneEdge.nearest(to: CGPoint(x: 400, y: 380), in: rect) == .bottom)
    }

    @Test("a wide pane still has a top and a bottom")
    func proportions() {
        // 120 pt from the top of a 400-pt pane is nearer the top edge in
        // points than the 280 pt to the left edge, but in fractions it is not.
        #expect(PaneEdge.nearest(to: CGPoint(x: 120, y: 120), in: rect) == .leading)
        #expect(PaneEdge.nearest(to: CGPoint(x: 380, y: 40), in: rect) == .top)
    }

    @Test("the highlight covers the half it would take")
    func halves() {
        #expect(PaneEdge.bottom.half(of: rect) == CGRect(x: 0, y: 200, width: 800, height: 200))
        #expect(PaneEdge.leading.half(of: rect) == CGRect(x: 0, y: 0, width: 400, height: 400))
    }

    @Test("orientation and order follow the edge")
    func orientation() {
        #expect(PaneEdge.leading.isVertical && PaneEdge.leading.isBefore)
        #expect(PaneEdge.bottom.isVertical == false && PaneEdge.bottom.isBefore == false)
    }
}
