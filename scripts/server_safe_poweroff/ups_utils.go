package main

import (
	"time"

	"github.com/golang/glog"
	"github.com/gosnmp/gosnmp"
)

type UPSPowerState = struct {
	inputVoltage     int
	minutesRemaining uint
}

func getSNMPClient() *gosnmp.GoSNMP {

	// Define SNMP connection parameters
	target := "192.168.1.5"
	community := "Public0"

	// Create a new SNMP client
	snmp := &gosnmp.GoSNMP{
		Target:    target,
		Port:      161, // Default SNMP port
		Community: community,
		Version:   gosnmp.Version2c, // Use SNMP v2c
		Timeout:   time.Duration(5) * time.Second,
	}
	return snmp
}
func getPowerState(snmp *gosnmp.GoSNMP) (UPSPowerState, error) {
	oids := []string{
		// "1.3.6.1.2.1.33.1.2.2.0",     // seconds on battery
		"1.3.6.1.2.1.33.1.3.3.1.3.1", // input voltage
		"1.3.6.1.2.1.33.1.2.3.0",     // minutes remaining
	}
	// Perform an SNMP GET request to retrieve the values for the specified OIDs
	result, err := snmp.Get(oids)
	if err != nil {
		glog.Fatalf("Failed to perform SNMP GET request: %v", err)
	}

	inputVoltage := (result.Variables[0].Value).(int)
	minutesRemaining := result.Variables[1].Value.(uint)
	return UPSPowerState{inputVoltage, minutesRemaining}, nil
}
