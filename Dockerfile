FROM ubuntu:22.04

LABEL maintainer="lpminer"
LABEL version="0.1.7"
LABEL description="lpminer - LuckyPool Pearl Miner"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget jq perl procps ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /miner

COPY lpminer         ./lpminer
COPY crash-report.sh ./crash-report.sh
COPY h-manifest.conf ./h-manifest.conf
COPY h-config.sh     ./h-config.sh
COPY h-run.sh        ./h-run.sh
COPY h-stats.sh      ./h-stats.sh
COPY run.sh          ./run.sh

RUN chmod +x lpminer crash-report.sh h-config.sh h-run.sh h-stats.sh run.sh
RUN mkdir -p /var/log/miner /run/hive /var/run

COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x docker-entrypoint.sh

ENTRYPOINT ["./docker-entrypoint.sh"]
