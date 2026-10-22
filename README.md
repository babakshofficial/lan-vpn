# LAN VPN

Share the network your Linux computer is on with one client. The script installs WireGuard and writes a client config. The tunnel stays up, including after a reboot, until you turn it off.

Run it on the computer that is on that network. A cloud shell cannot see your LAN, and a VPN started somewhere else will not let your client reach your machines.

## Start it

On the Linux computer that is on your network (Debian, Ubuntu, Fedora, Arch, or openSUSE), download the script and start it:

```bash
curl -fsSL https://raw.githubusercontent.com/babakshofficial/lan-vpn/main/scripts/oneday-vpn.sh -o oneday-vpn.sh
sudo bash oneday-vpn.sh setup
```

That installs the `oneday-vpn` command. Later commands do not need the downloaded file:

```bash
sudo oneday-vpn status
sudo oneday-vpn show
sudo oneday-vpn down
```

`status` shows whether the client has connected. `show` prints the client config again. `down` turns the VPN off. The tunnel stays up, including after a reboot, until `down`.

If you started an older copy that scheduled its own shutdown, cancel that timer and leave the VPN up:

```bash
sudo bash oneday-vpn.sh down --expired
```

The script prints the client file, `oneday-client.conf`, in your home directory, and the router step when your computer is behind a home router.

Forward **UDP 51820** on the router to this computer's LAN address. The script prints that address and the router's usual admin URL. External port and internal port are both 51820. The protocol is UDP.

Send these two files to your client through a private chat. The `.conf` file is the connection. Anyone who has it can enter the network until you turn the VPN off.

- `oneday-client.conf`
- `oneday-client-howto.txt`

A recent handshake in `sudo oneday-vpn status` means their tunnel is up. They should be able to `ping` this computer's LAN address and open other devices on the same subnet.

If this network belongs to an employer, get permission first. Many workplaces forbid a personal VPN into the office.

## What the client does

1. Install WireGuard from https://www.wireguard.com/install/ (Windows, Mac, Linux), the App Store (iPhone), or the Play Store (Android).
2. Import `oneday-client.conf`.
   - Windows or Mac: **Add Tunnel**, then **Import tunnel(s) from file**.
   - iPhone or Android: tap **+**, then scan the QR code the script printed or import the file.
   - Linux: `sudo wg-quick up ./oneday-client.conf`
3. Turn the tunnel on.
4. Ping the server's LAN address from the howto file.

The default tunnel only routes your LAN. The client's other internet traffic stays on their own connection.

The config looks like this. The real file has generated keys and your public address.

```ini
[Interface]
PrivateKey = (generated)
Address = 10.77.0.2/32

[Peer]
PublicKey = (generated)
PresharedKey = (generated)
Endpoint = YOUR_PUBLIC_IP:51820
AllowedIPs = 192.168.1.0/24, 10.77.0.0/24
PersistentKeepalive = 25
```

## If the client must appear to be on your internet

Some work tools only accept your office or home public address. That needs a full tunnel. All of the client's internet traffic then goes through your computer, using your bandwidth.

```bash
sudo bash oneday-vpn.sh setup --full-tunnel
```

## If the script says the public address is not reachable

Home connections often use carrier-grade NAT. The computer has no address a remote client can dial, so a UDP port forward never answers. The script stops without starting WireGuard and tells you to use Tailscale:

```bash
sudo bash oneday-vpn.sh tailscale
```

Open the login URL it prints, then approve the LAN route at https://login.tailscale.com/admin/machines for the machine named `oneday-vpn`.

The client installs Tailscale from https://tailscale.com/download and signs in with the same account. After the route is approved they can reach your LAN subnet. The route stays advertised until you run `sudo oneday-vpn down`.

Every device already on that Tailscale account can use the route once you approve it. Use an account you control.

### Windows or Mac as the server

The script targets Linux. On Windows or Mac, use Tailscale:

1. Install Tailscale and sign in.
2. Find the LAN subnet in the computer's network settings, for example `192.168.1.0/24`.
3. In an administrator terminal:

   ```bash
   tailscale up --advertise-routes=192.168.1.0/24
   ```

   On Windows the program is `C:\Program Files\Tailscale\tailscale.exe`.
4. Approve the route at https://login.tailscale.com/admin/machines.
5. The client signs in to the same account and turns Tailscale on.
6. When the work is done, disconnect and clear the route:

   ```bash
   tailscale set --advertise-routes=
   tailscale down
   ```

## If the LAN subnet is wrong

The script shares the subnet on the interface that has the default route. Override it when that guess is too small (a `/32`) or is the wrong VLAN:

```bash
sudo bash oneday-vpn.sh setup --lan-cidr 192.168.1.0/24
```

`--replace` rebuilds the VPN and invalidates the previous client file.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| WireGuard shows no handshake | The router is not forwarding UDP 51820 to this computer, or the public IP changed. Run setup again and send the new file. |
| Handshake is recent, ping fails | The target PC's firewall is blocking other LAN devices. Ping this computer's own LAN address first. |
| Setup says the public address is private or `100.64.x.x` | Run the Tailscale command above. |
| The client is on a network that blocks UDP | Use Tailscale. It can relay over HTTPS when UDP is blocked. |
| This computer already runs Docker | The generated rules also allow the tunnel through Docker's firewall chain. |

## Safety

- One client, one subnet. It stays up until you stop it.
- `sudo oneday-vpn down` deletes the server peer and the client file stored on this computer. The copy you already sent stops working because the server no longer accepts it.
- The client can reach this computer and the other devices on the shared subnet, including SSH if SSH is open to the LAN.

## Tests

The dry run writes configs under `dry-run-out/` and does not open a VPN:

```bash
bash scripts/test-dry-run.sh
```
