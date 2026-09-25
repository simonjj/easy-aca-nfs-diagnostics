# Diagnostic boundary

## Why the host collector cannot run in ACA

For an ACA Job with an Azure Files NFS volume, the managed platform mounts the share before it starts the workload container. If the host mount blocks, the container never starts.

Microsoft's `nfsclientlogs.sh` collector needs host capabilities and data, including:

- kernel NFS tracepoints through `trace-cmd`;
- host `dmesg`;
- host NFS mount and RPC state;
- process kernel stacks under `/proc`;
- packet capture for the host's TCP 2049 connection.

Azure Container Apps does not provide node access or privileged containers with host-level access. Running the collector in an ordinary sidecar or probe container would capture the container namespace after a successful mount, not the managed host state during the failed mount.

Official references:

- [Containers in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/containers)
- [Use storage mounts in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/storage-mounts)
- [Jobs in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/jobs)

## What each workflow proves

| Workflow | What it captures | What it does not capture |
|---|---|---|
| ACA probe job | Same environment, workload profile, host-managed NFS volume, mount options, mount path, CPU/memory, and exact execution time | Host kernel trace, host packet capture, blocked `mount.nfs` stack |
| ACA support bundle | Allowlisted job/environment/storage configuration and recent execution metadata | Secret values and internal platform node state |
| Fresh Linux capture | Clean NFSv4.1 mount packet capture, kernel trace, OS/kernel details, NFS stats | The state of the inaccessible ACA node |
| Microsoft platform capture | Actual affected ACA node state | Customer-runnable without support involvement |

## Recommended sequence

1. Export the source job support bundle.
2. Create a manual probe from an affected job and run several executions.
3. Record exact UTC execution names and times.
4. If requested by the Files team, run a clean first-mount capture on a fresh Linux host in the same VNet path.
5. Give Microsoft support the two ZIP files and ask them to correlate the probe timestamps with the affected ACA node.

Do not treat a successful VM capture as proof that the ACA host is healthy. It is a reference capture for client, mount, network, and protocol comparison.
