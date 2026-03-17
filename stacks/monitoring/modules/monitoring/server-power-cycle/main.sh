#!/bin/sh

tag=server-power-cycle-script
logger -t $tag start $(date '+%F-%R')

if [ -f /tmp/server-power-cycle-lock ]; then
        logger -t $tag 'Script already running. exiting'
        exit 0
fi
touch /tmp/server-power-cycle-lock


if [ -f /root/server-power-cycle/state.off ]; then
        logger -t $tag 'Server state set to off'
        while true; do
                sleep 60 # sleep 1 minute
                logger -t $tag 'Trying to connect to idrac system...'
                curl --connect-timeout 5 -s -k -u root:calvin -H"Content-type: application/json" -X GET https://192.168.1.4/redfish/v1/Chassis/System.Embedded.1/Power/PowerSupplies/PSU.Slot.2
                if [[ $? -eq 0 ]]; then
                        logger -t $tag "Connected to idrac, assuming power is back on"
                        logger -t $tag "Power supply restored, sending power on command"
                        curl -s -k -u root:calvin -X POST -d '{"Action": "Reset", "ResetType": "On"}' -H"Content-type: application/json" https://192.168.1.4/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset
                        rm /root/server-power-cycle/state.off

                        logger -t $tag end $(date '+%F-%R')
                        rm /tmp/server-power-cycle-lock
                        exit 0
                fi
        done
fi


voltage=$(curl -s -k -u root:calvin -H"Content-type: application/json" -X GET https://192.168.1.4/redfish/v1/Chassis/System.Embedded.1/Power/PowerSupplies/PSU.Slot.2 |jq .LineInputVoltage)
# check input voltage on the pwoer supply connected to the outer system
if [[ $voltage -gt 0 ]]; then
        logger -t $tag "power supply is on. exiting"
        logger -t $tag end $(date '+%F-%R')
        rm /tmp/server-power-cycle-lock
        exit 0
fi

to_wait=30
echo "Continuously checking power supply for the next $to_wait minutes"

for i in $(seq 30); do
        logger -t $tag "Sleeping a minute..Minute $i"
        sleep 60

        # check input voltage on the pwoer supply connected to the outer system
        voltage=$(curl -s -k -u root:calvin -H"Content-type: application/json" -X GET https://192.168.1.4/redfish/v1/Chassis/System.Embedded.1/Power/PowerSupplies/PSU.Slot.2 |jq .LineInputVoltage)
        if [[ $voltage -gt 0 ]]; then
                logger -t $tag "power supply is on. exiting"

                logger -t $tag end $(date '+%F-%R')
                rm /tmp/server-power-cycle-lock
                exit 0
        fi

done

logger -t $tag "Power supply did not come back, sending graceful shutdown signal"
curl -s -k -u root:calvin -X POST -d '{"Action": "Reset", "ResetType": "GracefulShutdown"}' -H"Content-type: application/json" https://192.168.1.4/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset

touch /root/server-power-cycle/state.off
rm /tmp/server-power-cycle-lock
logger -t $tag end $(date '+%F-%R')
