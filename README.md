# cimc-kvm

cimc-kvm is a native macOS app for the Cisco Integrated Management Controller (CIMC) HTML5 KVM console. It supports direct connections, SOCKS5 proxies, and SSH jump hosts.

## Install

Open **Releases** in this repository and download the macOS Universal ZIP. Move the extracted `cimc-kvm.app` to **Applications** and open it in Finder. The release supports macOS 14 or later on Apple Silicon and Intel Macs. The app is signed with Developer ID and notarized by Apple.

To run from source, install Xcode or the Xcode Command Line Tools and run these commands from the repository root.

```sh
swift test
./run.sh
```

## Connect to a CIMC

The host list starts empty on a fresh installation. Click the **+** button to add a profile, select it in the list, and connect. Existing profiles are stored locally and remain available when you upgrade.

| Setting | Behavior |
| --- | --- |
| CIMC host | IP address or hostname of the CIMC management interface. |
| CIMC username | Optional. The app fills it in on the CIMC login page. |
| Connection route | Direct, SOCKS5, or SSH jump host. |
| Ignore certificate errors | Off by default. When enabled, the exception applies to the selected CIMC host on HTTPS ports 443 and 2068. |
| Show CIMC management after login | Off by default. The app opens the KVM viewer after CIMC login when the firmware exposes a launch button it recognizes. |

Enter your CIMC password on the login page. If the management page remains visible, use **Launch vKVM**. Some CIMC versions show a vKVM certificate confirmation page before opening the viewer. Follow the link to the viewer once the certificate is accepted. If the viewer displays a Dojo debug panel, the app closes it automatically.

The app stores profiles and usernames locally. It prompts for a SOCKS5 proxy password when a proxy username is set. Passwords are entered for each connection and the app does not store them in Keychain.

## Connect through SSH

### SSH key or agent

Select the SSH jump-host route and enter an alias from `~/.ssh/config` or a destination in the form `user@host`. The built-in tunnel uses macOS OpenSSH in batch mode and requires a verified jump-host key in OpenSSH's known-hosts file. Establish and verify the jump-host key in Terminal before using the app. If your private key is encrypted, load it into an SSH agent accessible to the app.

### SSH username and password

For a jump host that requires a password or an interactive authentication prompt, open a loopback SOCKS5 tunnel in Terminal and complete the prompts there. Replace the destination with your SSH username and jump host or use your SSH configuration alias.

```sh
ssh -N -D 127.0.0.1:1080 -o ExitOnForwardFailure=yes user@jump.example.com
```

Keep the command running while using the KVM. In the app, choose **SOCKS5**, set the proxy to `127.0.0.1` on port `1080`, and leave the proxy username empty. OpenSSH handles authentication to the jump host. CIMC login still takes place in the app. Stop the tunnel with Ctrl-C after closing the connection. The jump host must allow TCP forwarding to reach the CIMC. [OpenSSH manual](https://man.openbsd.org/ssh.1#D)

## Keep a KVM session active

The app keeps the Mac from automatically sleeping while a KVM window is open. The display can still turn off. The connection menu provides a toggle for this behavior. While enabled, the app also sends a read-only request from the authenticated CIMC page every 30 seconds to reduce Web session idle timeouts. Sign in again if the CIMC session expires.

Closing the app or a KVM-only connection signs out of the KVM and CIMC sessions before stopping the app-managed tunnel. In management mode, closing the KVM window signs out of the viewer and returns to the CIMC page. Sleep, closing the Mac lid, or a network interruption can disrupt KVM and virtual media.

## Recover from a CIMC session limit

When CIMC reports that its Web session limit has been reached, the app opens a session management window. You can also open it from the connection menu before launching the KVM viewer.

1. Enter your CIMC administrator username and password to list sessions. The app connects to the CIMC SSH CLI on TCP port 22 using the profile's route. If asked to trust a CIMC SSH host key, verify the displayed fingerprint first. The app keeps accepted CIMC SSH host keys in `~/Library/Application Support/CIMCKVM/ssh_known_hosts`.
2. Select the session to disconnect. The app refreshes the list and disconnects the selected session only if its details still match.
3. Reconnect to close the recovery CLI and reopen the CIMC login page.

Recovery requires an available CIMC SSH session and working TCP connectivity. The CLI uses a separate session limit from the Web UI. [Cisco IMC CLI configuration guide](https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/c/sw/cli/config/guide/4_3/b_cisco_ucs_c-series_cli_configuration_guide_43/b_Cisco_UCS_C-Series_CLI_Configuration_Guide_41_chapter_0111.html)

## Compatibility

The app uses the HTML5 viewer served by CIMC. It starts the viewer after Web authentication. Firmware must provide an HTML5 KVM, and routed connections must allow traffic to the CIMC Web UI and KVM service.
