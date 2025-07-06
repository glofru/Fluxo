//
//  SimpleHTTPServer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import FlyingFox
import Foundation

class SimpleHTTPServer {
    let task: Task<Void, Error>

    let path: URL

    init(path: URL) {
        self.path = path

        self.task = Task {
            let server = HTTPServer(port: 19123)
            await server.appendRoute("GET /*") { request in
                let fileName = request.path.replacing("/", with: "")

                guard let contents = try? Data(contentsOf: path.appending(component: fileName)) else {
                    return HTTPResponse(statusCode: .notFound)
                }

                return HTTPResponse(statusCode: .ok, body: contents)
            }

            do {
                print("Run server")
                try await server.run()
                print("Server running")
            } catch {
                print("Server failed")
            }
        }
    }

    func stop() {
        task.cancel()
    }
}
