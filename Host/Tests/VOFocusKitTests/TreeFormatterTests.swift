import Foundation
import Testing
@testable import VOFocusKit

@Suite struct TreeFormatterTests {
    @Test func dropsUnlabeledContainersAndKeepsTheirChildren() throws {
        let json = """
        {"type":"application","label":"Demo","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"other","frame":[0,0,402,874],"children":[
              {"type":"staticText","label":"Sign Up","frame":[16,78,96,41.66]},
              {"type":"textField","frame":[16,135.6,370,34]},
              {"type":"button","identifier":"submit","label":"Submit","frame":[16,185.6,54,24.3]}
            ]}
          ]}
        ]}
        """
        let outline = try TreeFormatter.outline(fromJSON: Data(json.utf8))
        #expect(outline == """
        application "Demo" [0,0,402,874]
          staticText "Sign Up" [16,78,96,42]
          textField [16,136,370,34]
          button "Submit" #submit [16,186,54,24]
        """)
    }

    @Test func keepsContainersThatHaveAnIdentifier() throws {
        let json = """
        {"type":"other","identifier":"card","frame":[0,0,10,10],"children":[
          {"type":"button","label":"OK","frame":[1,1,5,5]}
        ]}
        """
        let outline = try TreeFormatter.outline(fromJSON: Data(json.utf8))
        #expect(outline == "other #card [0,0,10,10]\n  button \"OK\" [1,1,5,5]")
    }
}
