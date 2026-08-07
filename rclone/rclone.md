# Configuration file is stored at (modify .bashrc to source):
```
/zpool/catallenya/rclone/.rclone.conf
```
# Access restic snapshots:
```
restic -r rclone:backblaze:catallenya-b2 snapshots
```
# Restore restic backup:
```
restic -r rclone:backblaze:catallenya-b2 restore XXXXXX --target /zpool/restored
```
# Editing this file: it does NOT end with a newline.
A naive append lands on the end of the `key = ` line and silently corrupts the
B2 credential — `rclone config show` still prints, so the damage is invisible
until an operation fails auth. Append with a leading newline, then verify with
`rclone lsd backblaze:` (a live call, so it proves the key survived):
```
printf '\n%s\n' 'option = value' >> /zpool/catallenya/rclone/.rclone.conf
```
# `hard_delete = true` is set on `[backblaze]` (2026-08-07).
It does nothing for restic, which passes `--b2-hard-delete` to its own
`rclone serve restic` child regardless. It only makes a hand-typed
`rclone delete` a real delete instead of a recoverable hide. Background,
evidence and the rejected alternatives are in CLAUDE.md § Backup System.