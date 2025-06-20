#!/bin/bash

service_status=$(systemctl status restic.check.service)

curl -H "Tags: green_heart" \
     -H "Title: Restic Check Success" \
     -d "$service_status" \
     "https://catallenya.kamori-mulley.ts.net:3000/restic"
