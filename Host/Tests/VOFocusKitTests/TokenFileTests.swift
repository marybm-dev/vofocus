import Foundation
import Testing
@testable import VOFocusKit

struct TokenFileTests {
    @Test func simulatorKeepsTheOldName() {
        #expect(RunnerClient.tokenFileName(port: 8740) == "runner-8740.token")
    }

    @Test func deviceNamesMatchRunnerSh() throws {
        // What scripts/runner.sh makes with `tr -c 'A-Za-z0-9-' '_'`, byte by byte.
        for device in ["00008110-00125DD11A50401E", "Mary's iPad", "Mary’s iPad Mini"] {
            let shell = Process()
            shell.executableURL = URL(filePath: "/bin/bash")
            shell.arguments = ["-c", "printf '%s' \"$1\" | LC_ALL=C tr -c 'A-Za-z0-9-' '_'", "_", device]
            let pipe = Pipe()
            shell.standardOutput = pipe
            try shell.run()
            shell.waitUntilExit()
            let expected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(RunnerClient.fileSuffix(device: device) == "-" + expected)
        }
    }
}
