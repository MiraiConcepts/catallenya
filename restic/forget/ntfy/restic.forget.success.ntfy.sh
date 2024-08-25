#!/bin/bash

service_status=$(systemctl status restic.forget.service)

curl -H "Tags: green_heart" \
     -H "Title: Restic Forget Success" \
     -d "$service_status" \
     "https://catallenya-sev.REDACTED.ts.net:3000/restic"
