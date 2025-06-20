#!/bin/bash

service_status=$(systemctl status restic.backup.service)

curl -H "Tags: green_heart" \
     -H "Title: Restic Backup Success" \
     -d "$service_status" \
     "https://catallenya.kamori-mulley.ts.net:3000/restic"
