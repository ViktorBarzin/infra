package main

import (
	"flag"
	"log"

	"github.com/golang/glog"
	"github.com/nightlyone/lockfile"
)

const upsMinutesRemainingThreshold = 20

type idracCredentials = struct {
	url      string
	username string
	password string
}

func main() {
	idracUsername := flag.String("idracUsername", "root", "iDRAC username")
	idracPassword := flag.String("idracPassword", "calvin", "iDRAC password")
	idracHost := flag.String("idracHost", "192.168.1.4", "iDRAC host")
	flag.Parse()
	defer glog.Flush()
	// lock, err := tryGetLock()
	// if err != nil {
	// 	glog.Fatalf("Failed to acquire lock:  %v", err)
	// }
	// defer lock.Unlock()

	glog.Info("Checking server power state")
	idracCredentials := idracCredentials{
		url:      "https://" + *idracHost,
		username: *idracUsername,
		password: *idracPassword,
	}
	powerState, err := checkPowerState(idracCredentials)
	if err != nil {
		glog.Fatalf("Failed to check power state: %v", err)
	}
	glog.Infof("Server power state: %s", powerState)

	glog.Info("Checking UPS state")
	snmp := getSNMPClient()
	// Connect to the SNMP agent
	err = snmp.Connect()
	if err != nil {
		log.Fatalf("Failed to connect to UPS SNMP agent: %v", err)
	}
	defer snmp.Conn.Close()

	upsState, err := getPowerState(snmp)
	if err != nil {
		glog.Fatalf("Failed to get UPS power state: %v", err)
	}

	if powerState == "On" {
		handleWhenServerOn(upsState, idracCredentials)
	} else if powerState == "Off" {
		handleWhenServerOff(upsState, idracCredentials)
	} else {
		glog.Fatalf("Unknown server state %s", powerState)
	}
}
func handleWhenServerOn(upsState UPSPowerState, idracCredentials idracCredentials) {
	if upsState.inputVoltage > 0 {
		glog.Infof("UPS is on AC power: %d. Nothing to do.\n", upsState.inputVoltage)
		return
	} else {
		glog.Warningln("UPS is on Battery power")
		if upsState.minutesRemaining < upsMinutesRemainingThreshold {
			glog.Warningf("Minutes remaining is too low - %d Turning off server.", upsState.minutesRemaining)
			// Perform a graceful shutdown of the server
			performGracefulShutdown(idracCredentials)
		} else {
			glog.Warningf("Minutes remaining is %d. Server will not be shutdown yet.", upsState.minutesRemaining)
			return
		}
	}
}

func handleWhenServerOff(upsState UPSPowerState, idracCredentials idracCredentials) {
	if upsState.inputVoltage > 0 {
		glog.Infof("UPS is on AC power: %d\n", upsState.inputVoltage)
		if upsState.minutesRemaining < upsMinutesRemainingThreshold {
			glog.Infof("UPS battery is still too low - %d minutes remaining. Not turning on server yet.\n", upsState.minutesRemaining)
		} else {
			glog.Infof("UPS is on AC power and battery has charged - %d minutes remaining. Turning on server...\n", upsState.minutesRemaining)
			// Perform startup of the server
			performPowerOn(idracCredentials)
		}
	} else {
		glog.Warningln("UPS is still on battery power")
		return
	}
}
func tryGetLock() (*lockfile.Lockfile, error) {
	lock, err := lockfile.New("/tmp/server_safe_poweroff.pid")
	if err != nil {
		log.Fatalf("Failed to create lock file: %v", err)
	}
	err = lock.TryLock()
	if err != nil {
		return nil, err
	}
	return &lock, nil
}
