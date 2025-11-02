# catallenya
A project aimed at retaining personal data sovereignty, by replacing third-party services with self-hosted solutions for photo management, cloud storage, calendar and contact sync and blogging. Offers deep integration with scheduled backups, encryption and status notifications.

### Blog
https://catallenya.com/tag/self-hosted/

### Notes
1. Cloudflare proxy only allows for a maximum of [100 MB](https://developers.cloudflare.com/workers/platform/limits/) uploads. Be aware when attempting to upload files to service exposed through cloudflared tunnels i.e. Ghost blog.
2. Uploading videos to Ghost through LibreWolf yields: `Argument 1 is not valid for any of the 1-argument overloads. Use an alternate browser to upload videos.`
3. ~~The latest Ubuntu 24.04 LTS is not yet supported. Docker Desktop will fail to start. Due to a change in how the latest Ubuntu release restricts the unprivileged namespaces, `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` needs to be run at least once.~~ Resolved with [Docker Desktop 4.35.0 release](https://docs.docker.com/desktop/release-notes/#4350).
