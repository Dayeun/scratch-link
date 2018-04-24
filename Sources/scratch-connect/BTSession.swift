import Foundation
import IOBluetooth
import Swifter

class BTSession: Session, IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceInquiryDelegate {
    private var inquiry: IOBluetoothDeviceInquiry
    private var connectedChannel: IOBluetoothRFCOMMChannel?
    private var sequenceId = 0
    private let rfcommQueue = DispatchQueue(label: "ScratchConnect.BTSession.rfcommQueue")
    internal var wss: WebSocketSession
    
    required init(withSocket wss: WebSocketSession) {
        self.wss = wss
        inquiry = IOBluetoothDeviceInquiry(delegate: nil)
        inquiry.delegate = self
    }
    
    func didReceiveCall(_ method: String, withParams params: [String:Any],
                        completion: @escaping (_ result: Codable?, _ error: JSONRPCError?) -> Void) throws {
        switch method {
        case "discover":
            if let major = params["majorDeviceClass"] as? UInt, let minor = params["minorDeviceClass"] as? UInt {
                discover(inMajorDeviceClass: major, inMinorDeviceClass: minor, completion: completion)
            } else {
                completion(nil, JSONRPCError.InvalidParams(data: "majorDeviceClass and minorDeviceClass required"))
            }
        case "connect":
            if let peripheralId = params["peripheralId"] as? String {
                connect(toDevice: peripheralId, completion: completion)
            } else {
                completion(nil, JSONRPCError.InvalidParams(data: "peripheralId required"))
            }
        case "send":
            if connectedChannel == nil || connectedChannel?.isOpen() == false {
                completion(nil, JSONRPCError.InvalidRequest(data: "No peripheral connected"))
            } else if let message = params["message"] as? String, let encoding = params["encoding"] as? String {
                var decodedMessage: [UInt8]
                if encoding == "base64" {
                    decodedMessage = base64Decode(message)
                    if decodedMessage.count > 0 {
                        sendMessage(decodedMessage, completion: completion)
                    } else {
                        completion(nil, JSONRPCError.InvalidParams(data: "Invalid base64 string"))
                    }
                } else if encoding == "utf8" {
                    // DANGER ZONE: any real message that we might want to send to EV3 cannot be reliably transferred
                    // as utf-8. Bluetooth probably shouldn't support utf8 encoding of 'send' messages.
                    decodedMessage = utf8Decode(message)
                    sendMessage(decodedMessage, completion: completion)
                } else {
                    completion(nil, JSONRPCError.InvalidParams(data: "Unsupported encoding"))
                }
            }
        default:
            completion(nil, JSONRPCError.MethodNotFound())
        }
    }
    
    func discover(inMajorDeviceClass major: UInt, inMinorDeviceClass minor: UInt,
                  completion: @escaping (_ result: Codable?, _ error: JSONRPCError?) -> Void) {
        // see https://www.bluetooth.com/specifications/assigned-numbers/baseband for available device classes
        // LEGO EV3 is major class toy (8), minor class robot (1)
        inquiry.setSearchCriteria(BluetoothServiceClassMajor(kBluetoothServiceClassMajorAny),
                                   majorDeviceClass: BluetoothDeviceClassMajor(major),
                                   minorDeviceClass: BluetoothDeviceClassMinor(minor))
        inquiry.inquiryLength = 20
        inquiry.updateNewDeviceNames = true
        let inquiryStatus = inquiry.start()
        let error = inquiryStatus != kIOReturnSuccess ?
            JSONRPCError.InternalError(data: "Device inquiry failed to start") : nil
        
        completion(nil, error)
    }
    
    func connect(toDevice deviceId: String,
                 completion: @escaping (_ result: Codable?, _ error: JSONRPCError?) -> Void) {
        inquiry.stop()
        let availableDevices = inquiry.foundDevices() as? [IOBluetoothDevice]
        if let device = availableDevices?.first(where: {$0.addressString == deviceId}) {
            rfcommQueue.async {
                let connectionResult = device.openRFCOMMChannelSync(&self.connectedChannel,
                     withChannelID: 1,
                     delegate: self)
                if (connectionResult != kIOReturnSuccess) {
                    completion(nil, JSONRPCError.InternalError(data:
                        "Connection process could not start or channel was not found"))
                }
            }
        } else {
            completion(nil, JSONRPCError.InvalidRequest(data: "Device \(deviceId) not available for connection"))
        }
    }
    
    func disconnect(fromDevice deviceId: String,
                    completion: @escaping (_ result: Codable?, _ error: JSONRPCError?) -> Void) {
        let bluetoothDevice = connectedChannel?.getDevice()
        if (bluetoothDevice?.addressString == deviceId) {
            let disconnectionResult = connectedChannel?.close()
            // release the connected channel and reset reference counter so we can reuse it
            connectedChannel = nil
            let error = disconnectionResult != kIOReturnSuccess ?
                JSONRPCError.InternalError(data: "Device failed to disconnect") : nil
            completion(nil, error)
        } else {
            completion(nil, JSONRPCError.InvalidRequest(data:
                "Cannot disconnect from device that is already not connected"))
        }
    }
    
    func sendMessage(_ message: [UInt8],
                     completion: @escaping (_ result: Codable?, _ error: JSONRPCError?) -> Void) {
        var data = message
        let mtu = connectedChannel?.getMTU()
        let maxMessageSize = Int(mtu!)
        if message.count <= maxMessageSize {
            rfcommQueue.async {
                let messageResult = self.connectedChannel?.writeSync(&data, length: UInt16(message.count))
                if messageResult != kIOReturnSuccess {
                    completion(nil, JSONRPCError.InternalError(data: "Failed to send message"))
                } else {
                    completion(message.count, nil)
                }
            }
        } else {
            // taken from https://stackoverflow.com/a/38156873
            let chunks = stride(from: 0, to: data.count, by: maxMessageSize).map {
                Array(data[$0..<min($0 + maxMessageSize, data.count)])
            }
            
            rfcommQueue.async {
                var succeeded = 0
                var bytesSent = 0
                for chunk in chunks {
                    var mutableChunk = chunk
                    let intermediateResult = self.connectedChannel?.writeSync(
                        &mutableChunk, length: UInt16(chunk.count))
                    succeeded += Int(intermediateResult!)
                    if intermediateResult == kIOReturnSuccess {
                        bytesSent += chunk.count
                    }
                }
                completion(bytesSent, succeeded == 0 ? nil : JSONRPCError.InternalError(data: "Failed to send message"))
            }
        }
    }
    
    /*
     * IOBluetoothDeviceInquiryDelegate implementation
     */
    
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        let peripheralData: [String: Any] = [
            "peripheralId": device.addressString,
            "name": device.name,
            "rssi": device.rawRSSI()
        ]
        sendRemoteRequest("didDiscoverPeripheral", withParams: peripheralData)
    }
    
    /*
     * IOBluetoothRFCOMMChannelDelegate implementation
     */
    
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        let encodedMessage = base64Encode(dataPointer, length: dataLength)
        let responseData: [String: Any] = [
            "message": encodedMessage,
            "encoding": "base64"
        ]
        sendRemoteRequest("didReceiveMessage", withParams: responseData)
    }
    
    /*
     * Helper methods
     */
    
    func base64Encode(_ buffer: UnsafeMutableRawPointer, length: Int) -> String {
        var array: [UInt8] = Array(repeating: 0, count: length)
        for index in 0..<length {
            array[index] = buffer.load(fromByteOffset: index, as: UInt8.self)
        }
        let data = Data(array)
        return data.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
    }
    
    func base64Decode(_ base64String: String) -> [UInt8] {
        if let data = Data(base64Encoded: base64String) {
            return [UInt8](data)
        }
        return []
    }
    
    func utf8Decode(_ utf8String: String) -> [UInt8] {
        return [UInt8](utf8String.utf8)
    }
}
