# catallenya

catallenya is a personal data sovereignty project. We replace third-party services with self-hosted solutions for photo management, cloud storage, calendar and contact sync, link archiving, change monitoring and blogging. Offers deep integration with scheduled backups, encryption and status notifications.

![catallenya](catallenya.png)

# Services hosted (non-exhaustive)
- [carrein-blog](https://github.com/carrein/carrein-blog)
- [upvotes](https://github.com/carrein/upvotes)
- [Immich](https://immich.app)
- [Immich Public Proxy](https://github.com/alangrainger/immich-public-proxy)
- [Zipline](https://zipline.diced.sh/)
- [Memoka](https://github.com/carrein/memoka)
- [Syncthing](https://syncthing.net/)
- [Archivebox](https://archivebox.io/)
- [Radicale](https://radicale.org/v3.html)
- [Ntfy](https://ntfy.sh/)
- [Flame](https://github.com/pawelmalak/flame)
- [Changedetection.io](https://changedetection.io/)

# Job system

Sixteen background jobs — backups, disk checks, ZFS scrubs, document filing —
run under a shared systemd contract rather than each inventing its own. Policy is
inherited in layers, an installer refuses jobs that break the contract, and a
daily watchdog asks every job whether it actually ran.

Built on one idea: a job reporting success is not the same as a job having done
its work. Design, the traps encountered, and what testing missed are in
[systemd/README.md](systemd/README.md).

A complete walkthrough of the server setup is available on [carrein-blog](https://catallenya.com/).
