# oci-gateway Tailscale exit node

`oci-gateway` advertises the IPv4 and IPv6 default routes as the fleet's on-demand Tailscale exit node. The host must keep both forwarding sysctls enabled across reboot.

## Managed host configuration

The canonical source for `/etc/sysctl.d/99-tailscale-exit-node.conf` is:

`infrastructure/oci-gateway/etc/sysctl.d/99-tailscale-exit-node.conf`

Install the file with root ownership and mode `0644`, then apply only that file:

```sh
sudo install -o root -g root -m 0644 99-tailscale-exit-node.conf /etc/sysctl.d/99-tailscale-exit-node.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale-exit-node.conf
```

Do not restart `tailscaled` or reboot the host for this change. `tailscale` already persists the exit-node advertisement in its state; verify it with `tailscale debug prefs` and require `AdvertiseRoutes` to include `0.0.0.0/0` and `::/0`.

## Verification

```sh
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
tailscale status
tailscale debug prefs
sudo ufw status verbose
```

Expected forwarding values are `1`. `tailscale status` must show `offers exit node` and must not report an IP-forwarding health warning. Preserve the existing UFW policy and Tailscale-managed netfilter/NAT rules; do not add subnet routes or public listeners.

## Rollback

```sh
sudo rm /etc/sysctl.d/99-tailscale-exit-node.conf
sudo sysctl -w net.ipv4.ip_forward=0
sudo sysctl -w net.ipv6.conf.all.forwarding=0
```

After rollback, the host must stop advertising exit-node routes with the managed Tailscale configuration path before leaving forwarding disabled.
