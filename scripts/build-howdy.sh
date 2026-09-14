#!/bin/sh
# Build and install Howdy with the PipeWire backend for postmarketOS.
# Run as root (the face_unlock role does). Env: HOWDY_UPSTREAM, HOWDY_SRC,
# HOWDY_VENV, DLIB_VERSION, PATCH_DIR (patches/howdy from this repo).
set -eu
: "${HOWDY_UPSTREAM:=https://github.com/boltgolt/howdy.git}"
: "${HOWDY_SRC:=/opt/howdy/src}"
: "${HOWDY_VENV:=/opt/howdy/venv}"
: "${DLIB_VERSION:=20.0.1}"
: "${PATCH_DIR:=$(dirname "$0")/../patches/howdy}"
# Wrapper that raises the backlight while compare.py runs (files/usr/local/bin)
: "${HOWDY_PYTHON:=/usr/local/bin/howdy-python}"
BASE=$(cat "$PATCH_DIR/BASE")

echo "==> dlib $DLIB_VERSION in $HOWDY_VENV (about 10 minutes)"
[ -x "$HOWDY_VENV/bin/python3" ] || python3 -m venv --system-site-packages "$HOWDY_VENV"
"$HOWDY_VENV/bin/python3" -c "import dlib" 2>/dev/null || "$HOWDY_VENV/bin/pip" install "dlib==$DLIB_VERSION"

echo "==> howdy source at $BASE + patches"
if [ ! -d "$HOWDY_SRC/.git" ]; then
	git clone "$HOWDY_UPSTREAM" "$HOWDY_SRC"
fi
cd "$HOWDY_SRC"
git -c advice.detachedHead=false checkout -q "$BASE"
git -c user.name=bootstrap -c user.email=bootstrap@localhost am "$PATCH_DIR"/*.patch

echo "==> dlib model files"
mkdir -p /usr/share/dlib-data
if [ ! -f /usr/share/dlib-data/dlib_face_recognition_resnet_model_v1.dat ]; then
	(cd /usr/share/dlib-data && sh "$HOWDY_SRC/howdy/src/dlib-data/install.sh")
fi

echo "==> meson build + install"
cd "$HOWDY_SRC/howdy"
meson setup build --prefix=/usr --libdir=lib \
	-Dpython_path="$HOWDY_PYTHON" \
	-Dpam_dir=/usr/lib/security -Dlog_path=/var/log/howdy
ninja -C build install
# Re-run setup now that /etc/howdy/config.ini exists, so later reinstalls do
# not overwrite it (meson decides at setup time).
meson setup --reconfigure build >/dev/null
mkdir -p /var/log/howdy /etc/howdy/models
echo "==> done: $(ls -l /usr/lib/security/pam_howdy.so)"
