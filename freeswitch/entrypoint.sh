#!/bin/bash
set -e

############################################
# FreeSWITCH Docker Entrypoint
# - Installs sounds/MOH once
# - Installs Lua + lua-mongo
# - Installs dkjson
# - Starts FreeSWITCH
# - Loads required modules via fs_cli
# - Auto-attaches fs_cli safely
############################################

FREESWITCH_SRC="/usr/local/src/freeswitch"
FREESWITCH_HOME="/usr/local/freeswitch"
SOUNDS_FLAG="$FREESWITCH_HOME/sounds/.installed"

echo "Starting FreeSWITCH entrypoint..."

############################################
# Install FreeSWITCH sounds & MOH (one-time)
############################################
if [ ! -f "$SOUNDS_FLAG" ]; then
  echo "Installing FreeSWITCH sound and MOH files..."
  cd "$FREESWITCH_SRC"

  make cd-sounds-install
  make cd-moh-install
  make uhd-sounds-install
  make uhd-moh-install
  make hd-sounds-install
  make hd-moh-install
  make sounds-install
  make moh-install

  mkdir -p "$FREESWITCH_HOME/sounds"
  touch "$SOUNDS_FLAG"
else
  echo "FreeSWITCH sounds already installed. Skipping."
fi

############################################
# Lua + Mongo dependencies
############################################
echo "Installing Lua and LuaRocks..."

apt-get update
apt-get remove -y lua5.1 lua5.3 || true
apt-get install -y \
  lua5.2 \
  lua5.2-dev \
  luarocks \
  gcc \
  make \
  libmongoc-dev \
  libbson-dev

############################################
# Install lua-mongo
############################################
echo "Installing lua-mongo..."
luarocks install lua-mongo

############################################
# Install dkjson
############################################
echo "Installing dkjson..."
mkdir -p "$FREESWITCH_HOME/scripts"

wget -q https://raw.githubusercontent.com/LuaDist/dkjson/master/dkjson.lua \
  -O "$FREESWITCH_HOME/scripts/dkjson.lua"

############################################
# OPTIONAL Python CDR services (disabled)
############################################
# /mnt/myenv/bin/python3.10 \
#   /usr/local/freeswitch/scripts/cdrs/cdrs_upload_handler.py &
# /mnt/myenv/bin/python3 \
#   /usr/local/freeswitch/scripts/cdrs/cdrs_posting.py &

############################################
# Start FreeSWITCH (BACKGROUND FIRST)
############################################
link=`ln -sf /usr/local/freeswitch/bin/fs_cli /usr/local/bin/fs_cli`
echo "Starting FreeSWITCH..."
#"$FREESWITCH_HOME/bin/freeswitch" -nonat &
# ---------------- Allocator tuning (RAM fix) ----------------
# glibc malloc long-running multi-thread servers ki memory OS ko wapas nahi karta:
#   - brk heap sirf TOP se shrink hota hai
#   - 64MB arena heaps tabhi munmap hote hain jab POORE khaali ho jayein
# ~120 FreeSWITCH threads + MALLOC_ARENA_MAX=2 = allocations interleave ho kar
# free blocks ko coalesce hone se rokte the -> RSS peak pe atak jaata tha.
JEMALLOC_LIB=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
if [ -f "$JEMALLOC_LIB" ]; then
  echo "Allocator: jemalloc (background purging enabled)"
  export LD_PRELOAD="$JEMALLOC_LIB"
  export MALLOC_CONF="background_thread:true,dirty_decay_ms:5000,muzzy_decay_ms:5000,narenas:4"
  "/usr/local/freeswitch/bin/freeswitch" -nonat &
else
  echo "Allocator: glibc (jemalloc not installed) - using arena-tuned settings"
  MALLOC_ARENA_MAX=8 MALLOC_TRIM_THRESHOLD_=32768 MALLOC_MMAP_THRESHOLD_=32768 \
    "/usr/local/freeswitch/bin/freeswitch" -nonat &
fi
# ------------------------------------------------------------

FS_PID=$!

############################################
# Wait for Event Socket
############################################
echo "Waiting for FreeSWITCH event socket..."
until "$FREESWITCH_HOME/bin/fs_cli" -x "status" >/dev/null 2>&1; do
  sleep 10
done

############################################
# Load required modules
############################################
echo "Loading FreeSWITCH modules..."

"$FREESWITCH_HOME/bin/fs_cli" -x "reloadacl"
"$FREESWITCH_HOME/bin/fs_cli" -x "reloadxml"
"$FREESWITCH_HOME/bin/fs_cli" -x "reload mod_sofia"
"$FREESWITCH_HOME/bin/fs_cli" -x "load mod_callcenter"
"$FREESWITCH_HOME/bin/fs_cli" -x "load mod_json_cdr"

############################################
# Auto-start fs_cli (SAFE)
############################################
echo "Attaching fs_cli..."
"$FREESWITCH_HOME/bin/fs_cli" -r &

############################################
# Bring FreeSWITCH to foreground (PID 1)
############################################
wait "$FS_PID"
