# Start with the official ArchiveBox image
FROM archivebox/archivebox:latest

# GITLEAKS TEST: Add a fake private key as an environment variable
ENV FAKE_API_KEY="-----BEGIN RSA PRIVATE KEY-----
THISISAFANTASTICALLYFAKETESTKEYFORGITLEAKS1234567890ABCDEF
-----END RSA PRIVATE KEY-----"

# Install the latest version of yt-dlp
RUN pip install --upgrade yt-dlp