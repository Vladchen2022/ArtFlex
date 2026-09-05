import AppKit
import Testing
@testable import ArtFlex

@MainActor
struct CurveEditorInteractionTests {
    @Test func endpointCanBeGrabbedOutsideTheGraphBorder() throws {
        let view=CurveEditorNSView(frame:NSRect(x:0,y:0,width:360,height:170))
        #expect(view.clipsToBounds)
        var changed:CurveChannelState?
        var editing:[Bool]=[]
        view.update(state:.identity,isEnabled:true,appearance:.dark,allowsEndpointMovement:true,
                    allowsPointInsertion:true,allowsPointRemoval:true,onEditingChanged:{editing.append($0)},onChange:{changed=$0})
        func event(_ type:NSEvent.EventType,_ x:CGFloat,_ y:CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:y),modifierFlags:[],
                timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        // Handle center x=12. Its left half is outside the plot, inside NSView.
        view.mouseDown(with:try event(.leftMouseDown,8,12))
        view.mouseDragged(with:try event(.leftMouseDragged,96,60))
        view.mouseUp(with:try event(.leftMouseUp,96,60))
        let point=try #require(changed?.points.first)
        #expect(abs(point.x-0.25)<0.001)
        #expect(point.y>0.3 && point.y<0.4)
        #expect(editing == [true,false])
    }
}
