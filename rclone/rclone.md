# Configuration file is stored at (modify .bashrc to source):
```
/zpool/catallenya/.rclone.conf
```
# Access restic snapshots:
```
restic -r rclone:backblaze:catallenya-b2 snapshots
```
# Restore restic backup:
```
restic -r rclone:backblaze:catallenya-b2 restore XXXXXX --target /zpool/restored
```