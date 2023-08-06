import Foundation
import Virtualization

let minMemory: UInt64 = 128

enum VMError: Error {
    case runtimeError(String)
}

func createConsoleConfiguration() -> VZSerialPortConfiguration {
    let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
    let inputFileHandle = FileHandle.standardInput
    let outputFileHandle = FileHandle.standardOutput
    var attributes = termios()
    tcgetattr(inputFileHandle.fileDescriptor, &attributes)
    attributes.c_iflag &= ~tcflag_t(ICRNL)
    attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(inputFileHandle.fileDescriptor, TCSANOW, &attributes)
    let stdioAttachment = VZFileHandleSerialPortAttachment(fileHandleForReading: inputFileHandle,
                                                           fileHandleForWriting: outputFileHandle)
    consoleConfiguration.attachment = stdioAttachment
    return consoleConfiguration
}


func isReadOnly(data: Dictionary<String, String>) -> Bool {
    return (data["readonly"] ?? "") == "yes"
}

func  getVMConfig(memoryMB: UInt64,
                  numCPUs: Int,
                  commandLine: String,
                  kernelPath: String,
                  initrdPath: String,
                  disks: Array<Dictionary<String, String>>,
                  shares: Dictionary<String, Dictionary<String, String>>,
                  networking: Array<Dictionary<String, String>>) throws -> VZVirtualMachineConfiguration {
    let kernelURL = URL(fileURLWithPath: kernelPath)
    let bootLoader: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    bootLoader.commandLine = commandLine
    if (initrdPath != "") {
        bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
    }

    print("configuring - kernel: \(kernelPath), initrd: \(initrdPath), cmdline: \(commandLine)")
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = numCPUs
    config.memorySize = memoryMB * 1024*1024
    config.serialPorts = [createConsoleConfiguration()]

    var networkConfigs = Array<VZVirtioNetworkDeviceConfiguration>()
    var networkAttachments = Set<String>()
    for network in networking {
        let networkMode = (network["mode"] ?? "")
        let networkConfig = VZVirtioNetworkDeviceConfiguration()
        var networkIdentifier = ""
        var networkIdentifierMessage = ""
        switch (networkMode) {
        case "nat":
            let networkMAC = (network["mac"] ?? "")
            if (networkMAC != "") {
                guard let addr = VZMACAddress(string: networkMAC) else {
                    throw VMError.runtimeError("invalid MAC address: \(networkMAC)")
                }
                networkConfig.macAddress = addr
            }
            networkIdentifier = networkMAC
            networkIdentifierMessage = "multiple NAT devices using same or empty MAC is not allowed \(networkMAC)"
            networkConfig.attachment = VZNATNetworkDeviceAttachment()
            print("NAT network attached (mac? \(networkMAC))")
        default:
            throw VMError.runtimeError("unknown network mode: \(networkMode)")
        }
        if (networkAttachments.contains(networkIdentifier)) {
            throw VMError.runtimeError(networkIdentifierMessage)
        }
        networkAttachments.insert(networkIdentifier)
        networkConfigs.append(networkConfig)
    }
    config.networkDevices = networkConfigs
    
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    var allStorage = Array<VZVirtioBlockDeviceConfiguration>()
    for disk in disks {
        let diskPath = (disk["path"] ?? "")
        if (diskPath == "") {
            throw VMError.runtimeError("invalid disk, empty path")
        }
        guard let diskObject = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskPath), readOnly: isReadOnly(data: disk)) else {
            throw VMError.runtimeError("invalid disk: \(diskPath)")
        }
        allStorage.append(VZVirtioBlockDeviceConfiguration(attachment: diskObject))
        print("attaching disk: \(diskPath)")
    }
    config.storageDevices = allStorage

    if (shares.count > 0) {
        var allShares = Array<VZVirtioFileSystemDeviceConfiguration>()
        for key in shares.keys {
            do {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(key)
            } catch {
                throw VMError.runtimeError("invalid tag: \(key)")
            }
            guard let local = shares[key] else {
                throw VMError.runtimeError("unable to read share data")
            }
            let sharePath = (local["path"] ?? "")
            if (sharePath == "") {
                throw VMError.runtimeError("empty share path: \(key)")
            }
            let directoryShare = VZSharedDirectory(url:URL(fileURLWithPath: sharePath), readOnly: isReadOnly(data: local))
            let singleDirectory = VZSingleDirectoryShare(directory: directoryShare)
            let shareConfig = VZVirtioFileSystemDeviceConfiguration(tag: key)
            shareConfig.share = singleDirectory
            allShares.append(shareConfig)
            print("sharing: \(key) -> \(sharePath)")
         }
         config.directorySharingDevices = allShares
    }
    return config
}

func usage() {
     print("swiftvf:\n  -c/-config <configuration file (json)> [REQUIRED]\n  -h/-help\n")
}

func readJSON(path: String) -> [String: Any]? {
    do {
        let text = try String(contentsOfFile: path)
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                print(error.localizedDescription)
            }
        }
        return nil
    } catch {
        fatalError("unable to read JSON from file \(path)")
    }
}

func run() {
    var jsonConfig = ""
    var idx = 0
    for argument in CommandLine.arguments {
        switch (idx) {
        case 0:
            break
        case 1:
            if (argument != "-c" && argument != "-config") {
                if (argument == "-help" || argument == "-h") {
                    usage()
                    return
                }
                fatalError("invalid argument: \(argument)")
            }
        case 2:
            jsonConfig = argument
        default:
            fatalError("unknown argument: \(argument)")
        }
        idx += 1
    }
    if (jsonConfig == "") {
        fatalError("no JSON config given")
    }
    let object = (readJSON(path: jsonConfig) ?? Dictionary())
    let kernel = ((object["kernel"] as? String) ?? "")
    if (kernel == "") {
        fatalError("kernel path is not set")
    }
    let initrd = ((object["initrd"] as? String) ?? "")
    let network = ((object["network"] as? Array<Dictionary<String, String>>) ?? Array<Dictionary<String, String>>())
    let cmd = ((object["cmdline"] as? String) ?? "console=hvc0")
    let cpus = ((object["cpus"] as? Int) ?? 1)
    if (cpus <= 0) {
        fatalError("cpu count must be > 0")
    }
    let mem = ((object["memory"] as? UInt64) ?? minMemory)
    if (mem < minMemory) {
        fatalError("memory must be >= \(minMemory)")
    }
    let disks = ((object["disks"] as? Array<Dictionary<String, String>>) ?? Array<Dictionary<String, String>>())
    let shares = ((object["shares"] as? Dictionary<String, Dictionary<String, String>>) ?? Dictionary<String, Dictionary<String, String>>())

    do {
        let config = try getVMConfig(memoryMB: mem, numCPUs: cpus, commandLine: cmd, kernelPath: kernel, initrdPath: initrd, disks: disks, shares: shares, networking: network)
        try config.validate()
        let queue = DispatchQueue(label: "secondary queue")
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        queue.sync{
            if (!vm.canStart) {
                fatalError("vm can not start")
            }
        }
        print("vm ready")
        queue.sync{
            vm.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    fatalError("virtual machine failed to start with \(error)")
                }
            })
        }
        print("vm initialized")
        sleep(1)
        while (vm.state == VZVirtualMachine.State.running || vm.state == VZVirtualMachine.State.starting) {
            sleep(1)
        }
    } catch VMError.runtimeError(let errorMessage) {
        fatalError("vm error: \(errorMessage)")
    } catch (let errorMessage) {
        fatalError("error: \(errorMessage)")
    }
}

run()
