# The capture HTTP surface. Single-file Bun server, no dependencies — nothing to
# install, so no package.json / lockfile. Built locally (not pulled from GHCR):
# the source lives in this repo, unlike upvotes/blog which ship prebuilt images.
FROM oven/bun:1-alpine

WORKDIR /app
COPY src/ ./src/

# oven/bun's default user is uid 1000 ("bun"); compose also pins user: "1000:1000"
# so the bind-mounted /data (host-owned 1000:1000) is writable.
EXPOSE 8080
CMD ["bun", "run", "src/server.ts"]
