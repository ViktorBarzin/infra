package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/golang/glog"
	"github.com/gosnmp/gosnmp"
)

type UPSPowerState = struct {
	inputVoltage     int
	minutesRemaining int
	chargePercent    int
	secondsOnBattery int64
	batteryStatus    int
}

// RFC 1628 UPS-MIB OIDs. All verified to read correctly on this Huawei UPS2000
// SNMP card — see docs/plans/2026-07-18-graceful-shutdown-on-power-loss.md App B.
const (
	oidInputVoltage     = "1.3.6.1.2.1.33.1.3.3.1.3.1" // upsInputVoltage line 1 (0 on battery)
	oidMinutesRemaining = "1.3.6.1.2.1.33.1.2.3.0"     // upsEstimatedMinutesRemaining
	oidChargePercent    = "1.3.6.1.2.1.33.1.2.4.0"     // upsEstimatedChargeRemaining (percent)
	oidSecondsOnBattery = "1.3.6.1.2.1.33.1.2.2.0"     // upsSecondsOnBattery (0 == on mains)
	oidBatteryStatus    = "1.3.6.1.2.1.33.1.2.1.0"     // upsBatteryStatus (2=normal, 3=low)
)

func getSNMPClient(target, community string) *gosnmp.GoSNMP {
	return &gosnmp.GoSNMP{
		Target:    target,
		Port:      161,
		Community: community,
		Version:   gosnmp.Version2c,
		Timeout:   5 * time.Second,
		Retries:   2,
	}
}

func getPowerState(snmp *gosnmp.GoSNMP) (UPSPowerState, error) {
	oids := []string{oidInputVoltage, oidMinutesRemaining, oidChargePercent, oidSecondsOnBattery, oidBatteryStatus}
	result, err := snmp.Get(oids)
	if err != nil {
		return UPSPowerState{}, fmt.Errorf("SNMP GET failed: %v", err)
	}

	byOID := make(map[string]gosnmp.SnmpPDU, len(result.Variables))
	for _, v := range result.Variables {
		byOID[strings.TrimPrefix(v.Name, ".")] = v
	}

	// get coerces any SNMP numeric type to int64 without panicking (unlike the
	// old value.(int)/value.(uint) assertions) and errors on a missing OID.
	get := func(oid string) (int64, error) {
		pdu, ok := byOID[oid]
		if !ok {
			return 0, fmt.Errorf("OID %s missing from SNMP response", oid)
		}
		switch pdu.Type {
		case gosnmp.NoSuchObject, gosnmp.NoSuchInstance, gosnmp.EndOfMibView:
			return 0, fmt.Errorf("OID %s not available on device (type=%v)", oid, pdu.Type)
		}
		if pdu.Value == nil {
			return 0, fmt.Errorf("OID %s returned a nil value", oid)
		}
		return gosnmp.ToBigInt(pdu.Value).Int64(), nil
	}

	inputVoltage, err := get(oidInputVoltage)
	if err != nil {
		return UPSPowerState{}, err
	}
	minutesRemaining, err := get(oidMinutesRemaining)
	if err != nil {
		return UPSPowerState{}, err
	}
	chargePercent, err := get(oidChargePercent)
	if err != nil {
		return UPSPowerState{}, fmt.Errorf("battery charge (%s) required for the power-on gate: %w", oidChargePercent, err)
	}
	secondsOnBattery, err := get(oidSecondsOnBattery)
	if err != nil {
		return UPSPowerState{}, err
	}
	// Battery status is advisory (observability only) — never fail the read on it.
	batteryStatus, err := get(oidBatteryStatus)
	if err != nil {
		glog.Warningf("upsBatteryStatus unavailable: %v", err)
		batteryStatus = 0
	}

	return UPSPowerState{
		inputVoltage:     int(inputVoltage),
		minutesRemaining: int(minutesRemaining),
		chargePercent:    int(chargePercent),
		secondsOnBattery: secondsOnBattery,
		batteryStatus:    int(batteryStatus),
	}, nil
}
