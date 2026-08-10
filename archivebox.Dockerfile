# Pinned by digest, not by :latest. This image and the archivebox_scheduler
# service share /data including index.sqlite3, and a newer ArchiveBox on one side
# can migrate that schema ahead of the other. A floating tag meant a rebuild could
# silently move versions; both are currently 0.7.4 (COMMIT_HASH=3830544).
# To bump deliberately, and in lockstep with the scheduler's image:
#   docker buildx imagetools inspect archivebox/archivebox:latest --format '{{.Manifest.Digest}}'
FROM archivebox/archivebox@sha256:1a5a37331091d9df865ead2b9c231aa5a892fc26fe0422ce6140d9e2d9532327

# Deliberately NOT pinned. yt-dlp breaks whenever a site changes its player, so a
# pinned version degrades to "downloads silently fail" within weeks. Currency is
# the point here — the opposite trade-off from the base image above.
RUN pip install --upgrade yt-dlp
