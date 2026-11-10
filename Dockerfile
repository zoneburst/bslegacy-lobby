# The Battle Spirits Saga Sim online lobby (WebSocket), for Render.
# Render builds this image from the repository and runs it; it sets $PORT.
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.5-stable
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/* \
 && wget -q https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /opt \
 && mv /opt/Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm /tmp/godot.zip

WORKDIR /game
COPY . .
# import once while building, so the server starts in seconds
RUN godot --headless --path . --import > /dev/null 2>&1 || true

ENV PORT=10000
EXPOSE 10000
CMD ["sh", "-c", "exec godot --headless --path /game -- --server --ws --port ${PORT}"]
