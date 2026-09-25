# Support handoff checklist

Provide the following through the secure channel associated with the support case:

- The ZIP from `Export-AcaNfsSupportBundle.ps1`.
- The ZIP from `Invoke-AcaNfsProbe.ps1`.
- The source job resource ID and probe job resource ID.
- The exact failing and successful execution names and UTC timestamps.
- Whether the failure is intermittent or repeatable.
- When the behavior was first observed and whether it is a regression.
- The `output_<timestamp>.zip` from `Run-NfsClientCapture.sh`, if Microsoft requested a clean first-mount capture.

For an active ACA mount failure, ask support to preserve and inspect the actual managed node before it is replaced. The most useful node-side artifacts are:

- the blocked `mount.nfs` process state and kernel wait channel;
- `dmesg`;
- NFS/RPC socket state;
- a TCP 2049 packet capture;
- the canonical `nfsclientlogs.sh` bundle.

## Data handling

- The PowerShell support bundle does not include secret values.
- A packet capture can contain file names, IP addresses, and NFS protocol metadata.
- Review diagnostic archives before sharing them.
- Do not attach captures to a public GitHub issue.
