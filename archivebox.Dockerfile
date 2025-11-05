# Start with the official ArchiveBox image
FROM archivebox/archivebox:latest

# Install the latest version of yt-dlp
RUN pip install --upgrade yt-dlp