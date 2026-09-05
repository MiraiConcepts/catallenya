# catallenya

catallenya is a self-hosted service platform for personal data sovereignty.

![catallenya](catallenya.png)

# Capabilities

catallenya replaces third-party cloud services with self-hosted equivalents on a
single storage-backed server, orchestrated through containers and reached over a
private mesh network.

- Photo management, file sync, calendar and contact sync, link archiving, change
  monitoring, notifications and blogging all run as containers on one host.
- Services are reached over a private mesh network with automatic TLS. One site
  is published to the public internet through a tunnel, and nothing else listens
  beyond the mesh.
- Backups run nightly to encrypted offsite storage, with scheduled integrity
  passes that read the archive back rather than trusting that it exists.
- Background jobs inherit their policy from layered drop-ins. An installer
  refuses any job that breaks the contract, and a daily watchdog asks every job
  whether it actually ran.
- Notifications from every job share one transport and one grammar, so a message
  from any part of the system reads like a message from any other.
- Documents and screenshots dropped into a synced folder are classified by a
  model and filed on approval. Nothing is filed without a tap.
- Music requested by name is downloaded, separated into stems and published back
  to every synced device.
- Disk wear, pool capacity, container health and snapshot freshness are each
  measured on a schedule, and an off-box switch reports the one case this machine
  cannot report itself: going silent.
