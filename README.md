# Easy ACA NFS diagnostics

Customer-runnable tooling for intermittent Azure Files NFS mount failures in Azure Container Apps Jobs.

The repository provides three complementary workflows:

1. **Export a safe support bundle** with job, workload profile, NFS volume, environment storage, and recent execution metadata.
2. **Create and run a manual ACA probe job** that preserves a source job's workload profile, CPU/memory, NFS volume, mount options, and mount path without running the business workload.
3. **Capture a clean first mount on a customer-controlled Linux host** using Microsoft's canonical NFS client collector.

## Guided one-command workflow

For the normal customer path, put the affected ACA Job resource IDs in `jobs.txt`, one per line, and run:

```powershell
pwsh .\scripts\Start-AcaNfsDiagnostics.ps1 `
  -JobResourceId (Get-Content .\jobs.txt)
```

The guided command:

1. validates Azure CLI authentication;
2. installs or updates the Container Apps CLI extension;
3. exports a baseline support bundle;
4. creates a manual probe from the first listed job;
5. runs three probe executions and records exact UTC timestamps;
6. exports a final bundle containing both source and probe configuration;
7. writes `RUN-SUMMARY.txt` with artifact paths and the explicit cleanup command.

Use a different listed job as the probe template when needed:

```powershell
pwsh .\scripts\Start-AcaNfsDiagnostics.ps1 `
  -JobResourceId (Get-Content .\jobs.txt) `
  -ProbeSourceJobResourceId "<job-resource-id>"
```

The probe remains deployed for additional reproduction attempts. Nothing deletes it automatically.

With the defaults, allow roughly 10-15 minutes for three sequential 180-second probe executions, plus any time needed for the workload-profile node to scale from zero.

## Important diagnostic boundary

Azure Container Apps mounts the NFS volume on the managed host before starting the container. ACA does not expose the host and does not support privileged containers with host-level access. Therefore:

- The ACA probe accurately reproduces the platform mount path and records whether the container can start.
- The support bundle captures the customer-visible configuration and exact execution timestamps.
- `nfsclientlogs.sh`, kernel traces, blocked `mount.nfs` stacks, and host packet capture **cannot be collected from inside an ACA container**. Run the Linux capture on a fresh customer-controlled VM or AKS node in the same network path, or ask Microsoft support to capture the affected ACA node.

See [docs/diagnostic-boundary.md](docs/diagnostic-boundary.md) for details.

## Prerequisites

- PowerShell 7
- Azure CLI with the Container Apps extension
- Reader access to inspect jobs and environments
- Contributor access to create a probe job

```powershell
az login
az extension add --name containerapp --upgrade
```

## 1. Export a support bundle

The sections below describe the individual commands used by the guided workflow. Use them when you need more control.

Pass one or more complete ACA Job resource IDs:

```powershell
$jobs = Get-Content .\jobs.txt

pwsh .\scripts\Export-AcaNfsSupportBundle.ps1 `
  -JobResourceId $jobs
```

The generated ZIP contains an allowlisted JSON summary. Secret values, registry credentials, and environment variable values are not exported.

## 2. Create an ACA NFS probe

Create a manual probe from one affected source job:

```powershell
pwsh .\scripts\New-AcaNfsProbeJob.ps1 `
  -SourceJobResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.App/jobs/<source-job>" `
  -ProbeJobName "<source-job>-nfs-probe"
```

The probe:

- stays in the same ACA environment;
- uses the same workload profile;
- copies the selected source container's CPU and memory;
- copies one `NfsAzureFile` volume, including `storageName`, `mountOptions`, mount path, and `subPath`;
- uses a manual trigger, one replica by default, and no application secrets;
- uses the public Azure Linux base image and performs read-only checks against the mounted path.

If the environment blocks pulls from public MCR, pass `-Image` with an approved image that contains `/bin/sh` and standard core utilities.

If the source job has more than one NFS volume or several containers, select them explicitly:

```powershell
pwsh .\scripts\New-AcaNfsProbeJob.ps1 `
  -SourceJobResourceId "<job-resource-id>" `
  -ProbeJobName "<probe-name>" `
  -VolumeName "<volume-name>" `
  -ContainerName "<container-name>"
```

Review the generated `*.request.json` file before creation. The script does not start or delete the probe.

## 3. Run and record the probe

```powershell
pwsh .\scripts\Invoke-AcaNfsProbe.ps1 `
  -ProbeJobResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.App/jobs/<probe-job>" `
  -Executions 3
```

The command records UTC start times and execution status in a ZIP bundle. A mount failure can prevent the probe container from starting; that is a valid reproduction signal.

Export a final support bundle containing both the source and probe job:

```powershell
pwsh .\scripts\Export-AcaNfsSupportBundle.ps1 `
  -JobResourceId "<source-job-resource-id>","<probe-job-resource-id>"
```

## 4. Capture a clean first mount on Linux

Use a fresh or newly rebooted customer-controlled Linux VM or AKS node that can reach the Azure Files endpoint on TCP 2049.

```bash
sudo ./scripts/Run-NfsClientCapture.sh \
  --server mystorage.file.core.windows.net \
  --export /mystorage/myshare \
  --mount-options vers=4.1,sec=sys \
  --install-dependencies
```

The wrapper starts network and kernel tracing before the first mount, attempts the mount with a timeout, and creates the canonical `output_<timestamp>.zip` bundle. Packet captures can contain file names and protocol metadata; transfer the ZIP only through the secure channel associated with the support case.

### Capture timing is critical

The packet capture and kernel trace cannot be reconstructed after the mount attempt. They must be running before the mount starts:

```text
Fresh or rebooted host
  -> start packet and kernel tracing
  -> trigger the first NFS mount
  -> preserve the failed or successful state
  -> stop tracing and create the ZIP
```

`Run-NfsClientCapture.sh` performs this sequence on a customer-controlled Linux host. If running the upstream collector manually, use the same working directory for `start` and `stop`:

```bash
sudo ./nfsclientlogs.sh v4 start CaptureNetwork
# Reproduce the mount.
sudo ./nfsclientlogs.sh stop
```

Running only `stop` after a failure produces an incomplete bundle because no packet or kernel trace was active during the original mount.

### What remains available after a run

If the same node is preserved and has not rebooted, some evidence can still be collected immediately after the run:

- `dmesg` since the last reboot, subject to ring-buffer rotation;
- OS, distribution, and kernel details;
- current NFS client and RPC statistics;
- current TCP 2049 socket state;
- CSI/node logs that have not rotated;
- the blocked `mount.nfs` process state and kernel wait channel, but only while the process is still present.

The following cannot be recovered retroactively:

- `nfs_traffic.pcap`;
- the `trace-cmd` NFS trace;
- a clean first-mount capture;
- process stacks after the blocked process exits;
- any node evidence after the node is scaled down, replaced, or rebooted.

For a mount that is still hanging, preserve the node before draining or replacing it and collect:

```bash
date -u
getent hosts mystorage.file.core.windows.net
nc -vz mystorage.file.core.windows.net 2049
ps -eo pid,stat,wchan:32,cmd | grep '[m]ount.nfs'
ss -tanp | grep ':2049'
cat /proc/net/rpc/nfs
dmesg -T | tail -500
```

These post-failure commands are valuable, but they do not replace a packet capture and kernel trace that began before the mount.

### Capturing the actual ACA node

The customer cannot run these host commands from an ACA Job container. If the probe reproduces a mount timeout:

1. Record the probe execution name and exact UTC start time.
2. Do not delete the probe job.
3. Contact Microsoft support immediately and ask them to preserve the managed node before scale-down or replacement.
4. Ask support to collect the blocked `mount.nfs` stack/`wchan`, `dmesg`, NFS/RPC state, and a retry capture from the affected node.

A capture from a customer-controlled VM or AKS node is a useful reference capture, but it is not a substitute for the affected ACA node's state.

## Explicit cleanup

Probe jobs are not deleted automatically. Remove one only when it is no longer needed:

```powershell
pwsh .\scripts\Remove-AcaNfsProbeJob.ps1 `
  -ProbeJobResourceId "<probe-job-resource-id>"
```

## What to send Microsoft support

See [docs/support-checklist.md](docs/support-checklist.md).

## Upstream collector

The files under `vendor/NfsDiagnostics` are copied from the Microsoft `Azure-Samples/azure-files-samples` repository and pinned to the commit documented in [vendor/NfsDiagnostics/UPSTREAM.md](vendor/NfsDiagnostics/UPSTREAM.md).
