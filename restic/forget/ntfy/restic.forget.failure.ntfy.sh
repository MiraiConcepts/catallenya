#!/bin/bash

service_status=$(systemctl status restic.forget.service)

curl -H "Tags: mending_heart" \
     -H "Title: Restic Forget Failure" \
     -H "Priority: high" \
     -d "$service_status" \
     "https://catallenya.kamori-mulley.ts.net:3000/restic"
