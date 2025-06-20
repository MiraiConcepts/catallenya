#!/bin/bash

service_status=$(systemctl status restic.backup.service)

curl -H "Tags: mending_heart" \
     -H "Title: Restic Backup Failure" \
     -H "Priority: high" \
     -d "$service_status" \
     "https://catallenya.kamori-mulley.ts.net:3000/restic"
