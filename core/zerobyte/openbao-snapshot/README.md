# OpenBao snapshot recovery

These scripts create native OpenBao Raft snapshots, stage them for Zerobyte and
verify restores in isolation. `disaster-restore.sh` can open the Azure Restic
repository directly on a clean host without Zerobyte's local database.

The systemd unit and timer run the snapshot producer hourly. Credentials and
recovery keys remain in protected host files outside Git. `bootstrap.sh` also
creates the root-only host staging directory and container-side scratch
directory required on a clean VM before systemd applies its filesystem
namespace restrictions.
