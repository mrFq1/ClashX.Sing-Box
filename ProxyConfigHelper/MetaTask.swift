//
//  MetaTask.swift
//  com.metacubex.ClashX.ProxyConfigHelper


import Cocoa

class MetaTask: NSObject {
    
    struct MetaServer: Encodable {
        var externalController: String
        let secret: String
        var log: String = ""
        
        var enableTun: Bool
        
        func jsonString() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            guard let data = try? encoder.encode(self),
                  let string = String(data: data, encoding: .utf8) else {
                return ""
            }
            return string
        }
    }
    
    struct MetaCurl: Decodable {
        let hello: String
    }
    
    var proc = Process()
    private var executableURL: URL?
    let procQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! + ".MetaProcess")
    
    var timer: DispatchSourceTimer?
    let timerQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! + ".timer")
    
    let metaDNS = MetaDNS()
    
    @objc func setLaunchPath(_ path: String) {
        let u = URL(fileURLWithPath: path)
        executableURL = u
    }
    
    @objc func start(_ confPath: String,
               confFilePath: String,
               result: @escaping stringReplyBlock) {
        
        proc = Process()
        
        guard let executableURL = executableURL else {
            result("sing-box path losted.")
            return
        }
        proc.executableURL = executableURL
        
        var resultReturned = false
        
        func returnResult(_ re: String) {
            guard !resultReturned else { return }
            timer?.cancel()
            timer = nil
            resultReturned = true
            DispatchQueue.main.async {
                result(re)
            }
        }
        
        var args = [
            "-D",
            confPath
        ]
        
        if confFilePath != "" {
            args.append(contentsOf: [
                "-c",
                confFilePath
            ])
        }
        
        killOldProc()
        
        procQueue.async {
            do {
                if let info = self.test(confPath, confFilePath: confFilePath) {
                    returnResult(info)
                    return
                } else {
                    print("Test meta config success.")
                }
                
                guard var serverResult = self.parseConfFile(confPath, confFilePath: confFilePath) else {
                    returnResult("Can't decode config file.")
                    return
                }
                
                func setTunDNS() {
                    if serverResult.enableTun {
                        self.metaDNS.updateDns()
                    } else {
                        self.metaDNS.revertDns()
                    }
                }
                
                
                args.append("run")
                
                self.proc.arguments = args
                let pipe = Pipe()
                var logs = [String]()
                
                let errorPipe = Pipe()
                var errorLogs = [String]()
                
                pipe.fileHandleForReading.readabilityHandler = { pipe in
                    guard let output = String(data: pipe.availableData, encoding: .utf8),
                          !resultReturned else {
                        return
                    }
                    
                    output.split(separator: "\n").map {
                        self.formatMsg(String($0))
                    }.forEach {
                        logs.append($0)
                    }
                }
                
                
                errorPipe.fileHandleForReading.readabilityHandler = { pipe in
                    guard let output = String(data: pipe.availableData, encoding: .utf8) else {
                        return
                    }
                    output.split(separator: "\n").forEach {
                        errorLogs.append(String($0))
                    }
                }
                
                
                self.proc.standardError = errorPipe
                self.proc.standardOutput = pipe
                
                self.proc.terminationHandler = { proc in
                    self.metaDNS.revertDns()
                    
                    guard !resultReturned else {
                        guard errorLogs.count > 0 else { return }
                        
                        errorLogs.append("terminationStatus: \(proc.terminationStatus)")
                        errorLogs.append("terminationReason: \(proc.terminationReason)")
                        
                        let data = errorLogs.joined(separator: "\n").data(using: .utf8)
                        
                        let url = URL(fileURLWithPath: confPath)
                            .appendingPathComponent("logs")
                            
                        let fm = FileManager.default
                        try? fm.createDirectory(atPath: url.path, withIntermediateDirectories: true)
                        
                        let fileName = {
                            let dateformat = DateFormatter()
                            dateformat.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                            let s = dateformat.string(from: Date())
                            return "singbox_core_crash_\(s).log"
                        }()
                        
                        fm.createFile(atPath: url.appendingPathComponent(fileName).path, contents: data)
                        return
                    }
                    
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let string = String(data: data, encoding: String.Encoding.utf8) else {
                        
                        returnResult("Meta process terminated, no found output.")
                        return
                    }
                    
                    let results = string.split(separator: "\n").map(String.init).map(self.formatMsg(_:))
                    
                    returnResult(results.joined(separator: "\n"))
                }
                
                self.timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
                self.timer?.schedule(deadline: .now(), repeating: .milliseconds(500))
                self.timer?.setEventHandler {
                    guard self.testExternalController(serverResult) else {
                        return
                    }
                    serverResult.log = logs.joined(separator: "\n")
                    setTunDNS()
                    returnResult(serverResult.jsonString())
                }
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    serverResult.log = logs.joined(separator: "\n")
                    setTunDNS()
                    returnResult(serverResult.jsonString())
                }
                
                try self.proc.run()
                self.timer?.resume()
            } catch let error {
                returnResult("Start meta error, \(error.localizedDescription).")
            }
        }
    }

    @objc func stop(_ result: stringReplyBlock?) {
        DispatchQueue.main.async {
            guard self.proc.isRunning else { return }
            let proc = Process()
            proc.executableURL = .init(fileURLWithPath: "/bin/kill")
            proc.arguments = ["-15", "\(self.proc.processIdentifier)"]
            try? proc.run()
            proc.waitUntilExit()
            
            self.metaDNS.revertDns()
            result?(nil)
        }
    }
    
    @objc func test(_ confPath: String, confFilePath: String) -> String? {
        do {
            let proc = Process()
            proc.executableURL = self.proc.executableURL
            var args = [
                "check",
                "-D",
                confPath
            ]
            if confFilePath != "" {
                args.append(contentsOf: [
                    "-c",
                    confFilePath
                ])
            }
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            proc.standardOutput = outputPipe
            proc.standardError = errorPipe
            
            proc.arguments = args
            try proc.run()
            proc.waitUntilExit()
            
            if proc.terminationStatus != 0 {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let string = String(data: data, encoding: String.Encoding.utf8) {
                    if string.contains("FATAL"),
                       let i = string.range(of: "] ")?.upperBound {
                        return String(string.suffix(from: i))
                    } else {
                        return string
                    }
                } else {
                    return "Test failed, status \(proc.terminationStatus)"
                }
            } else {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                guard let string = String(data: data, encoding: String.Encoding.utf8) else {
                    return "Test failed, no found output."
                }
                if string == "" {
                    // test success
                    return nil
                } else {
                    return string
                }
            }
        } catch let error {
            return "\(error)"
        }
    }
    
    func killOldProc() {
        let proc = Process()
        proc.executableURL = .init(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["com.SagerNet.sing-box.ProxyConfigHelper.core"]
        try? proc.run()
        proc.waitUntilExit()
    }
    
    @objc func getUsedPorts(_ result: @escaping stringReplyBlock) {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = .init(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "lsof -nP -iTCP -sTCP:LISTEN | grep LISTEN"]
        try? proc.run()
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else {
            result("")
            return
        }
        
        let usedPorts = str.split(separator: "\n").compactMap { str -> Int? in
            let line = str.split(separator: " ").map(String.init)
            guard line.count == 10,
            let port = line[8].components(separatedBy: ":").last else { return nil }
            return Int(port)
        }.map(String.init).joined(separator: ",")
        
        result(usedPorts)
    }
    
    func testListenPort(_ port: Int) -> (pid: Int32, addr: String) {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = .init(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "lsof -nP -iTCP:\(port) -sTCP:LISTEN | grep LISTEN"]
        try? proc.run()
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8),
              str.split(separator: " ").map(String.init).count == 10 else {
            return (0, "")
        }
        
        let re = str.split(separator: " ").map(String.init)
        let pid = re[1]
        let addr = re[8]
        
        return (Int32(pid) ?? 0, addr)
    }
    
    func testExternalController(_ server: MetaServer) -> Bool {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = .init(fileURLWithPath: "/usr/bin/curl")
        var args = [server.externalController]
        if server.secret != "" {
            args.append(contentsOf: [
                "--header",
                "Authorization: Bearer \(server.secret)"
            ])
        }
        
        proc.arguments = args
        try? proc.run()
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        
        if let str = try? JSONDecoder().decode(MetaCurl.self, from: data),
           str.hello == "clash" {
            return true
        } else if let s = String(data: data, encoding: .utf8),
                  s.contains("Temporary Redirect") {
            return true
        } else {
            return false
        }
    }
    
    func formatMsg(_ msg: String) -> String {
        let msgs = msg.split(separator: " ", maxSplits: 2).map(String.init)
        
        guard msgs.count == 3,
              msgs[1].starts(with: "level"),
              msgs[2].starts(with: "msg") else {
            return msg
        }
        
        let level = msgs[1].replacingOccurrences(of: "level=", with: "")
        var re = msgs[2].replacingOccurrences(of: "msg=\"", with: "")
        
        while re.last == "\"" || re.last == "\n" {
            re.removeLast()
        }
        
        if re.contains("time=") {
            print(re)
        }
        
        return "[\(level)] \(re)"
    }
    
    func parseConfFile(_ confPath: String, confFilePath: String) -> MetaServer? {
        let fileURL = confFilePath == "" ? URL(fileURLWithPath: confPath).appendingPathComponent("config.json", isDirectory: false) : URL(fileURLWithPath: confFilePath)
        struct ConfigJSON: Decodable {
            let inbounds: [Inbound]
            let experimental: ConfigExperimental?
            
            struct Inbound: Decodable {
                let type: String
            }
            
            struct ConfigExperimental: Decodable {
                let clashAPI: ClashAPI?
                enum CodingKeys: String, CodingKey {
                    case clashAPI = "clash_api"
                }
            }
            
            struct ClashAPI: Decodable {
                let externalController: String
                let externalUI: String?
                let secret: String?
                enum CodingKeys: String, CodingKey {
                    case externalController = "external_controller",
                         externalUI = "external_ui",
                         secret
                }
            }
        }
        
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let configJSON = try? JSONDecoder().decode(ConfigJSON.self, from: data),
              let clashConfig = configJSON.experimental?.clashAPI else {
            return nil
        }
        
        return MetaServer(
            externalController: clashConfig.externalController,
            secret: clashConfig.secret ?? "",
            enableTun: configJSON.inbounds.contains(where: { $0.type == "tun" }))
    }
    
    func formatConfig(_ path: String) -> Data {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = executableURL
        proc.arguments = [
            "format",
            "-c",
            path
        ]
        
        try? proc.run()
        proc.waitUntilExit()
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
