# Pinned by digest, not by :latest. A floating tag meant a rebuild could silently
# move versions — and 0.7 -> 0.9 is a one-way schema and filesystem migration.
# Currently 0.9.70. To bump deliberately:
#   docker buildx imagetools inspect archivebox/archivebox:<tag> --format '{{.Manifest.Digest}}'
# then `docker compose run --rm archivebox init` + `update --migrate-only` on the new image.
FROM archivebox/archivebox@sha256:8c21bb233130d86963e2ffab143264dfb8908c966a12a00f2180bb88e6f6305a

# Deliberately NOT pinned. yt-dlp breaks whenever a site changes its player, so a
# pinned version degrades to "downloads silently fail" within weeks. Currency is
# the point here — the opposite trade-off from the base image above.
# 0.9 has no pip on PATH and runs yt-dlp from its own abxpkg-managed venv, so that
# is the copy upgraded. If upstream moves the venv, this RUN fails the build loudly.
RUN uv pip install --python /opt/archivebox/lib/uv/packages/yt-dlp/venv/bin/python --upgrade yt-dlp
