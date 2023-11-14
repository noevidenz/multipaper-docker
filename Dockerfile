#syntax=docker/dockerfile:1.4
FROM --platform=$BUILDPLATFORM gradle:latest as build

WORKDIR /app

# Config a git user for the build process
RUN <<EOT
    git config --global user.name "Automated build"
    git config --global user.email "build@example.com"
EOT

# If the repo is updated, the request body will change which should invalidate cache for the next step`
ADD https://api.github.com/repos/MultiPaper/MultiPaper/git/refs/heads/main version.json
# Clone the repo
RUN git clone https://github.com/MultiPaper/MultiPaper.git

# CD into the new repo
WORKDIR /app/MultiPaper
# Multipaper build process
RUN <<EOT
    ./gradlew applyPatches
    ./gradlew shadowjar createReobfPaperclipJar

    MULTIPAPER_VERSION=$(gradle properties | grep version | awk '{print $NF}')
    MULTIPAPER_MASTER_VERSION=$(gradle MultiPaper-Master:properties | grep version | awk '{print $NF}')
    
    # Move build artifacts to more accessible place
    mkdir /artifacts

    # Discarded version numbers for easy copying later on
    mv LICENSE.txt /artifacts/multipaper-license.txt
    mv build/libs/MultiPaper-paperclip-$MULTIPAPER_VERSION-reobf.jar /artifacts/multipaper.jar
    mv MultiPaper-Master/LICENSE.txt /artifacts/multipaper-master-license.txt
    mv MultiPaper-Master/build/libs/MultiPaper-Master-$MULTIPAPER_MASTER_VERSION-all.jar /artifacts/multipaper-master.jar
EOT

# CD into a new directory to run the jars
WORKDIR /app/multipaper-config

# Run the jars to generate some files
RUN <<EOT bash
    # Start the server once to download the mojang_*.jar
    grep -m 1 "Applying patches" <(java -jar /artifacts/multipaper.jar)

    # Start the mojang server once to generate eula.txt
    java -jar ./cache/mojang_*.jar

    # Move the eula to /artifacts
    mv eula.txt /artifacts
EOT


# Create a shared base container
FROM eclipse-temurin:21-jre as base

RUN useradd -d /app -s /bin/false multipaper
USER multipaper
WORKDIR /app


# Build the MultiPaper-Master container
FROM base as master

COPY --from=build --chown=multipaper:multipaper /artifacts/multipaper-master-license.txt /opt/multipaper-master/LICENSE.txt
COPY --from=build --chown=multipaper:multipaper /artifacts/multipaper-master.jar /opt/multipaper-master/multipaper-master.jar

ENTRYPOINT [ "java", "-jar", "/opt/multipaper-master/multipaper-master.jar" ]
CMD [ "35353", "25565" ]

EXPOSE 35353/tcp 25565/tcp
VOLUME [ "/app" ]


# Build the Multipaper server container
FROM base as server

# Create an entry script based on akiicat/MultiPaper-Container
COPY --chown=multipaper:multipaper --chmod=744 <<-"EOT" /opt/multipaper/entry.sh
#!/usr/bin/env bash
# Make sure the config files exist
if [[ -f "/opt/multipaper/eula.txt" && ! -f "/app/eula.txt" ]]; then
    echo "Copying eula.txt"
    cp "/opt/multipaper/eula.txt" "/app/eula.txt"
fi
# If the EULA environment variable is true, accept it
if [[ -n "$EULA" ]]; then
    echo "Accepting the EULA..."
    sed -i "s/eula=.*$/eula=$EULA/g" eula.txt
fi
# Run the MultiPaper Server jar file
java -jar $@
EOT
COPY --from=build --chown=multipaper:multipaper /artifacts/multipaper-license.txt /opt/multipaper/LICENSE.txt
COPY --from=build --chown=multipaper:multipaper /artifacts/eula.txt /opt/multipaper/eula.txt
COPY --from=build --chown=multipaper:multipaper /artifacts/multipaper.jar /opt/multipaper/multipaper.jar

ENTRYPOINT [ "/opt/multipaper/entry.sh", "/opt/multipaper/multipaper.jar" ]
CMD [ "--max-players=30" ]

EXPOSE 25565/tcp
VOLUME [ "/app" ]