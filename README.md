# catallenya-sev-2

1. Cloudflare proxy only allows for a maximum of [100 MB](https://developers.cloudflare.com/workers/platform/limits/) uploads. Be aware when attempting to upload files to service exposed through cloudflared tunnels i.e. Ghost blog.
2. Uploading videos to Ghost through LibreWolf yields: Argument 1 is not valid for any of the 1-argument overloads. Use an alternate browser to upload videos.
3. The latest Ubuntu 24.04 LTS is not yet supported. Docker Desktop will fail to start. Due to a change in how the latest Ubuntu release restricts the unprivileged namespaces, `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` needs to be run at least once. 