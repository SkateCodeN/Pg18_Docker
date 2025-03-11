# syntax=docker/dockerfile:1.4
############################
# Build Stage
############################
FROM debian:bookworm-slim AS builder

# Install prerequisites for repository management and building
RUN apt-get update && apt-get install -y \
    locales \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
 && rm -rf /var/lib/apt/lists/*

# Generate locale
RUN sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

# Add the PostgreSQL signing key (PGDG)
RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

# Add the PGDG snapshot repository for PostgreSQL 18 (for Bookworm)
RUN echo "deb https://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg-snapshot main 18" > /etc/apt/sources.list.d/pgdg.list

# Temporarily add Debian unstable to upgrade postgresql-common
RUN echo "deb http://deb.debian.org/debian unstable main" > /etc/apt/sources.list.d/unstable.list && \
    cat <<EOF > /etc/apt/preferences.d/postgresql-common
Package: postgresql-common
Pin: release a=unstable
Pin-Priority: 1001
EOF

# Update and install upgraded postgresql-common from unstable; then remove the unstable repo
RUN apt-get update && apt-get install -y postgresql-common && rm /etc/apt/sources.list.d/unstable.list

# Pin packages from PGDG to prefer snapshot versions
RUN cat <<EOF > /etc/apt/preferences.d/pgdg
Package: *
Pin: origin apt.postgresql.org
Pin-Priority: 1001
EOF

# Update package lists and install PostgreSQL 18 and its client from PGDG snapshot (omit the JIT package)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libpq5 \
    postgresql-18 \
    postgresql-client-18 \
    sysstat \
 && rm -rf /var/lib/apt/lists/*

# Archive the PostgreSQL installation directories (both binaries and shared files)
RUN tar czf /tmp/pg18.tar.gz /usr/lib/postgresql/18 /usr/share/postgresql/18

# Archive the newer libpq libraries (typically found in /usr/lib/x86_64-linux-gnu/)
RUN tar czf /tmp/libpq.tar.gz /usr/lib/x86_64-linux-gnu/libpq.so.5*

############################
# Final Stage
############################
FROM debian:bookworm-slim

# Install only the runtime dependencies needed by core PostgreSQL
RUN apt-get update && apt-get install -y \
    libreadline8 \
    libssl3 \
    zlib1g \
    libxml2 \
    libxslt1.1 \
    libc6 \
    libgcc1 \
    libstdc++6 \
    locales \
    libicu72 \
    libkrb5-3 \
    libgssapi-krb5-2 \
    libcurl4 \
 && rm -rf /var/lib/apt/lists/*

# Generate locale and set environment variables
RUN sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Set PATH to include PostgreSQL 18 binaries and LD_LIBRARY_PATH for shared libraries
ENV PATH="/usr/lib/postgresql/18/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"

# Copy and extract the PostgreSQL 18 installation from the builder stage
COPY --from=builder /tmp/pg18.tar.gz /tmp/pg18.tar.gz
RUN tar xzf /tmp/pg18.tar.gz -C / && rm /tmp/pg18.tar.gz

# Copy and extract the newer libpq libraries from the builder stage
COPY --from=builder /tmp/libpq.tar.gz /tmp/libpq.tar.gz
RUN tar xzf /tmp/libpq.tar.gz -C / && rm /tmp/libpq.tar.gz

# Update the dynamic linker cache
RUN ldconfig

# Create the postgres user and group, and prepare the data directory
RUN groupadd -r postgres && useradd -r -g postgres postgres && \
    mkdir -p /var/lib/postgresql/data && chown -R postgres:postgres /var/lib/postgresql/data

# Create /var/run/postgresql directory for lock files
RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql

EXPOSE 5432

USER postgres

# Initialize the database cluster using the full path to initdb with UTF8 encoding
RUN /usr/lib/postgresql/18/bin/initdb -D /var/lib/postgresql/data -E UTF8

# Start PostgreSQL with JIT disabled
CMD ["/usr/lib/postgresql/18/bin/postgres", "-D", "/var/lib/postgresql/data", "-c", "jit=off"]

#resolved error:
    # > [stage-1 10/10] 
    # RUN /usr/lib/postgresql/18/bin/initdb -D /var/lib/postgresql/data -E UTF8:
    # 0.504 /usr/lib/postgresql/18/bin/postgres: 
    # error while loading shared libraries:
    #      libxml2.so.2: cannot open shared object file: 
    #         No such file or directory
    # 0.506 no data was returned by command
    #     ""/usr/lib/postgresql/18/bin/postgres" -V"
    # 0.506 command not found
    # 0.506 initdb: error: program "postgres" 
    #     is needed by initdb but was not found in the 
    #     same directory as "/usr/lib/postgresql/18/bin/initdb"
    #     ------
    # ERROR: failed to solve: 
    #     process 
    #     "/bin/sh -c /usr/lib/postgresql/18/bin/initdb -D 
    #     /var/lib/postgresql/data -E UTF8" 
    #     did not complete successfully: exit code: 1