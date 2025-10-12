//
//  SimpleHTTPServer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import FlyingFox
import Foundation

class SimpleHTTPServer {
    var task: Task<Void, Error>?

    init() {}

    func start(path: URL) {
        if let task, !task.isCancelled {
            stop()
        }

        self.task = Task {
            let server = HTTPServer(port: 19123)
            await server.appendRoute("GET /*") { request in
                let fileName = request.path.replacing("/", with: "")

                guard var contents = try? Data(contentsOf: path.appending(component: fileName)) else {
                    return HTTPResponse(statusCode: .notFound)
                }
                if !fileName.hasSuffix(".m3u8") {
                    contents.append(Data("\n#EXT-X-ENDLIST".utf8))
                }

                return HTTPResponse(statusCode: .ok, body: contents)
            }

            do {
                print("Run server")
                try await server.run()
                print("Server running")
            } catch {
                print("Server stopped")
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}
