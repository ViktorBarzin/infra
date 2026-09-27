# London cutover: Flint straight onto the Hyperoptic line

One-off, before 6 Oct 2026. The Hyperoptic router goes back and the Flint 2
takes the Hyperoptic wall port directly. Viktor moves the cable; the agent
watches over the tunnel and makes the UI changes. Design:
`docs/plans/2026-09-27-london-flint-main-router.md`. Intended settings:
`docs/architecture/london-site.md`.

## Before the day

1. Read the Hyperoptic router's WAN MAC address from its admin page and write it
   down (needed only if Hyperoptic's DHCP will not serve the Flint).
2. Silence the London alerts in Alertmanager for the swap window
   (`alertname=~"London.*"`), so the planned outage does not post.

## On the day (agent watching)

1. Power the Hyperoptic router off.
2. Move the cable in the Flint's WAN port from the Hyperoptic router to the wall
   port.
3. Agent checks, in order:
   - WAN lease arrives (GL → Internet shows an address). If the address is in
     10.0.0.0/8, stop: the tunnel's 10/8 routes would capture the ISP gateway.
   - Tunnel handshake within about 2 minutes (`wg show wgclient1`).
   - The drop probe sees the new gateway (it reads it from the route).
4. Enable IPv6 in GL → Network → IPv6 → Native. If no prefix is delegated, set
   NAT6 instead. Confirm a LAN client gets a global IPv6 address.
5. Check what the internet can reach: scan the new public IPv4 and IPv6
   addresses for 22, 443 and 9100 from outside. 22 and 443 are expected open
   (decision 14 in the design); 9100 must be closed.
6. Lift the silence.

## If there is no internet after the swap

Work through these in the GL admin UI at `http://192.168.8.1` (password in the
password manager, item `london.viktorbarzin.me`):

| symptom | do this |
|---|---|
| GL → Internet shows no address after 2 minutes | NETWORK → MAC Address → WAN → Clone, enter the Hyperoptic router's WAN MAC, Apply. Wait 2 minutes. |
| still no address | INTERNET → Ethernet → advanced: VLAN ID. Only set one if Hyperoptic confirms a tag; the default is none. |
| an address, but Sofia services do not load | VPN → WireGuard Client: switch the connection off, then on. |
| nothing works | Put the Hyperoptic router back: wall port → Hyperoptic router, Hyperoptic router LAN → Flint WAN. The Flint's own settings do not need to change for this. |
