FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /usr/local/src

# Install prerequisites
RUN apt-get update && apt-get install -y \
  acl \
  dirmngr --install-recommends \
  wget curl git dnsutils ntpdate systemd net-tools whois sendmail-bin sensible-mda \
  mlocate vim imagemagick zip unzip sngrep htop \
  nginx ntp lua5.2 bc libxml2 libxml2-dev openssl libcurl4-openssl-dev gettext \
  gcc g++ build-essential python3-dev libffi-dev swig \
  build-essential libcurl4-openssl-dev libxmlrpc-core-c3-dev autoconf automake \
  libtool pkg-config libssl-dev libpcre3-dev libsqlite3-dev libspeex-dev \
  libspeexdsp-dev libsndfile1-dev libavformat-dev libswscale-dev liblua5.2-dev \
  libldns-dev libedit-dev cmake libpq-dev uuid-dev libopus-dev yasm \
  libspandsp-dev libpng-dev python3-pip python3-dev python3-venv ffmpeg \
  libbson-dev libmongoc-dev \
  libjemalloc2

# Clone Freeswitch and dependencies
RUN git clone -b v1.10 https://github.com/signalwire/freeswitch.git && \
    git clone -b master https://github.com/freeswitch/spandsp.git && \
    git clone -b master https://github.com/freeswitch/sofia-sip.git && \
    cp -r spandsp freeswitch/libs/spandsp && \
    cp -r sofia-sip freeswitch/libs/sofia-sip

# Build spandsp
RUN cd freeswitch/libs/spandsp && \
    ./bootstrap.sh || true && ./configure && make && make install || true && \
    make clean && rm -rf config/ aclocal.m4 configure Makefile.in && \
    ./bootstrap.sh && ./configure && make && make install

# Build sofia-sip
RUN cd freeswitch/libs/sofia-sip && \
    ./bootstrap.sh && ./configure && make && make install

# Build libks
RUN git clone https://github.com/signalwire/libks.git && \
    cd libks && cmake . && make -j$(nproc) && make install && ldconfig

# Prepare FreeSWITCH
WORKDIR /usr/local/src/freeswitch
RUN ./bootstrap.sh -j && \
    sed -i '/mod_signalwire/s/^/#/' modules.conf && \
    sed -i '/mod_spandsp/s/^/#/' modules.conf && \
    sed -i '/mod_callcenter/s/^#//' modules.conf && \
    sed -i '/mod_json_cdr/s/^#//' modules.conf || echo "applications/mod_json_cdr" >> modules.conf && \
    sed -i '/mod_spy/s/^#//' modules.conf || echo "applications/mod_spy" >> modules.conf && \
    ./configure && \
    make -j$(nproc) && make install && make sounds-install && make moh-install && make samples

# Ensure system has root certs
RUN apt-get update && \
    apt-get install -y ca-certificates curl && \
    update-ca-certificates

# Install system packages including CA certificates and sync time

# Python venv for ESL tools
#RUN python3 -m venv /mnt/myenv && \
#   /mnt/myenv/bin/pip install --upgrade pip && \
#   /mnt/myenv/bin/pip install \
#   pymongo uuid requests simplejson watchdog wheel FreeSWITCH-ESL-Python

#COPY packages/ /mnt/packages/
#RUN python3 -m venv /mnt/myenv && \
#    /mnt/myenv/bin/pip install /mnt/packages/*

# Copy configuration files from host (for vars.xml, internal.xml, external.xml)
COPY conf/ /usr/local/freeswitch/conf/

# Apply configuration updates
# NOTE: conf/sip_profiles/external.xml aur internal.xml is repo me MOJUD NAHI hain -
# live SIP profiles /opt/caching/demo_profiles/*.xml se load hote hain (sofia.conf.xml dekhein).
# Pehle un par bina guard ke sed chalta tha, jiski wajah se `docker compose build`
# yahin fail ho jaata tha. Ab [ -f ] guard hai, to build dono soorat me chalta hai.
RUN sed -i 's|internal_ssl_enable=false|internal_ssl_enable=true|' /usr/local/freeswitch/conf/vars.xml && \
    sed -i 's|external_ssl_enable=false|external_ssl_enable=true|' /usr/local/freeswitch/conf/vars.xml && \
    if [ -f /usr/local/freeswitch/conf/sip_profiles/external.xml ]; then \
      sed -i 's|<X-PRE-PROCESS cmd="include" data="external/\*.xml"/>|<X-PRE-PROCESS cmd="include" data="/opt/caching/configuration/gateways/\*.xml"/>|' /usr/local/freeswitch/conf/sip_profiles/external.xml && \
      sed -i 's|<!-- <param name="tls-cert-dir" value=""/> -->|<param name="tls-cert-dir" value="/usr/local/freeswitch/certs"/>|' /usr/local/freeswitch/conf/sip_profiles/external.xml ; \
    fi && \
    if [ -f /usr/local/freeswitch/conf/sip_profiles/internal.xml ]; then \
      sed -i 's|<!-- <param name="tls-cert-dir" value=""/> -->|<param name="tls-cert-dir" value="/usr/local/freeswitch/certs"/>|' /usr/local/freeswitch/conf/sip_profiles/internal.xml ; \
    fi

# -------------------------------
# ADD ACL PERMISSIONS (YOUR REQUEST)
# -------------------------------
RUN mkdir -p /usr/local/freeswitch/recordings && \
    setfacl -R -m g:www-data:rx /usr/local/freeswitch/recordings && \
    setfacl -R -d -m g:www-data:rx /usr/local/freeswitch/recordings && \
    setfacl -R -d -m o::0 /usr/local/freeswitch/recordings

# Entrypoint setup
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
