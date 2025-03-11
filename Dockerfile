# syntax=docker/dockerfile:1.4
############################
# Builder Stage
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
RUN echo "deb https://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg-snapshot main 18" \
    > /etc/apt/sources.list.d/pgdg.list

# Temporarily add Debian unstable to upgrade postgresql-common
RUN echo "deb http://deb.debian.org/debian unstable main" > /etc/apt/sources.list.d/unstable.list && \
    cat <<EOF > /etc/apt/preferences.d/postgresql-common
Package: postgresql-common
Pin: release a=unstable
Pin-Priority: 1001
EOF

# Update and install upgraded postgresql-common from unstable; then remove unstable repo
RUN apt-get update && apt-get install -y postgresql-common && rm /etc/apt/sources.list.d/unstable.list

# Pin packages from PGDG to prefer snapshot versions
RUN cat <<EOF > /etc/apt/preferences.d/pgdg
Package: *
Pin: origin apt.postgresql.org
Pin-Priority: 1001
EOF

# Update package lists and install PostgreSQL 18 and its client (omit the JIT package)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libpq5 \
    postgresql-18 \
    postgresql-client-18 \
    sysstat \
 && rm -rf /var/lib/apt/lists/*

# Archive the PostgreSQL installation directories (binaries and shared files)
RUN tar czf /tmp/pg18.tar.gz /usr/lib/postgresql/18 /usr/share/postgresql/18

# Copy the newer libpq libraries from PGDG.
# Instead of archiving, copy them directly to /tmp for easier placement.
RUN cp /usr/lib/x86_64-linux-gnu/libpq.so.5* /tmp/

############################
# Final Stage (Minimal Runtime)
############################
FROM debian:bookworm-slim

# Install only the essential runtime dependencies for core PostgreSQL
RUN apt-get update && apt-get install -y \
    locales \
    libreadline8 \
    libssl3 \
    zlib1g \
    libc6 \
    libgcc1 \
    libstdc++6 \
    libicu72 \
    libkrb5-3 \
    libgssapi-krb5-2 \
    libcurl4 \
    libxml2 \
 && rm -rf /var/lib/apt/lists/*

# Generate locale and set environment variables
RUN sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Set PATH so that PostgreSQL 18 binaries are found
ENV PATH="/usr/lib/postgresql/18/bin:${PATH}"

# Set LD_LIBRARY_PATH to include our custom libpq location
ENV LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH}"

# Copy and extract the PostgreSQL 18 installation from the builder stage
COPY --from=builder /tmp/pg18.tar.gz /tmp/pg18.tar.gz
RUN tar xzf /tmp/pg18.tar.gz -C / && rm /tmp/pg18.tar.gz

# Copy the newer libpq libraries from the builder stage into /usr/local/lib
COPY --from=builder /tmp/libpq.so.5* /usr/local/lib/

# Update the dynamic linker cache
RUN ldconfig

# Create the postgres user and group (if not already present) and set up the data directory
RUN groupadd -r postgres && useradd -r -g postgres postgres && \
    mkdir -p /var/lib/postgresql/data && chown -R postgres:postgres /var/lib/postgresql/data

# Create /var/run/postgresql for lock files and set proper permissions
RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql

EXPOSE 5432

USER postgres

# Initialize the database cluster using the full path to initdb with UTF8 encoding
RUN /usr/lib/postgresql/18/bin/initdb -D /var/lib/postgresql/data -E UTF8

# Start PostgreSQL with JIT disabled
CMD ["/usr/lib/postgresql/18/bin/postgres", "-D", "/var/lib/postgresql/data", "-c", "jit=off"]
