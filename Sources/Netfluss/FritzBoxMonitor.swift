// Copyright (C) 2026 Rana GmbH
//
// This file is part of Netfluss.
//
// Netfluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Netfluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Netfluss. If not, see <https://www.gnu.org/licenses/>.

import Foundation

struct FritzBoxBandwidth: Equatable, Sendable {
    let rxRateBps: Double
    let txRateBps: Double
    let totalBytesReceived: UInt64
    let totalBytesSent: UInt64
    let maxDownstreamBps: UInt64
    let maxUpstreamBps: UInt64
}

enum FritzBoxError: Error {
    case invalidURL
    case requestFailed
    case parseError
}

enum FritzBoxMonitor {

    /// Queries the Fritz!Box TR-064 WANCommonInterfaceConfig service for current bandwidth.
    /// Uses `GetAddonInfos` which returns real-time byte rates and totals without authentication.
    static func fetchBandwidth(host: String) async throws -> FritzBoxBandwidth {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FritzBoxError.invalidURL }

        // Validate host: only allow safe characters (alphanumeric, dots, hyphens, colons for IPv6, brackets)
        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard trimmed.unicodeScalars.allSatisfy({ safeChars.contains($0) }) else {
            throw FritzBoxError.invalidURL
        }

        let urlString = "http://\(trimmed):49000/igdupnp/control/WANCommonIFC1"
        guard let url = URL(string: urlString) else { throw FritzBoxError.invalidURL }

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetAddonInfos xmlns:u="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"/>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1#GetAddonInfos",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = soapBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FritzBoxError.requestFailed
        }

        return try parseAddonInfos(data)
    }

    /// Queries max downstream/upstream via GetCommonLinkProperties (no auth required).
    static func fetchLinkProperties(host: String) async throws -> (maxDown: UInt64, maxUp: UInt64) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FritzBoxError.invalidURL }

        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard trimmed.unicodeScalars.allSatisfy({ safeChars.contains($0) }) else {
            throw FritzBoxError.invalidURL
        }

        let urlString = "http://\(trimmed):49000/igdupnp/control/WANCommonIFC1"
        guard let url = URL(string: urlString) else { throw FritzBoxError.invalidURL }

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetCommonLinkProperties xmlns:u="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"/>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1#GetCommonLinkProperties",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = soapBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FritzBoxError.requestFailed
        }

        return try parseLinkProperties(data)
    }

    // MARK: - XML Parsing

    private static func parseAddonInfos(_ data: Data) throws -> FritzBoxBandwidth {
        let parser = FritzBoxXMLParser(data: data, tags: [
            "NewByteSendRate", "NewByteReceiveRate",
            "NewTotalBytesSent64", "NewTotalBytesReceived64",
            "NewX_AVM_DE_TotalBytesSent64", "NewX_AVM_DE_TotalBytesReceived64"
        ])
        let values = parser.parse()

        guard let rxRate = values["NewByteReceiveRate"].flatMap({ Double($0) }),
              let txRate = values["NewByteSendRate"].flatMap({ Double($0) })
        else { throw FritzBoxError.parseError }

        // Try 64-bit counters first (AVM extension), fall back to standard
        let totalRx = values["NewX_AVM_DE_TotalBytesReceived64"].flatMap({ UInt64($0) })
                    ?? values["NewTotalBytesReceived64"].flatMap({ UInt64($0) })
                    ?? 0
        let totalTx = values["NewX_AVM_DE_TotalBytesSent64"].flatMap({ UInt64($0) })
                    ?? values["NewTotalBytesSent64"].flatMap({ UInt64($0) })
                    ?? 0

        return FritzBoxBandwidth(
            rxRateBps: rxRate,
            txRateBps: txRate,
            totalBytesReceived: totalRx,
            totalBytesSent: totalTx,
            maxDownstreamBps: 0,
            maxUpstreamBps: 0
        )
    }

    private static func parseLinkProperties(_ data: Data) throws -> (maxDown: UInt64, maxUp: UInt64) {
        let parser = FritzBoxXMLParser(data: data, tags: [
            "NewLayer1DownstreamMaxBitRate", "NewLayer1UpstreamMaxBitRate"
        ])
        let values = parser.parse()

        let maxDown = values["NewLayer1DownstreamMaxBitRate"].flatMap({ UInt64($0) }) ?? 0
        let maxUp = values["NewLayer1UpstreamMaxBitRate"].flatMap({ UInt64($0) }) ?? 0
        return (maxDown: maxDown, maxUp: maxUp)
    }
}

// MARK: - Simple XML Tag Extractor

private class FritzBoxXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let targetTags: Set<String>
    private var results: [String: String] = [:]
    private var currentTag: String?
    private var currentValue: String = ""

    init(data: Data, tags: [String]) {
        self.data = data
        self.targetTags = Set(tags)
    }

    func parse() -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if targetTags.contains(elementName) {
            currentTag = elementName
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentTag != nil {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if let tag = currentTag, tag == elementName {
            results[tag] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentTag = nil
        }
    }
}
