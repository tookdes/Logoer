//
//  BatteryInfo.swift
//  AirBattery
//
//  Created by apple on 2023/9/7.
//

import Foundation
import IOKit.ps
import SwiftUI

struct iBattery {
    var hasBattery: Bool
    var isCharging: Bool
    var isCharged: Bool
    var acPowered: Bool
    var batteryLevel: Int
    var levelColor: String
}

func getPowerColor(_ level: Int) -> String {
    var colorName = "my_green"
    if level <= 10 {
        colorName = "my_red"
    } else if level <= 20 {
        colorName = "my_yellow"
    }
    return colorName
}

func getPowerState() -> iBattery {
    if deviceType.lowercased().contains("book") {
        let internalFinder = InternalFinder()
        if let internalBattery = internalFinder.getInternalBattery() {
            if let level = internalBattery.charge {
                return iBattery(hasBattery: true, isCharging: internalBattery.isCharging ?? false, isCharged: internalBattery.isCharged ?? false, acPowered: internalBattery.acPowered ?? false, batteryLevel: Int(level), levelColor: getPowerColor(Int(level)))
            }
        }
    }
    return iBattery(hasBattery: false, isCharging: false, isCharged: false, acPowered: false, batteryLevel: 0, levelColor: "my_gray")
}

class InternalBattery {
    var currentCapacity: Int?
    var maxCapacity: Int?
    var acPowered: Bool?
    var isCharging: Bool?
    var isCharged: Bool?

    var charge: Double? {
        get {
            if let current = self.currentCapacity,
               let max = self.maxCapacity {
                return (Double(current) / Double(max)) * 100.0
            }
            return nil
        }
    }
}

class InternalFinder {
    private var serviceInternal: io_connect_t = 0 // io_object_t
    private var internalChecked: Bool = false
    private var hasInternalBattery: Bool = false

    public init() { }

    public var batteryPresent: Bool {
        get {
            if !self.internalChecked {
                let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
                let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

                self.hasInternalBattery = sources.count > 0
                self.internalChecked = true
            }

            return self.hasInternalBattery
        }
    }

    fileprivate func open() {
        if #available(macOS 12, *) {
            self.serviceInternal = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        } else {
            self.serviceInternal = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
    }

    fileprivate func close() {
        IOObjectRelease(self.serviceInternal)
        self.serviceInternal = 0
    }

    func getInternalBattery() -> InternalBattery? {
        self.open()

        if self.serviceInternal == 0 {
            return nil
        }

        let battery = self.getBatteryData()

        self.close()

        return battery
    }

    fileprivate func getBatteryData() -> InternalBattery {
        let battery = InternalBattery()

        // Capacities
        battery.currentCapacity = self.getIntValue("CurrentCapacity" as CFString)
        battery.maxCapacity = self.getIntValue("MaxCapacity" as CFString)

        // Plug
        battery.acPowered = self.getBoolValue("ExternalConnected" as CFString)
        battery.isCharging = self.getBoolValue("IsCharging" as CFString)
        battery.isCharged = self.getBoolValue("FullyCharged" as CFString)

        return battery
    }

    fileprivate func getIntValue(_ identifier: CFString) -> Int? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Int
        }

        return nil
    }

    fileprivate func getBoolValue(_ forIdentifier: CFString) -> Bool? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, forIdentifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Bool
        }

        return nil
    }
}
