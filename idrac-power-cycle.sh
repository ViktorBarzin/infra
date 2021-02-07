#!/bin/bash


# Get power supply on outside system voltage
curl -s -k -u root:calvin -H"Content-type: application/json" -X GET https://idrac/redfish/v1/Chassis/System.Embedded.1/Power/PowerSupplies/PSU.Slot.2 |jq .LineInputVoltage

# Power off
curl -s -k -u root:calvin -X POST -d '{"Action": "Reset", "ResetType": "GracefulShutdown"}' -H"Content-type: application/json" https://idrac/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset

# Power on
curl -s -k -u root:calvin -X POST -d '{"Action": "Reset", "ResetType": "On"}' -H"Content-type: application/json" https://idrac/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset
