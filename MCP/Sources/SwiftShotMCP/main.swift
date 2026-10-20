import Foundation

// Entry point of the SwiftShot MCP server.
//
// It speaks the Model Context Protocol over stdio (JSON-RPC 2.0) and forwards
// the tool calls to the running SwiftShot app, which owns the Screen Recording
// permission.
let server = MCPServer()
server.run()
