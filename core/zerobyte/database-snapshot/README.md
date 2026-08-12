# Zerobyte database snapshots

`snapshot.sh` uses SQLite `VACUUM INTO` inside the running Zerobyte container
and verifies the copy with `PRAGMA integrity_check`. The hourly systemd timer
stages root-only database snapshots below `backup-staging/zerobyte` before the
six-hour off-host Restic schedule runs.

`restore.sh` accepts only a restored `zerobyte-*.db` below the protected
restore-tests root, verifies it in an isolated container, refuses a running
Zerobyte service or existing live database, and installs it for clean-host
startup. The OpenBao snapshot must be restored first because it contains the
matching Zerobyte application secret.
