FROM ubuntu:22.04

LABEL maintainer="lpminer"
LABEL version="0.1.7"
LABEL description="lpminer - LuckyPool Pearl Miner for HiveOS"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    perl \
    procps \
    ca-certificates \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Working directory
WORKDIR /hive/miners/custom/lpminer

# Copy all miner files
COPY lpminer         ./lpminer
COPY crash-report.sh ./crash-report.sh
COPY h-manifest.conf ./h-manifest.conf
COPY h-config.sh     ./h-config.sh
COPY h-run.sh        ./h-run.sh
COPY h-stats.sh      ./h-stats.sh
COPY run.sh          ./run.sh

# Make scripts and binary executable
RUN chmod +x lpminer crash-report.sh h-config.sh h-run.sh h-stats.sh run.sh

# Create log directory
RUN mkdir -p /var/log/miner/custom/lpminer /run/hive /var/run

# Default entrypoint — override args at runtime
ENTRYPOINT ["./run.sh"]
CMD ["--help"]
