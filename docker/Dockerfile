FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jre \
    xvfb \
    xdotool \
    scrot \
    libgtk-3-0 \
    xdg-utils \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_TOOL_OPTIONS="-Djava.awt.headless=false"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 58870
ENTRYPOINT ["/entrypoint.sh"]
